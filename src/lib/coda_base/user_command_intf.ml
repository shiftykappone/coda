(* user_command_intf.ml *)

[%%import
"/src/config.mlh"]

open Import
open Core

[%%ifdef
consensus_mechanism]

open Coda_numbers

[%%else]

open Coda_numbers_nonconsensus.Coda_numbers
module Currency = Currency_nonconsensus.Currency

[%%endif]

module type Gen_intf = sig
  type t

  module Gen : sig
    (* Generate a single transaction between
    * Generate random keys for sender and receiver
    * for fee $\in [0,max_fee]$
    * and an amount $\in [1,max_amount]$
    *)
    val payment :
         ?sign_type:[`Fake | `Real]
      -> key_gen:(Signature_keypair.t * Signature_keypair.t)
                 Quickcheck.Generator.t
      -> ?nonce:Account_nonce.t
      -> max_amount:int
      -> max_fee:int
      -> unit
      -> t Quickcheck.Generator.t

    (* Generate a single transaction between
    * $a, b \in keys$
    * for fee $\in [0,max_fee]$
    * and an amount $\in [1,max_amount]$
    *)
    val payment_with_random_participants :
         ?sign_type:[`Fake | `Real]
      -> keys:Signature_keypair.t array
      -> ?nonce:Account_nonce.t
      -> max_amount:int
      -> max_fee:int
      -> unit
      -> t Quickcheck.Generator.t

    val stake_delegation :
         key_gen:(Signature_keypair.t * Signature_keypair.t)
                 Quickcheck.Generator.t
      -> ?nonce:Account_nonce.t
      -> max_fee:int
      -> unit
      -> t Quickcheck.Generator.t

    val stake_delegation_with_random_participants :
         keys:Signature_keypair.t array
      -> ?nonce:Account_nonce.t
      -> max_fee:int
      -> unit
      -> t Quickcheck.Generator.t

    (** Generate a valid sequence of payments based on the initial state of a
        ledger. Use this together with Ledger.gen_initial_ledger_state.
    *)
    val sequence :
         ?length:int
      -> ?sign_type:[`Fake | `Real]
      -> (Signature_lib.Keypair.t * Currency.Amount.t * Account_nonce.t) array
      -> t list Quickcheck.Generator.t
  end
end

module type S = sig
  type t [@@deriving sexp, yojson, hash]

  include Comparable.S with type t := t

  val payload : t -> User_command_payload.t

  val fee : t -> Currency.Fee.t

  val nonce : t -> Account_nonce.t

  val sender : t -> Public_key.Compressed.t

  val receiver : t -> Public_key.Compressed.t

  val amount : t -> Currency.Amount.t option

  val is_payment : t -> bool

  val memo : t -> User_command_memo.t

  val valid_until : t -> Global_slot.t

  (* for filtering *)
  val minimum_fee : Currency.Fee.t

  val is_trivial : t -> bool

  include Gen_intf with type t := t

  module With_valid_signature : sig
    module Stable : sig
      module Latest : sig
        type nonrec t = private t
        [@@deriving sexp, eq, bin_io, yojson, version, compare, hash]

        include Gen_intf with type t := t
      end

      module V1 = Latest
    end

    type t = Stable.Latest.t [@@deriving sexp, yojson, compare, hash]

    include Gen_intf with type t := t

    include Comparable.S with type t := t
  end

  val sign :
    Signature_keypair.t -> User_command_payload.t -> With_valid_signature.t

  module For_tests : sig
    val fake_sign :
      Signature_keypair.t -> User_command_payload.t -> With_valid_signature.t
  end

  val check : t -> With_valid_signature.t option

  (** Forget the signature check. *)
  val forget_check : With_valid_signature.t -> t

  val accounts_accessed : t -> Public_key.Compressed.t list

  val filter_by_participant : t list -> Public_key.Compressed.t -> t list

  include Codable.Base58_check_intf with type t := t
end
