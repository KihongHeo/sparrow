(***********************************************************************)
(*                                                                     *)
(* Copyright (c) 2007-present.                                         *)
(* Programming Research Laboratory (ROPAS), Seoul National University. *)
(* All rights reserved.                                                *)
(*                                                                     *)
(* This software is distributed under the term of the BSD license.     *)
(* See the LICENSE file for details.                                   *)
(*                                                                     *)
(***********************************************************************)
module type S = 
sig
  module Dom : InstrumentedMem.S
  module DUGraph : Dug.S with type Loc.t = Dom.A.t and type PowLoc.t = Dom.PowA.t
  module Worklist : Worklist.S with type DUGraph.t = DUGraph.t
  module Table : MapDom.CPO with type A.t = BasicDom.Node.t and type B.t = Dom.t and type t = MapDom.MakeCPO(BasicDom.Node)(Dom).t

  type t = {
    locset : Dom.PowA.t;
    locset_fs : Dom.PowA.t;
    ptrinfo : ItvDom.Table.t;
    premem : Dom.t;
    (* unsoundness *)
    unsound_lib : string BatSet.t;
    unsound_update : bool;
    unsound_bitwise : bool;
    (* for timer *)
    pre_alarm : Report.query list;
    inspect_alarm : (Global.t -> t -> Table.t -> Report.query list) option;
    coarsening_fs : (t -> Global.t -> Dom.Access.t -> DUGraph.t -> Worklist.t -> Table.t -> 
                     t * DUGraph.t * Worklist.t * Table.t) option;
    timer_finalize : (t -> Global.t -> DUGraph.t -> Table.t -> unit) option;
    extract_timer_data : (t -> Global.t -> Dom.Access.t -> int -> unit) option;
  }
  val empty : t
end

module Make(Dom: InstrumentedMem.S) : S
  with type Dom.t = Dom.t and type Dom.A.t = Dom.A.t
  and type Dom.PowA.t = Dom.PowA.t and type Dom.Access.t = Dom.Access.t
