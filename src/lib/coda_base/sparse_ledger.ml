open Core
open Import
open Snark_params.Tick

[%%versioned
module Stable = struct
  module V1 = struct
    type t =
      ( Ledger_hash.Stable.V1.t
      , Public_key.Compressed.Stable.V1.t
      , Account.Stable.V1.t )
      Sparse_ledger_lib.Sparse_ledger.T.Stable.V1.t
    [@@deriving to_yojson, sexp]

    let to_latest = Fn.id
  end
end]

type t = Stable.Latest.t [@@deriving sexp]

module Hash = struct
  include Ledger_hash

  let merge = Ledger_hash.merge
end

module Account = struct
  include Account

  let data_hash = Fn.compose Ledger_hash.of_digest Account.digest
end

module M =
  Sparse_ledger_lib.Sparse_ledger.Make (Hash) (Public_key.Compressed) (Account)

[%%define_locally
M.
  ( of_hash
  , to_yojson
  , get_exn
  , path_exn
  , set_exn
  , find_index_exn
  , add_path
  , merkle_root
  , iteri )]

let of_root (h : Ledger_hash.t) =
  of_hash ~depth:Ledger.depth (Ledger_hash.of_digest (h :> Pedersen.Digest.t))

let of_ledger_root ledger = of_root (Ledger.merkle_root ledger)

let of_any_ledger (ledger : Ledger.Any_ledger.witness) =
  Ledger.Any_ledger.M.foldi ledger
    ~init:(of_root (Ledger.Any_ledger.M.merkle_root ledger))
    ~f:(fun _addr sparse_ledger account ->
      let loc =
        Option.value_exn
          (Ledger.Any_ledger.M.location_of_key ledger account.public_key)
      in
      add_path sparse_ledger
        (Ledger.Any_ledger.M.merkle_path ledger loc)
        account.public_key
        (Option.value_exn (Ledger.Any_ledger.M.get ledger loc)) )

let of_ledger_subset_exn (oledger : Ledger.t) keys =
  let ledger = Ledger.copy oledger in
  let _, sparse =
    List.fold keys
      ~f:(fun (new_keys, sl) key ->
        match Ledger.location_of_key ledger key with
        | Some loc ->
            ( new_keys
            , add_path sl
                (Ledger.merkle_path ledger loc)
                key
                ( Ledger.get ledger loc
                |> Option.value_exn ?here:None ?error:None ?message:None ) )
        | None ->
            let path, acct = Ledger.create_empty ledger key in
            (key :: new_keys, add_path sl path key acct) )
      ~init:([], of_ledger_root ledger)
  in
  Debug_assert.debug_assert (fun () ->
      [%test_eq: Ledger_hash.t]
        (Ledger.merkle_root ledger)
        ((merkle_root sparse :> Pedersen.Digest.t) |> Ledger_hash.of_hash) ) ;
  sparse

let of_ledger_index_subset_exn (ledger : Ledger.Any_ledger.witness) indexes =
  List.fold indexes
    ~init:(of_root (Ledger.Any_ledger.M.merkle_root ledger))
    ~f:(fun acc i ->
      let account = Ledger.Any_ledger.M.get_at_index_exn ledger i in
      add_path acc
        (Ledger.Any_ledger.M.merkle_path_at_index_exn ledger i)
        account.public_key account )

let%test_unit "of_ledger_subset_exn with keys that don't exist works" =
  let keygen () =
    let privkey = Private_key.create () in
    (privkey, Public_key.of_private_key_exn privkey |> Public_key.compress)
  in
  Ledger.with_ledger ~f:(fun ledger ->
      let _, pub1 = keygen () in
      let _, pub2 = keygen () in
      let sl = of_ledger_subset_exn ledger [pub1; pub2] in
      [%test_eq: Ledger_hash.t]
        (Ledger.merkle_root ledger)
        ((merkle_root sl :> Pedersen.Digest.t) |> Ledger_hash.of_hash) )

let get_or_initialize_exn public_key t idx =
  let account = get_exn t idx in
  if Public_key.Compressed.(equal empty account.public_key) then
    (`Added, {account with delegate= public_key; public_key})
  else (`Existed, account)

let sub_account_creation_fee action (amount : Currency.Amount.t) =
  if action = `Added then
    Option.value_exn
      Currency.Amount.(
        sub amount (of_fee Coda_compile_config.account_creation_fee))
  else amount

let apply_user_command_exn t ({sender; payload; signature= _} : User_command.t)
    =
  let sender_idx = find_index_exn t (Public_key.compress sender) in
  let sender_account = get_exn t sender_idx in
  let nonce = User_command.Payload.nonce payload in
  let fee = User_command.Payload.fee payload in
  assert (Account.Nonce.equal sender_account.nonce nonce) ;
  let open Currency in
  let sender_account =
    { sender_account with
      nonce= Account.Nonce.succ sender_account.nonce
    ; receipt_chain_hash=
        Receipt.Chain_hash.cons payload sender_account.receipt_chain_hash
    ; balance=
        Balance.sub_amount sender_account.balance (Amount.of_fee fee)
        |> Option.value_exn ?here:None ?error:None ?message:None }
  in
  match User_command.Payload.body payload with
  | Stake_delegation (Set_delegate {new_delegate}) ->
      set_exn t sender_idx {sender_account with delegate= new_delegate}
  | Payment {amount; receiver} ->
      let t =
        set_exn t sender_idx
          { sender_account with
            balance=
              Balance.sub_amount sender_account.balance amount
              |> Option.value_exn ?here:None ?error:None ?message:None }
      in
      let receiver_idx = find_index_exn t receiver in
      let action, receiver_account =
        get_or_initialize_exn receiver t receiver_idx
      in
      let receiver_balance =
        (*deduct account-creation fee*)
        let amount' = sub_account_creation_fee action amount in
        Option.value_exn (Balance.add_amount receiver_account.balance amount')
      in
      set_exn t receiver_idx {receiver_account with balance= receiver_balance}

let apply_fee_transfer_exn =
  let apply_single t ((pk, fee) : Fee_transfer.Single.t) =
    let index = find_index_exn t pk in
    let action, account = get_or_initialize_exn pk t index in
    let open Currency in
    let amount = Amount.of_fee fee in
    let balance =
      let amount' = sub_account_creation_fee action amount in
      Option.value_exn (Balance.add_amount account.balance amount')
    in
    set_exn t index {account with balance}
  in
  fun t transfer -> One_or_two.fold transfer ~f:apply_single ~init:t

let apply_coinbase_exn t
    ({receiver; fee_transfer; amount= coinbase_amount} : Coinbase.t) =
  let open Currency in
  let add_to_balance t pk amount =
    let idx = find_index_exn t pk in
    let action, a = get_or_initialize_exn pk t idx in
    let balance =
      let amount' = sub_account_creation_fee action amount in
      Option.value_exn (Balance.add_amount a.balance amount')
    in
    set_exn t idx {a with balance}
  in
  let receiver_reward, t =
    match fee_transfer with
    | None ->
        (coinbase_amount, t)
    | Some (transferee, fee) ->
        let fee = Amount.of_fee fee in
        let reward =
          Amount.sub coinbase_amount fee
          |> Option.value_exn ?here:None ?message:None ?error:None
        in
        (reward, add_to_balance t transferee fee)
  in
  add_to_balance t receiver receiver_reward

let apply_transaction_exn t (transition : Transaction.t) =
  match transition with
  | Fee_transfer tr ->
      apply_fee_transfer_exn t tr
  | User_command cmd ->
      apply_user_command_exn t (cmd :> User_command.t)
  | Coinbase c ->
      apply_coinbase_exn t c

let merkle_root t = Ledger_hash.of_hash (merkle_root t :> Pedersen.Digest.t)

let handler t =
  let ledger = ref t in
  let path_exn idx =
    List.map (path_exn !ledger idx) ~f:(function `Left h -> h | `Right h -> h)
  in
  stage (fun (With {request; respond}) ->
      match request with
      | Ledger_hash.Get_element idx ->
          let elt = get_exn !ledger idx in
          let path = (path_exn idx :> Pedersen.Digest.t list) in
          respond (Provide (elt, path))
      | Ledger_hash.Get_path idx ->
          let path = (path_exn idx :> Pedersen.Digest.t list) in
          respond (Provide path)
      | Ledger_hash.Set (idx, account) ->
          ledger := set_exn !ledger idx account ;
          respond (Provide ())
      | Ledger_hash.Find_index pk ->
          let index = find_index_exn !ledger pk in
          respond (Provide index)
      | _ ->
          unhandled )
