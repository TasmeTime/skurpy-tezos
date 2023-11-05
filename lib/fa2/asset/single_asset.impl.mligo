#import "../common/assertions.jsligo" "Assertions"

#import "../common/errors.mligo" "Errors"

#import "../common/tzip12.datatypes.jsligo" "TZIP12"

#import "../common/tzip12.interfaces.jsligo" "TZIP12Interface"

#import "../common/tzip16.datatypes.jsligo" "TZIP16"


module Datatypes  = struct
 type ledger = (address, nat) big_map
   type operator = address
   type operators = (address, operator set) big_map
   type storage =  {
      ledger : ledger;
      operators : operators;
      token_metadata : TZIP12.tokenMetadata;
      metadata : TZIP16.metadata;
   }
end

module Sidecar  = struct

// Operators 


   let assert_authorisation (operators : Datatypes.operators) (from_ : address) : unit =
      let sender_ = (Tezos.get_sender ()) in
      if (sender_ = from_) then ()
      else
      let authorized = match Big_map.find_opt from_ operators with
         Some (a) -> a | None -> Set.empty
      in if Set.mem sender_ authorized then ()
      else failwith Errors.not_operator


  

   let add_operator (operators : Datatypes.operators) (owner : address) (operator : Datatypes.operator) : Datatypes.operators =
      if owner = operator then operators (* assert_authorisation always allow the owner so this case is not relevant *)
      else
         let () = Assertions.assert_update_permission owner in
         let auths = match Big_map.find_opt owner operators with
            Some (os) -> os | None -> Set.empty in
         let auths  = Set.add operator auths in
         Big_map.update owner (Some auths) operators

   let remove_operator (operators : Datatypes.operators) (owner : address) (operator : Datatypes.operator) : Datatypes.operators =
      if owner = operator then operators (* assert_authorisation always allow the owner so this case is not relevant *)
      else
         let () = Assertions.assert_update_permission owner in
         let auths = match Big_map.find_opt owner operators with
         None -> None | Some (os) ->
            let os = Set.remove operator os in
            if (Set.size os = 0n) then None else Some (os)
         in
         Big_map.update owner auths operators


// Ledger 

   let get_for_user    (ledger:Datatypes.ledger) (owner: address) : nat =
      match Big_map.find_opt owner ledger with
         Some (tokens) -> tokens
      |  None          -> 0n

   let update_for_user (ledger:Datatypes.ledger) (owner: address) (amount_ : nat) : Datatypes.ledger =
      Big_map.update owner (Some amount_) ledger

   let decrease_token_amount_for_user (ledger : Datatypes.ledger) (from_ : address) (amount_ : nat) : Datatypes.ledger =
      let tokens = get_for_user ledger from_ in
      let () = assert_with_error (tokens >= amount_) Errors.ins_balance in
      let tokens = abs(tokens - amount_) in
      let ledger = update_for_user ledger from_ tokens in
      ledger

   let increase_token_amount_for_user (ledger : Datatypes.ledger) (to_   : address) (amount_ : nat) : Datatypes.ledger =
      let tokens = get_for_user ledger to_ in
      let tokens = tokens + amount_ in
      let ledger = update_for_user ledger to_ tokens in
      ledger

// Storage

 
  
   let get_amount_for_owner (s:Datatypes.storage) (owner : address) =
      get_for_user s.ledger owner

   let set_ledger (s:Datatypes.storage) (ledger:Datatypes.ledger) = {s with ledger = ledger}

   let get_operators (s:Datatypes.storage) = s.operators
   let set_operators (s:Datatypes.storage) (operators:Datatypes.operators) = {s with operators = operators}



end

module SingleAsset  = struct
   type ledger = Datatypes.ledger
   type operators = Datatypes.operators
   type storage =  Datatypes.storage
   type ret = operation list * storage


[@entry] let transfer : TZIP12.transfer -> storage -> operation list * storage =
   fun (t:TZIP12.transfer) (s:storage) ->
   (* This function process the "txs" list. Since all transfer share the same "from_" address, we use a se *)
   let process_atomic_transfer (from_:address) (ledger, t:ledger * TZIP12.atomic_trans) =
      let {to_;token_id=_token_id;amount=amount_} = t in
      let ()     = Sidecar.assert_authorisation s.operators from_ in
      let ledger = Sidecar.decrease_token_amount_for_user ledger from_ amount_ in
      let ledger = Sidecar.increase_token_amount_for_user ledger to_   amount_ in
      ledger
   in
   let process_single_transfer (ledger, t:ledger * TZIP12.transfer_from ) =
      let {from_;txs} = t in
      let ledger     = List.fold_left (process_atomic_transfer from_) ledger txs in
      ledger
   in
   let ledger = List.fold_left process_single_transfer s.ledger t in
   let s = Sidecar.set_ledger s ledger in
   ([]: operation list),s


[@entry] let balance_of :  TZIP12.balance_of -> storage -> operation list * storage =
   fun (b: TZIP12.balance_of) (s: storage) ->
   let {requests;callback} = b in
   let get_balance_info (request : TZIP12.request) : TZIP12.callback =
      let {owner;token_id=_token_id} = request in
      let balance_ = Sidecar.get_amount_for_owner s owner    in
      {request=request;balance=balance_}
   in
   let callback_param = List.map get_balance_info requests in
   let operation = Tezos.transaction (Main callback_param) 0tez callback in
   ([operation]: operation list),s

(**
Add or Remove token operators for the specified token owners and token IDs.


The entrypoint accepts a list of update_operator commands. If two different
commands in the list add and remove an operator for the same token owner and
token ID, the last command in the list MUST take effect.


It is possible to update operators for a token owner that does not hold any token
balances yet.


Operator relation is not transitive. If C is an operator of B and if B is an
operator of A, C cannot transfer tokens that are owned by A, on behalf of B.


*)
[@entry] let update_operators :  TZIP12.update_operators -> storage -> operation list * storage =
   fun (updates: TZIP12.update_operators) (s: storage) ->
   let update_operator (operators,update : operators * TZIP12.unit_update) = match update with
      Add_operator    {owner=owner;operator=operator;token_id=_token_id} -> Sidecar.add_operator    operators owner operator
   |  Remove_operator {owner=owner;operator=operator;token_id=_token_id} -> Sidecar.remove_operator operators owner operator
   in
   let operators = Sidecar.get_operators s in
   let operators = List.fold_left update_operator operators updates in
   let s = Sidecar.set_operators s operators in
   ([]: operation list),s


  [@view]
  let get_balance (p: (address * nat)) (s: storage) : nat =  
  
  let (owner , token_id) = p in
  let () = Assertions.assert_token_exist s.token_metadata token_id in
  match Big_map.find_opt owner s.ledger with None -> 0n | Some(n) -> n

  [@view]
  let total_supply (_token_id: nat) (_s: storage) : nat =  failwith Errors.not_available
  [@view]
  let all_tokens (_: unit) (_s: storage) : nat set = failwith Errors.not_available
  [@view]
  let is_operator (op: TZIP12.operator) (s: storage) : bool = 

   let authorized = match Big_map.find_opt (op.owner) s.operators with
            Some(opSet) -> opSet
            | None -> Set.empty in
    Set.mem op.operator authorized  || op.owner = op.operator

 [@view]
  let token_metadata (p: nat) (s: storage) : TZIP12.tokenMetadataData = 
      match Big_map.find_opt p s.token_metadata with
         Some(data) ->    data
         | None() -> failwith Errors.undefined_token

end


   module DUMMY : TZIP12Interface.FA2 = SingleAsset