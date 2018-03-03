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
(** timer for interval analysis *)
open Cil
open Vocab
open Global
open BasicDom
open ItvDom
open Report
open Yojson

module Analysis = SparseAnalysis.Make(ItvSem)
module Table = Analysis.Table
module DUGraph = Analysis.DUGraph
module Worklist = Analysis.Worklist
module Spec = Analysis.Spec
module Access = Spec.Dom.Access
module LocHashtbl = BatHashtbl.Make(Loc)

type strategy = Rank | Clf
type coarsening_target = Dug | Worklist

let strategy = Rank
let coarsening_target = Dug

type t = {
  widen_start : float;
  last : float;
  time_stamp : int;
  old_inputof : Table.t;
  static_feature : float LocHashtbl.t;
  dynamic_feature : DynamicFeature.feature;
  alarm_history : (int, Report.query list) BatMap.t;
  locset : PowLoc.t;
  num_of_locset : int;
  num_of_coarsen : int;
  total_memory : int;
  base_memory : int;
  current_memory : int;
  total_worklist : int;
  prepare : int;
  deadline : int;
  coeff : float;
  py : Lymp.pycommunication;
  base_height : int;
  fi_height : int;
  history : (float list * float) list
}

let empty = {
  widen_start = 0.0;
  last = 0.0;
  time_stamp = 1;
  old_inputof = Table.empty;
  static_feature = LocHashtbl.create 1;
  dynamic_feature = DynamicFeature.empty_feature;
  alarm_history = BatMap.empty;
  locset = PowLoc.empty;
  num_of_locset = 0;
  num_of_coarsen = 0;
  total_memory = 70; (* MB *)
  base_memory = 0;
  current_memory = 0;
  total_worklist = 0;
  prepare = 0;
  deadline = 0;
  coeff = 0.0;
  py = Lymp.init ~exec:"python3" "/home/khheo/project/TimerExperiment/";
  base_height = 0;
  fi_height = 0;
  history = [];
}

let timer = ref empty

let prerr_memory_info timer =
  (* XXX: quick_stat *)
  let stat = Gc.stat () in
  (* total 128 GB *)
  let live_mem = stat.Gc.live_words * Sys.word_size / 1024 / 1024 / 8 in
  let heap_mem = stat.Gc.heap_words * Sys.word_size / 1024 / 1024 / 8 in
  prerr_endline "=== Memory Usage ===";
  prerr_endline ("live mem   : " ^ string_of_int live_mem ^ " / " ^ string_of_int timer.total_memory ^ "MB");
  prerr_endline ("total heap : " ^ string_of_int heap_mem ^ " / " ^ string_of_int timer.total_memory ^ "MB");
  prerr_endline ("actual heap : " ^ string_of_int (heap_mem - timer.base_memory) ^ " / " ^ string_of_int (timer.total_memory - timer.base_memory));
  ()

let prdbg_endline x =
  if !Options.timer_debug then
    prerr_endline ("DEBUG::"^x)
  else ()

let load_classifier global timer =
  let py_module = Lymp.get_module timer.py "sparrow" in
  let classifier = Lymp.Pyref (Lymp.get_ref py_module "load" [Lymp.Pystr !Options.timer_clf]) in
  (py_module, classifier)

let predict py_module clf x feature static_feature =
  let vec = DynamicFeature.feature_vector x feature static_feature in
  let vec = Lymp.Pylist (List.map (fun x -> Lymp.Pyfloat x) vec) in
  Lymp.get_bool py_module "predict_one" [clf; vec]

let predict_proba py_module clf x feature static_feature =
  let vec = DynamicFeature.feature_vector x feature static_feature in
  let vec = Lymp.Pylist (List.map (fun x -> Lymp.Pyfloat x) vec) in
  Lymp.get_float py_module "predict_proba" [clf; vec]

(*

let clf_strategy global timer =
  let (py_module, clf) = load_classifier global timer in
  let set = Hashtbl.fold (fun k _ ->
      if predict py_module clf k timer.dynamic_feature timer.static_feature then PowLoc.add k
      else id) DynamicFeature.locset_hash PowLoc.empty
  in
  set

*)
let counter_example global lst =
    let filename = Filename.basename global.file.Cil.fileName in
    let oracle = try MarshalManager.input ~dir:!Options.timer_dir (filename^".oracle") with _ -> prerr_endline "Can't find the oracle"; BatMap.empty in
    prerr_endline "== counter examples";
    List.iter (fun (x, w) ->
        let answer = try BatMap.find (!timer.time_stamp, Loc.to_string x) oracle with _ -> w in
        if abs_float (answer -. w) >= 0.5 then
          prerr_endline ("ce : " ^ Loc.to_string x ^ " : " ^ string_of_float w ^", answer : " ^ string_of_float answer)
        else ()
    ) lst; lst

let model timer x =
  if x >= 1.0 then 1.0
  else
    let k = timer.coeff in
    k *. x /. (k -. x +. 1.0)
(*

let dump_feature global timer inputof worklist action =
  let (feat_memory, feat_height, feat_worklist) = MemoryFeature.extract_feature global timer inputof worklist in
  let filename = Filename.basename global.file.Cil.fileName in
  let oc = open_out_gen [Open_creat; Open_append; Open_text] 0o640 (!Options.timer_dir ^ "/" ^ filename ^ ".mem_feature") in
  output_string oc ((string_of_float feat_memory) ^ "," ^ (string_of_float feat_height) ^ "," ^ string_of_float feat_worklist ^ ":" ^ action ^"\n");
  close_out oc

*)

let append_history mem_feature portion =
  timer := { !timer with history = (mem_feature, portion)::(!timer.history) }

let coarsen_portion global timer worklist inputof =
  if !Options.timer_random_search then
    let _ = prerr_endline "Randomly chosen (random search)" in
    let portion = (Random.int 100 |> float_of_int) /. 100.0 in
    (timer.num_of_locset - timer.num_of_coarsen) * (portion *. 100.0 |> int_of_float) / 100
  else if timer.total_memory > 0 && !Options.timer_auto_coarsen && (memory_usage () * 100 / timer.total_memory < 50) then 0
  else if timer.total_memory > 0 && !Options.timer_auto_coarsen then
    let _ = prerr_endline ("Current Mem0 : " ^ string_of_int (memory_usage ())) in
    let mem_feature = MemoryFeature.extract_feature global inputof worklist
        ~total_memory:timer.total_memory ~base_memory:timer.base_memory
        ~fi_height:timer.fi_height ~base_height:timer.base_height
        ~total_worklist:timer.total_worklist
        |> MemoryFeature.to_vector
    in
    let py_module = Lymp.get_module timer.py "sparrow" in
(*     let filename = Filename.basename global.file.Cil.fileName in *)
(*     let clf = Lymp.Pystr (!Options.timer_dir ^ "/" ^ filename ^ "." ^ string_of_int timer.total_memory ^ ".strategy") in *)
    let clf = Lymp.Pystr (!Options.timer_clf ^ ".strategy") in
    let vec = List.map (fun x -> Lymp.Pyfloat x) mem_feature in
    let portion =
      if !Options.timer_training && (!Options.timer_iteration < 5 || Random.int 1000 < (!Options.timer_explore_rate * 10 - !Options.timer_iteration)) then
        let _ = prerr_endline "Randomly chosen" in
        (Random.int 80 |> float_of_int) /. 100.0
      else
        BatList.range 0 `To 100
        |> List.map (fun x ->
            let p = float_of_int x /. 100.0 in
            let vec = Lymp.Pylist (vec @ [Lymp.Pyfloat p]) in
            let estimation = Lymp.get_float py_module "predict_float" [clf; vec] in
            (p, estimation))
        |> List.sort (fun (_, x) (_, y) -> compare x y)
        |> (fun x -> List.iter (fun (portion, alarm_estimation) ->
            prerr_endline ((string_of_float portion) ^ " : " ^ (string_of_float alarm_estimation))) x; x)
        |> (fun x -> List.filter (fun e -> snd (List.hd x) = snd e) x)
(*        |> (fun x -> List.nth x (List.length x / 3))*)
        |> List.hd  
        |> fst
    in
    append_history mem_feature portion;
    prerr_endline ("portion : " ^ string_of_float portion);
(*     timer.num_of_locset * portion / 100 - timer.num_of_coarsen *)
    (timer.num_of_locset - timer.num_of_coarsen) * (portion *. 100.0 |> int_of_float) / 100
  else if timer.total_memory > 0 && !Options.timer_manual_coarsen <> "" then
    let actual_used_mem = memory_usage () - timer.base_memory in
    let possible_mem = timer.total_memory - timer.base_memory in
    prerr_endline ("actual: " ^ string_of_int actual_used_mem);
    prerr_endline ("possible: " ^ string_of_int possible_mem);
(*     let x = (float_of_int actual_used_mem) /. (float_of_int possible_mem) *. 5.0 in *)
(*     prerr_endline ("x : " ^ string_of_float x); *)
    let controls = Str.split (Str.regexp "[ \t\n]+") (!Options.timer_manual_coarsen) in
    let action = try List.nth controls (timer.time_stamp - 1) with _ -> "0" in
    prerr_endline ("portion : " ^ action);
    (timer.num_of_locset - timer.num_of_coarsen) * (int_of_string action) / 100
  else if timer.total_memory > 0 then
    let actual_used_mem = memory_usage () - timer.base_memory in
    let possible_mem = timer.total_memory - timer.base_memory in
(*    let target = (actual_used_mem * 100 / possible_mem / 10 + 1) * 10 in (* rounding (e.g. 15 -> 20) *)*)
    let x = (float_of_int actual_used_mem) /. (float_of_int possible_mem) in
    let target = model timer x in
    prerr_endline ("target : " ^ string_of_float target);
    (target *. (float_of_int timer.num_of_locset) |> int_of_float) - timer.num_of_coarsen
  else
    0

let assign_weight locs features =
  let weight_vector =
    Str.split (Str.regexp "[ \t\n]+") (!Options.pfs_wv)
    |> List.map float_of_string
  in
  let score l =
    List.fold_left2 (fun p x y -> p +. x *. y) 0.0 l weight_vector
  in
  List.map (fun l ->
      let f =
        DynamicFeature.LocHashtbl.find features l |> BatList.take 45
      in
      (l, score f)) locs

let rank_strategy global spec timer top =
  let ranking =
    if !Options.timer_oracle_rank then
      let filename = Filename.basename global.file.Cil.fileName in
      let oracle =
        try MarshalManager.input ~dir:!Options.timer_dir (filename^".oracle")
        with _ -> prerr_endline "Can't find the oracle"; BatMap.empty
      in
      LocHashtbl.fold (fun k _ l ->
          let score =
            (try BatMap.find (timer.time_stamp, Loc.to_string k) oracle with _ -> 0.0)
          in
          (k, score)::l) DynamicFeature.locset_hash []
        |> List.sort (fun (_, x) (_, y) -> if x > y then -1 else if x = y then 0 else 1)
    else if (*!Options.timer_static_rank*) true then
      LocHashtbl.fold (fun k _ l -> (k, LocHashtbl.find timer.static_feature k)::l)
          DynamicFeature.locset_hash []
      |> List.sort (fun (_, x) (_, y) -> compare x y)
    else
      []
(*XXX
      let (py_module, clf) = load_classifier global timer in
      Hashtbl.fold (fun k _ l ->
            (k, predict_proba py_module clf k timer.dynamic_feature timer.static_feature)::l)
        DynamicFeature.locset_hash []
      |> List.sort (fun (_, x) (_, y) -> if x > y then -1 else if x = y then 0 else 1)
      |> opt !Options.timer_counter_example (counter_example global)
*)
  in
  ranking
  |> opt !Options.timer_debug
        (fun l -> List.fold_left (fun r (l, w) ->
          prerr_string (string_of_int r ^ ". "^ (Loc.to_string l) ^ ", "^ (string_of_float w) ^ "\n");
          r + 1) 1 l |> ignore; prerr_endline ""; l)
  |> BatList.take top
  |> List.map fst
  |> PowLoc.of_list
(*  else PowLoc.empty*)

module AlarmSet = Dependency.AlarmSet

let old_alarms = ref AlarmSet.empty

let get_new_alarms alarms =
  let new_alarms = List.filter (fun q -> not (AlarmSet.mem q !old_alarms)) alarms in
  List.iter (fun q ->
      old_alarms := AlarmSet.add q !old_alarms; ()) new_alarms;
  new_alarms

let diff_alarms alarms1 alarms2 =
  let alarms2_set = List.fold_left (fun set q -> AlarmSet.add q set) AlarmSet.empty alarms2 in
  List.filter (fun q -> not (AlarmSet.mem q alarms2_set)) alarms1

module History = BatMap.Make(Loc)
module HistoryAlarm = Dependency.AlarmMap

let timer_dump global dug inputof feature new_alarms locset_coarsen time =
  let filename = Filename.basename global.file.Cil.fileName in
  let surfix = string_of_int time in
  let dir = !Options.timer_dir in
  MarshalManager.output ~dir (filename ^ ".feature." ^ surfix) feature;
  MarshalManager.output ~dir (filename ^ ".inputof." ^ surfix) inputof;
  MarshalManager.output ~dir (filename ^ ".dug." ^ surfix) dug;
  MarshalManager.output ~dir (filename ^ ".alarm." ^ surfix) new_alarms;
  let coarsen_history =
    (try MarshalManager.input ~dir (filename ^ ".coarsen_history") with _ -> History.empty)
    |> PowLoc.fold (fun x -> History.add x time) locset_coarsen
  in
  MarshalManager.output ~dir (filename ^ ".coarsen_history") coarsen_history;
  let alarm_history =
    (try MarshalManager.input ~dir (filename ^ ".alarm_history") with _ -> HistoryAlarm.empty)
    |> list_fold (fun x -> HistoryAlarm.add x time) new_alarms
  in
  MarshalManager.output ~dir (filename ^ ".alarm_history") alarm_history

(* compute coarsening targets *)
let filter global locset_coarsen node dug =
  list_fold (fun p (target, dug) ->
      let locs_on_edge = DUGraph.get_abslocs p node dug in
      let target_on_edge = PowLoc.inter locs_on_edge locset_coarsen in
      if PowLoc.is_empty target_on_edge then (target, dug)
      else
        let dug = DUGraph.remove_abslocs p target_on_edge node dug in
        let target = PowLoc.union target_on_edge target in
        (target, dug)
    ) (DUGraph.pred node dug) (PowLoc.empty, dug)

(* memory sharing for inter-edges *)
let optimize_dug global dug =
  let uses_of_function = Hashtbl.create 256 in
  let defs_of_function = Hashtbl.create 256 in
  let calls = InterCfg.callnodesof global.icfg in
  list_fold (fun call dug ->
    let return = InterCfg.returnof call global.icfg in
    InterCfg.ProcSet.fold (fun callee dug ->
        let entry = InterCfg.entryof global.icfg callee in
        let exit  = InterCfg.exitof  global.icfg callee in
        let locs_on_call =
          try
            Hashtbl.find uses_of_function callee
          with Not_found ->
            let locs = DUGraph.get_abslocs call entry dug in
            Hashtbl.add uses_of_function callee locs;
            locs
        in
        let locs_on_return =
          try
            Hashtbl.find defs_of_function callee
          with Not_found ->
            let locs = DUGraph.get_abslocs exit return dug in
            Hashtbl.add defs_of_function callee locs;
            locs
        in
        dug
        |> DUGraph.modify_abslocs call locs_on_call entry
        |> DUGraph.modify_abslocs exit locs_on_return return
      ) (InterCfg.get_callees call global.icfg) dug) calls dug

(* coarsening all nodes in dug *)
let coarsening_dug global access locset_coarsen dug worklist inputof outputof spec =
  if PowLoc.is_empty locset_coarsen then (spec,dug,worklist,inputof,outputof)
  else
    let (dug,worklist_candidate,inputof,outputof) =
      DUGraph.fold_node (fun node (dug,worklist_candidate,inputof,outputof) ->
          let _ = Profiler.start_event "coarsening filter" in
          let (locset_coarsen, dug) = filter global locset_coarsen node dug in
          let _ = Profiler.finish_event "coarsening filter" in
          if PowLoc.is_empty locset_coarsen then (dug, worklist_candidate, inputof,outputof)
          else
            let used = Access.Info.useof (Access.find_node node access) in
            let (old_input_mem, old_output_mem) = (Table.find node inputof, Table.find node outputof) in
            let _ = Profiler.start_event "coarsening mem" in
            let (new_input_mem, new_output_mem) = PowLoc.fold (fun l (new_input_mem, new_output_mem) ->
                if PowLoc.mem l used then 
                  (Mem.add l (try LocHashtbl.find DynamicFeature.premem_hash l with _ -> Val.bot)
                  new_input_mem, new_output_mem)
                else
                  (Mem.remove l new_input_mem, Mem.remove l new_output_mem)
              ) locset_coarsen (old_input_mem, old_output_mem) in
            let _ = Profiler.finish_event "coarsening mem" in
            let worklist_candidate =
(*              if Mem.unstables old_mem new_mem unstable spec.Spec.locset_fs = [] then worklist
              else*) node::worklist_candidate in
            (dug, worklist_candidate,
             Table.add node new_input_mem inputof,
             Table.add node new_output_mem outputof)) dug (dug,[],inputof,outputof)
    in
    let dug = optimize_dug global dug in
    let (to_add, to_remove) = List.fold_left (fun (to_add, to_remove) node ->
        if DUGraph.pred node dug = [] && DUGraph.succ node dug = [] then (to_add, BatSet.add node to_remove)
        else (BatSet.add node to_add, to_remove)) (BatSet.empty, BatSet.empty) worklist_candidate
    in
    let worklist =
      Worklist.remove_set to_remove worklist
      |> Worklist.push_plain_set to_add
    in
    let (dug, inputof, outputof) =
      BatSet.fold (fun node (dug, inputof, outputof) ->
        if DUGraph.pred node dug = [] && DUGraph.succ node dug = [] then
          (DUGraph.remove_node node dug, Table.remove node inputof, Table.remove node outputof)
        else
          (dug, inputof, outputof)) to_remove (dug, inputof, outputof)
    in
(*    let spec = { spec with Spec.locset_fs = PowLoc.diff spec.Spec.locset_fs locset_coarsen } in*)
    LocHashtbl.filteri_inplace (fun k _ -> not (PowLoc.mem k locset_coarsen)) DynamicFeature.locset_hash;
(*    PowLoc.iter (fun k -> Hashtbl.replace locset_fi_hash k k) locset_coarsen;*)
    (spec,dug,worklist,inputof,outputof)

(* coarsening all nodes in worklist *)
let coarsening_worklist global access locset_coarsen dug worklist inputof spec =
  if PowLoc.is_empty locset_coarsen then (dug,worklist,inputof)
  else
    let (dug,candidate) =
      Worklist.fold (fun node (dug,candidate) ->
          let _ = Profiler.start_event "coarsening filter" in
          let (locset_coarsen, dug) = filter global locset_coarsen node dug in
          let _ = Profiler.finish_event "coarsening filter" in
          if PowLoc.is_empty locset_coarsen then (dug, candidate)
      else (dug, (node,locset_coarsen)::candidate)) worklist (dug,[])
    in
    let (inputof, worklist) =
      List.fold_left (fun (inputof,worklist) (node,locset_coarsen) ->
        let locs_on_edge = List.fold_left (fun locs s ->
                    DUGraph.get_abslocs node s dug
                    |> PowLoc.join locs) PowLoc.empty (DUGraph.succ node dug)
        in
        let locs_used = Access.Info.useof (Access.find_node node access) in
        let locset_coarsen = PowLoc.inter locset_coarsen (PowLoc.join locs_on_edge locs_used) in
        let old_mem = Table.find node inputof in
        let _ = Profiler.start_event "coarsening mem" in
        let new_mem = PowLoc.fold (fun l -> Mem.add l
          (try LocHashtbl.find DynamicFeature.premem_hash l with _ -> Val.bot)
          ) locset_coarsen old_mem in
        let _ = Profiler.finish_event "coarsening mem" in
        let worklist =
          if DUGraph.pred node dug = [] && DUGraph.succ node dug = [] then
            Worklist.remove node worklist
          else worklist
        in
        (Table.add node new_mem inputof, worklist)) (inputof, worklist) candidate
    in
    (dug,worklist,inputof)

let coarsening global access locset_coarsen dug worklist inputof outputof spec =
  match coarsening_target with
  | Dug -> coarsening_dug global access locset_coarsen dug worklist inputof outputof spec
  | Worklist ->
    let (dug,worklist,inputof) = coarsening_worklist global access locset_coarsen dug
        worklist inputof spec
    in
    (spec,dug,worklist,inputof, outputof) (* TODO: outputof *)

let print_stat spec global access dug =
  let alarm_fs = MarshalManager.input (global.file.Cil.fileName ^ ".alarm") |> flip Report.get Report.UnProven |> AlarmSet.of_list in
  let alarm_fi = spec.Spec.pre_alarm |> flip Report.get Report.UnProven |> AlarmSet.of_list in
  let locset_of_fi = Dependency.dependency_of_query_set_new false global dug access alarm_fi in
(*        AlarmSet.fold (fun q locs ->
          Dependency.dependency_of_query global dug access q global.mem
          |> PowLoc.join locs) alarm_fi PowLoc.empty
  in*)
  let locset_of_fs = Dependency.dependency_of_query_set_new false global dug access alarm_fs in
(*        AlarmSet.fold (fun q locs ->
          Dependency.dependency_of_query global dug access q global.mem
          |> PowLoc.join locs) alarm_fs PowLoc.empty
  in*)
  prerr_endline (" == Timer Stat ==");
  prerr_endline (" # Total AbsLoc : " ^ string_of_int (PowLoc.cardinal spec.Spec.locset_fs));
  prerr_endline (" # FI AbsLoc : " ^ string_of_int (PowLoc.cardinal locset_of_fi));
  prerr_endline (" # FS AbsLoc : " ^ string_of_int (PowLoc.cardinal locset_of_fs));
  exit 0

let encode_static_feature global locset =
  let weighted_locs = PartialFlowSensitivity.weighted_locs global locset in
  let hashtbl = LocHashtbl.create 100000 in
  List.iter (fun (loc, weight) ->
      LocHashtbl.add hashtbl loc weight) weighted_locs;
  hashtbl

let initialize spec global access dug worklist inputof outputof =
  Random.self_init ();
  let widen_start = Sys.time () in
(*   let alarm_fi = spec.Spec.pre_alarm |> flip Report.get Report.UnProven |> AlarmSet.of_list in *)
  let target_locset = spec.Spec.locset_fs in
  (* if target locset is a set of reachable locs from fi_alarms *)
(*     Dependency.dependency_of_query_set_new true global dug access alarm_fi *)
  let static_feature = encode_static_feature global spec.Spec.locset_fs in
(*  let filename = Filename.basename global.file.Cil.fileName in
  let dir = !Options.timer_dir in*)
(*   MarshalManager.output ~dir (filename ^ ".static_feature") static_feature; *)
  prerr_endline ("\n== locset took " ^ string_of_float (Sys.time () -. widen_start));

  let locset_coarsen = PowLoc.diff spec.Spec.locset_fs target_locset in
  (if !Options.timer_stat then print_stat spec global access dug);
  prerr_endline ("\n== feature took " ^ string_of_float (Sys.time () -. widen_start));
  (* for efficiency *)
  let dynamic_feature = DynamicFeature.initialize_cache spec.Spec.locset target_locset spec.Spec.premem in
  let (spec, dug, worklist, inputof, outputof) = coarsening global access locset_coarsen dug worklist inputof outputof spec in
  let prepare = int_of_float (Sys.time () -. widen_start) in
(*   let deadline = !Options.timer_deadline - prepare in *)
  let base_memory = memory_usage () in
  timer := {
    !timer with
    widen_start; last = Sys.time (); static_feature; locset = target_locset;
    total_memory = !Options.timer_total_memory;
    coeff = !Options.timer_coeff;
    dynamic_feature;
    num_of_locset = PowLoc.cardinal target_locset;
    base_memory;
    current_memory = base_memory;
    total_worklist = Worklist.cardinal worklist;
    prepare;
    base_height = MemoryFeature.height_of_table global inputof worklist;
    fi_height = MemoryFeature.height_of_fi_mem global worklist dug access spec.Spec.premem;
  };
(*   timer := { !timer with threshold = threshold !timer.time_stamp; }; (* threshold uses prepare and deadline *) *)
  prerr_endline ("\n== Timer: Coarsening #0 took " ^ string_of_float (Sys.time () -. widen_start));
  prerr_endline ("== Actual Target: " ^ (string_of_int !timer.num_of_locset));
  prerr_endline ("== Base Mem: " ^ (string_of_int base_memory));
(*  let new_alarms = (BatOption.get spec.Spec.inspect_alarm) global spec inputof
                   |> flip Report.get Report.UnProven in*)
      (* TODO: revert the following when dynamic learning is necessary *)
(*   timer_dump global dug inputof dynamic_feature new_alarms locset_coarsen 0; *)
  (spec, dug, worklist, inputof, outputof)

module Data = Set.Make(Loc)

let extract_type1 spec oc prev next coarsen size_coarsen coarsen_score_pos1 global dug access alarm_fi feature_prev inputof_prev inputof_idx iteration =
  output_string oc ("#\t\t\tType 1 Data. "^(string_of_int next)^" -> " ^ (string_of_int prev)^"\n");
  (* locs not related to FI-alarms *)
(*   let locs_of_fi_alarms = Dependency.dependency_of_query_set global dug access alarm_fi feature_prev inputof_prev inputof_idx in *)
  let locs_of_fi_alarms = Dependency.dependency_of_query_set_new false global dug access alarm_fi in
  let pos_locs1 = PowLoc.diff spec.Spec.locset_fs locs_of_fi_alarms in
  let inter_pos1 = PowLoc.inter pos_locs1 coarsen in
  output_string oc ("#\t\t\t\tPos1 : "^(PowLoc.cardinal pos_locs1 |> string_of_int)^"\n");
  output_string oc ("#\t\t\t\tCoarsen : "^(string_of_int size_coarsen)^"\n");
  let size_inter_pos = PowLoc.cardinal inter_pos1 in
  output_string oc ("#\t\t\t\tIntersect between Coarsen and Pos1 : "^(string_of_int size_inter_pos)^" ("^(string_of_int (size_inter_pos * 100 / size_coarsen))^"%)\n");
  let coarsen_score_pos1_new = (PowLoc.cardinal inter_pos1) * 100 / (PowLoc.cardinal coarsen) in
  output_string oc ("#\t\t\t\tPos1 Score previous iter : " ^ string_of_int coarsen_score_pos1 ^ ", this iter : " ^ string_of_int coarsen_score_pos1_new^"\n");
  let pos_locs1 =
    if iteration = 0 then pos_locs1
    else if coarsen_score_pos1 >= coarsen_score_pos1_new (*&& coarsen_score_pos1 >= 80*) then PowLoc.bot
    else PowLoc.diff pos_locs1 coarsen
  in
(*         PowLoc.iter (fun x -> output_string oc (string_of_raw_feature x feature_prev static_feature^ " : 1\n")) pos_locs; *)
  (pos_locs1, coarsen_score_pos1_new)

let is_inter_node global node =
  (InterCfg.is_entry node) || (InterCfg.is_exit node)
  || (InterCfg.is_callnode node global.icfg)
  || (InterCfg.is_returnnode node global.icfg)

let debug_info global inputof_prev feature_prev static_feature qset history_old history dep_locs =
  if !Options.timer_debug then
    begin
      AlarmSet.iter (fun q ->
        prdbg_endline ("query: "^(Report.string_of_query q));
        prdbg_endline ("node: "^(Node.to_string q.node));
        prdbg_endline ("cmd: "^(InterCfg.cmdof global.icfg q.node |> IntraCfg.Cmd.to_string));
      ) qset;
      PowLoc.iter (fun x ->
        prdbg_endline (DynamicFeature.string_of_raw_feature x feature_prev static_feature);
        prdbg_endline ("History       : "^string_of_int
          (try History.find x history_old with _ -> -1)^ " -> " ^ string_of_int (try History.find x history with _ -> -1));
        prdbg_endline ("FI val        : "^(try Val.to_string (Mem.find x global.mem) with _ -> "Notfound"));
        let v = Table.fold (fun node mem ->
            if is_inter_node global node then Val.join (Mem.find x mem) else id) inputof_prev Val.bot in
        prdbg_endline ("FS val (inter): "^(Val.to_string v));
        ) dep_locs
    end

(* Remove undesired variables (already imprecise ones) in negative data. *)
let refine_negative_data global inputof_prev locset =
  PowLoc.filter (fun x ->
    let fs_v = Table.fold (fun node mem ->
      if is_inter_node global node then Val.join (Mem.find x mem) else id)
        inputof_prev Val.bot
    in
    let fi_v = Mem.find x global.mem in
    not (Val.eq fs_v Val.bot) && not (Val.eq fs_v fi_v)) locset

let extract_data_normal spec global access oc filename lst alarm_fs alarm_fi static_feature iteration =
  let filename = Filename.basename global.file.Cil.fileName in
  output_string oc ("# Iteration "^(string_of_int iteration)^" of "^ filename ^" begins\n");
  let dir = !Options.timer_dir in
  let final_idx = List.length lst in
  let alarm_final = MarshalManager.input ~dir (filename ^ ".alarm." ^ (string_of_int final_idx)) |> AlarmSet.of_list in
  let coarsen_history = try MarshalManager.input ~dir (filename ^ ".coarsen_history") with _ -> History.empty in
  let coarsen_history_old = try MarshalManager.input ~dir (filename ^ ".coarsen_history_old") with _ -> History.empty in
  let alarm_history = try MarshalManager.input ~dir (filename ^ ".alarm_history") with _ -> HistoryAlarm.empty in
  let alarm_history_old = try MarshalManager.input ~dir (filename ^ ".alarm_history_old") with _ -> HistoryAlarm.empty in
  MarshalManager.output ~dir (filename ^ ".coarsen_history_old") coarsen_history;
  MarshalManager.output ~dir (filename ^ ".alarm_history_old") alarm_history;
  let (pos_data, neg_data) = List.fold_left (fun (pos_data, neg_data) i ->
    try
      let (prev, idx, next) = (i, i + 1, i + 2) in
      prerr_endline ("Extract Data at " ^ string_of_int idx);
      let alarm_idx = MarshalManager.input ~dir (filename ^ ".alarm." ^ string_of_int idx) |> AlarmSet.of_list in
      let alarm_prev = MarshalManager.input ~dir (filename ^ ".alarm." ^ string_of_int prev) |> AlarmSet.of_list in
      let alarm_next = try MarshalManager.input ~dir (filename ^ ".alarm." ^ string_of_int next) |> AlarmSet.of_list with _ -> alarm_final in
      let inputof_prev = MarshalManager.input ~dir (filename ^ ".inputof." ^ string_of_int prev) in
      let dug = MarshalManager.input ~dir (filename ^ ".dug." ^ string_of_int prev) in
      let feature_prev = MarshalManager.input ~dir (filename ^ ".feature." ^ string_of_int prev) in
      if Sys.file_exists (dir^"/"^filename^".alarm."^string_of_int next) then
        let _ = output_string oc ("#\t\tIdx : " ^(string_of_int idx) ^ "\n") in
        (* 2. Update w to coarsen variables that are related to the FS alarms earlier *)
        output_string oc ("#\t\t\tPositive Data. "^(string_of_int next)^" -> " ^ (string_of_int prev)^"\n");
        prdbg_endline ("Type 2 Data at " ^ string_of_int idx);
        let inter =
          (* coarsen vars related with the FS-alarms at idx 1 and 2 *)
          if idx = 2 then AlarmSet.inter alarm_fs alarm_next
          else AlarmSet.inter alarm_fs (AlarmSet.diff alarm_next alarm_idx)
        in
        let inter =
          AlarmSet.filter (fun x ->
              try
                let old_position = HistoryAlarm.find x alarm_history_old in
                let new_position = HistoryAlarm.find x alarm_history in
                old_position > new_position
              with _ -> true) inter
        in
(*         let inter = AlarmSet.inter alarm_fs alarm_next in *)
        output_string oc ("#\t\t\t\tnumber of alarm next: "^(string_of_int (AlarmSet.cardinal alarm_next))^"\n");
        output_string oc ("#\t\t\t\tnumber of alarm idx: "^(string_of_int (AlarmSet.cardinal alarm_idx))^"\n");
        output_string oc ("#\t\t\t\tnumber of alarm diff & fs: "^(string_of_int (AlarmSet.cardinal inter))^"\n");
        (* locs related to FS-alarms *)
        let pos_locs =
          Dependency.dependency_of_query_set_new false global dug access inter
          |> PowLoc.filter (fun x -> (DynamicFeature.PowLocBit.mem (LocHashtbl.find feature_prev.DynamicFeature.encoding x) feature_prev.DynamicFeature.non_bot))
        in
        debug_info global inputof_prev feature_prev static_feature inter coarsen_history_old coarsen_history pos_locs;
        output_string oc ("#\t\t\t\tPos: "^(string_of_int (PowLoc.cardinal pos_locs))^"\n");
(*        let pos_locs =
          PowLoc.filter (fun x ->
              try
                let old_position = History.find x coarsen_history_old in
                let new_position = History.find x coarsen_history in
                old_position > new_position
              with _ -> true) pos_locs
        in*)
        output_string oc ("#\t\t\t\tPos (after filtering): "^(string_of_int (PowLoc.cardinal pos_locs))^"\n");
        prdbg_endline ("Pos Data : " ^ PowLoc.to_string pos_locs);
        (* 3. Update w to coarsen variable *)
        output_string oc ("#\t\t\tNegative Data. "^(string_of_int idx)^" -> " ^ (string_of_int next)^"\n");
        output_string oc ("#\t\t\t\tnumber of alarm prev: "^(string_of_int (AlarmSet.cardinal alarm_prev))^"\n");
        output_string oc ("#\t\t\t\tnumber of alarm idx: "^(string_of_int (AlarmSet.cardinal alarm_idx))^"\n");
        prdbg_endline ("Negative Data at " ^ string_of_int idx);
        let diff = AlarmSet.diff (AlarmSet.diff alarm_idx alarm_prev) alarm_fs in
(*         let diff = AlarmSet.diff alarm_final alarm_fs in *)
        let diff =
          AlarmSet.filter (fun x ->
              try
                let old_position = HistoryAlarm.find x alarm_history_old in
                let new_position = HistoryAlarm.find x alarm_history in
                old_position < new_position
              with _ -> true) diff
        in
        output_string oc ("#\t\t\t\tnumber of alarm diff & non-fs: "^(string_of_int (AlarmSet.cardinal diff))^"\n");
        let locs_of_alarms =
          Dependency.dependency_of_query_set_new false global dug access diff
          |> refine_negative_data global inputof_prev
        in
        debug_info global inputof_prev feature_prev static_feature diff coarsen_history_old coarsen_history locs_of_alarms;
        let neg_locs = locs_of_alarms in
        output_string oc ("#\t\t\t\tNeg: "^(PowLoc.cardinal neg_locs |> string_of_int)^"\n");
(*
        let neg_locs =
          PowLoc.filter (fun x ->
              try
                let old_position = History.find x coarsen_history_old in
                let new_position = History.find x coarsen_history in
                old_position < new_position
              with _ -> true) neg_locs
        in
*)
        prdbg_endline ("Neg Data : " ^ PowLoc.to_string neg_locs);
        output_string oc ("#\t\t\t\tNeg (after filter): "^(PowLoc.cardinal neg_locs |> string_of_int)^"\n");
(*         MarshalManager.output ~dir (filename ^ ".coarsen.score." ^ string_of_int prev) (coarsen_score_pos1_new, coarsen_score_pos2_new, coarsen_score_neg_new); *)
        let conflict = PowLoc.inter pos_locs neg_locs in
        output_string oc ("#\t\t\tSummary at "^(string_of_int idx)^"\n");
        output_string oc ("#\t\t\t\tpositive : "^(string_of_int (PowLoc.cardinal pos_locs))^"\n");
        output_string oc ("#\t\t\t\tnegative : "^(string_of_int (PowLoc.cardinal neg_locs))^"\n");
        output_string oc ("#\t\t\t\tconflict : "^(string_of_int (PowLoc.cardinal conflict))^"\n");
        let pos_data = PowLoc.fold (fun x pos_data ->
            if PowLoc.mem x conflict then pos_data
            else (prev, x, feature_prev)::pos_data) pos_locs pos_data in
        let neg_data = PowLoc.fold (fun x neg_data ->
(*            if PowLoc.mem x conflict then neg_data
            else*) (prev, x, feature_prev)::neg_data) neg_locs neg_data in
        (pos_data, neg_data)
      else
        (pos_data, neg_data)
    with _ -> (pos_data, neg_data)
  ) ([], []) lst
  in
  output_string oc ("# Iteration "^(string_of_int iteration)^" completes\n");
  output_string oc ("# Summary\n");
  let conflict =
    BatSet.intersect
      (List.fold_left (fun set (i, x, _) -> BatSet.add (i, Loc.to_string x) set) BatSet.empty pos_data)
      (List.fold_left (fun set (i, x, _) -> BatSet.add (i, Loc.to_string x) set) BatSet.empty neg_data)
  in
  output_string oc ("# positive : "^(string_of_int (List.length pos_data))^"\n");
  output_string oc ("# negative : "^(string_of_int (List.length neg_data))^"\n");
  output_string oc ("# conflict : "^(string_of_int (BatSet.cardinal conflict))^"\n");
  (pos_data, neg_data)

let extract_data spec global access iteration  =
  let filename = Filename.basename global.file.Cil.fileName in
  let dir = !Options.timer_dir in
  let oc = open_out_gen [Open_creat; Open_append; Open_text] 0o640 (!Options.timer_dir ^ "/" ^ filename ^ ".tr_data.dat.raw") in
  let alarm_fs = MarshalManager.input (filename ^ ".alarm") |> flip Report.get Report.UnProven |> AlarmSet.of_list in
  let alarm_fi = spec.Spec.pre_alarm |> flip Report.get Report.UnProven |> AlarmSet.of_list in
  let final_idx =
    Sys.readdir dir
    |> Array.to_list
    |> List.filter (fun x ->
        Str.string_match (Str.regexp (Str.quote filename ^ "\\.alarm\\.[1-9]+")) x 0)
    |> List.length
  in
  let static_feature = MarshalManager.input ~dir (filename ^ ".static_feature") in
  let lst = BatList.range 1 `To final_idx in
  let alarm_final = MarshalManager.input ~dir (filename ^ ".alarm." ^ (string_of_int final_idx)) |> AlarmSet.of_list in
  let (pos_data, neg_data) =
      extract_data_normal spec global access oc filename lst alarm_fs alarm_fi static_feature iteration
  in
  close_out oc;
  let oc = open_out_gen [Open_creat; Open_append; Open_text] 0o640 (!Options.timer_dir ^ "/" ^ filename ^ ".tr_data.dat") in
  output_string oc "# Iteration\n";
  List.iter (fun (_, x, feature) ->
    output_string oc (DynamicFeature.string_of_raw_feature x feature static_feature ^ " : 1\n")) pos_data;
  List.iter (fun (_, x, feature) ->
    output_string oc (DynamicFeature.string_of_raw_feature x feature static_feature ^ " : 0\n")) neg_data;
  if !Options.timer_oracle_rank || !Options.timer_counter_example then
  begin
    let filename = Filename.basename global.file.Cil.fileName in
    let oracle = try MarshalManager.input ~dir:!Options.timer_dir (filename^".oracle") with _ -> prerr_endline "Can't find the oracle"; BatMap.empty in
    let oracle = List.fold_left (fun oracle (prev, x, feature) ->
      BatMap.add (prev, Loc.to_string x) 1.0 oracle) oracle pos_data in
    let oracle = List.fold_left (fun oracle (prev, x, feature) ->
      BatMap.add (prev, Loc.to_string x) (0.0) oracle) oracle neg_data in
      MarshalManager.output ~dir (filename^".oracle") oracle
  end;
  let score = List.fold_left (fun score i ->
      try
        let (prev, idx) = (i - 1, i) in
        let alarm_idx = MarshalManager.input ~dir (filename ^ ".alarm." ^ string_of_int idx) |> AlarmSet.of_list in
        let alarm_prev = if i = 0 then AlarmSet.empty else MarshalManager.input ~dir (filename ^ ".alarm." ^ string_of_int prev) |> AlarmSet.of_list in
        let new_alarm = AlarmSet.diff alarm_idx alarm_prev in
        let inter = AlarmSet.inter alarm_fs new_alarm in
        (* score 1: for FS-alarms (d - t) / d *)
        let score1 = ((float_of_int (final_idx - idx))
                     /. float_of_int final_idx)
                     *. (float_of_int (AlarmSet.cardinal inter))
                     /. (float_of_int (AlarmSet.cardinal alarm_final))
        in
        (* score 2: for non-FS-alarms t / d *)
        let score2 = (float_of_int idx)
                     /. (float_of_int final_idx)
                     *. float_of_int (AlarmSet.cardinal (AlarmSet.diff new_alarm inter))
                     /. (float_of_int (AlarmSet.cardinal alarm_final))
        in
        prerr_endline ("idx : " ^ string_of_int idx);
        prerr_endline ("# alarms in FS-alarm before deadline: " ^ string_of_int (AlarmSet.cardinal inter));
        prerr_endline ("# alarms not in FS-alarm before deadline: " ^ string_of_int (AlarmSet.cardinal (AlarmSet.diff new_alarm inter)));
        score +. score1 +. score2
      with _ -> score) 0.0 (0::lst)
  in
  prerr_endline ("Score of proxy: " ^ string_of_float score);
  exit 0

let extract_feature spec global alarms_part new_alarms_part inputof timer =
  if !Options.timer_static_rank then timer
  else
    { timer with
      dynamic_feature = DynamicFeature.extract spec global alarms_part
          new_alarms_part timer.old_inputof inputof timer.dynamic_feature }

let select global spec timer num_of_coarsen =
  match strategy with
  | Rank -> rank_strategy global spec timer num_of_coarsen
  | Clf -> PowLoc.empty (* XXX clf_strategy global timer*)

let history_to_json history cost old_json =
  let state_to_json feat action =
    List.fold_left (fun l num ->
        l@[`Float num]) [] (feat@[action])
  in
  let history = List.fold_left (fun l (feat, action) ->
      (`List (state_to_json feat action))::l) [] history
  in
  let new_json = `Assoc [ ("history", `List history); ("log", `String ("log"^string_of_int !Options.timer_iteration)); ("cost", `Float cost) ] in
  match old_json with
  | `Null -> prerr_endline "yojson null"; `List [new_json]
  | `List l -> `List (new_json :: l)
  | _ -> assert false

let save_history global cost =
(*   let filename = Filename.basename global.file.Cil.fileName in *)
  let old_json =
    if Sys.file_exists (!Options.timer_clf ^ ".mcts") then
      Yojson.Safe.from_file (!Options.timer_clf ^ ".mcts")
    else
      `Null
  in
  let json = history_to_json !timer.history cost old_json in
  (try
     Unix.unlink (!Options.timer_clf ^ ".mcts")
   with _ -> ());
  let oc = open_out_gen [Open_creat; Open_wronly; Open_text] 0o640 (!Options.timer_clf ^ ".mcts") in
  Yojson.Safe.pretty_to_channel oc json;
(*   output_string oc ("Alarm : " ^ (string_of_int (BatMap.cardinal new_alarms_part)) ^"\n"); *)
  close_out oc

let finalize ?(out_of_mem=false) spec global dug inputof =
  let num_of_alarms =
    if out_of_mem then !Options.timer_fi_alarm
    else
      let alarms = (BatOption.get spec.Spec.inspect_alarm) global spec inputof |> flip Report.get Report.UnProven in
      let new_alarms_part = Report.partition alarms in
      if !Options.timer_debug then
        begin
          Report.display_alarms ~verbose:0 ("Alarms at "^string_of_int !timer.time_stamp) new_alarms_part
        end;
      (* TODO: revert the following when dynamic learning is necessary *)
    (*   timer_dump global dug inputof DynamicFeature.empty_feature alarms PowLoc.empty !timer.time_stamp; *)
      BatMap.cardinal new_alarms_part
  in
  Lymp.close !timer.py;
  (if !Options.timer_training then
     let cost = float_of_int (num_of_alarms - !Options.timer_fs_alarm) /. float_of_int (!Options.timer_fi_alarm - !Options.timer_fs_alarm) in
     save_history global cost);
  prerr_memory_usage ()

let coarsening_fs spec global access dug worklist inputof outputof =
  let (spec, dug, worklist, inputof, outputof) =
    if !timer.widen_start = 0.0 then initialize spec global access dug worklist inputof outputof (* initialize *)
    else (spec, dug, worklist, inputof, outputof)
  in
  let t0 = Sys.time () in
  let elapsed = t0 -. !timer.last in
(*   if elapsed > (float_of_int !timer.threshold) then *)

  let used = memory_usage () in
  if used > !timer.total_memory then
    let _ = prerr_endline ("\nOut of Memory: " ^ string_of_int used) in
    finalize ~out_of_mem:true spec global dug inputof;
    exit 0
  else if used > !timer.current_memory then
    let _ = prerr_endline ("\n== Timer: Coarsening #"^(string_of_int !timer.time_stamp)^" starts at " ^ (string_of_float elapsed)) in
    let _ = prerr_endline ("==Mem0 : " ^ string_of_int used) in
    let _ = prerr_memory_info !timer in
    let num_of_locset_fs = PowLoc.cardinal spec.Spec.locset_fs in
    let num_of_locset = LocHashtbl.length DynamicFeature.locset_hash in
    let num_of_coarsen = coarsen_portion global !timer worklist inputof in
    if num_of_locset_fs = 0 || num_of_coarsen = 0 then
      let _ = timer := { !timer with last = Sys.time ();
                             time_stamp = !timer.time_stamp + 1;
                             num_of_coarsen = !timer.num_of_coarsen + num_of_coarsen;
                             current_memory = used;
                             (*old_inputof = inputof; *)}
      in
      (spec, dug, worklist, inputof, outputof)
    else
      let _ = Profiler.reset () in
      let alarms = (BatOption.get spec.Spec.inspect_alarm) global spec inputof |> flip Report.get Report.UnProven in
      let new_alarms = get_new_alarms alarms in
      let alarms_part = Report.partition alarms in
      let new_alarms_part = Report.partition new_alarms in
      timer := extract_feature spec global alarms_part new_alarms_part inputof !timer;
      prerr_endline ("\n== Timer: feature extraction took " ^ string_of_float (Sys.time () -. t0));
      let t1 = Sys.time () in
      let locset_coarsen = select global spec !timer num_of_coarsen in
      let num_of_coarsen = PowLoc.cardinal locset_coarsen in
      (if !Options.timer_dump then timer_dump global dug inputof !timer.dynamic_feature alarms locset_coarsen !timer.time_stamp);
      prerr_endline ("\n== Timer: Predict took " ^ string_of_float (Sys.time () -. t1));
      let num_of_works = Worklist.cardinal worklist in
      let t2 = Sys.time () in
      let (spec, dug, worklist, inputof, outputof) = coarsening global access locset_coarsen dug worklist inputof outputof spec in
      prerr_endline ("\n== Timer: Coarsening dug took " ^ string_of_float (Sys.time () -. t2));
      prerr_endline ("Unproven Query          : " ^ string_of_int (BatMap.cardinal new_alarms_part));
      prerr_endline ("Unproven Query (acc)    : " ^ string_of_int (BatMap.cardinal alarms_part));
      prerr_endline ("Coarsening Target       : " ^ string_of_int num_of_coarsen ^ " / " ^ string_of_int num_of_locset);
(*      prerr_endline ("Coarsening Target (acc) : " ^ string_of_int (LocHashtbl.length locset_fi_hash) ^ " / " ^ string_of_int num_of_locset);*)
      prerr_endline ("Analyzed Node           : " ^ string_of_int (PowNode.cardinal !SparseAnalysis.reach_node) ^ " / " ^ string_of_int !SparseAnalysis.nb_nodes);
      prerr_endline ("#Abs Locs on Dug        : " ^ string_of_int (DUGraph.nb_loc dug));
      prerr_endline ("#Node on Dug            : " ^ string_of_int (DUGraph.nb_node dug));
      prerr_endline ("#Worklist               : " ^ (string_of_int num_of_works) ^ " -> "^(string_of_int (Worklist.cardinal worklist)));
      prerr_endline ("Memory Usage            : " ^ string_of_int (memory_usage ()));
(*       prdbg_endline ("Coarsened Locs : \n\t"^PowLoc.to_string locset_coarsen); *)
      (if !Options.timer_debug then Report.display_alarms ~verbose:0 ("Alarms at "^string_of_int !timer.time_stamp) new_alarms_part);
      prerr_endline ("== Timer: Coarsening took " ^ string_of_float (Sys.time () -. t0));
      prerr_endline ("== Timer: Coarsening completes at " ^ string_of_float (Sys.time () -. !timer.widen_start));
      Profiler.report stdout;
      timer := { !timer with last = Sys.time ();
        time_stamp = !timer.time_stamp + 1;
        current_memory = memory_usage ();
        num_of_coarsen = !timer.num_of_coarsen + num_of_coarsen;
        (*old_inputof = inputof; *)};
      (spec,dug,worklist,inputof, outputof)
  else (spec, dug, worklist, inputof, outputof)
