open Mods
open Tools
open ExceptionDefn
open Random_tree

(** random exponential selection if finite, next perturbation time if
infinite ... *)
let determine_time_advance activity state counter env =
  let rd = Random.float 1.0 in
  let dt = -. (log rd /. activity) in
  if dt <> infinity && activity > 0. then dt
  else
    let depset = Environment.get_dependencies Term.TIME env in
    Term.DepSet.fold
      (fun dep dt ->
       match dep with
       | Term.PERT p_id ->
	  begin match State.maybe_find_perturbation p_id state with
		| None -> dt
		| Some _ -> match Mods.Counter.dT counter with
			    | Some dt -> dt
			    | None -> Mods.Counter.last_increment counter
	  end
       | _ -> dt
      ) depset infinity

let event state maybe_active_pert_ids story_profiling
	  event_list counter plot env =
  (* 1. Updating dependencies of time or event number *)
  let env,pert_ids =
    State.update_dep state Term.EVENT maybe_active_pert_ids counter env in
  let env,pert_ids =
    State.update_dep state Term.TIME pert_ids counter env in
  (* 2. Applying perturbations *)
  let state,remain_pert_ids,env,obs_from_perturbation,pert_events =
    External.try_perturbate [] state pert_ids [] counter env
  in
  (* Adding perturbation event to story -if any *)
  let story_profiling,event_list,cpt =
    if Environment.tracking_enabled env then (*if logging events is required*)
      let story_profiling,event_list,cpt =
	List.fold_left
	  (fun (story_prof,event_list,cpt) (r,phi,psi,side_effects) ->
	   let sp,el =
	       Compression_main.D.S.PH.B.PB.CI.Po.K.store_event
		 story_prof
		 (Compression_main.D.S.PH.B.PB.CI.Po.K.import_event
		    ((r,phi,psi),(obs_from_perturbation,r,cpt+1,side_effects))) event_list (*we are adding several events with the same id in the grid!*)
	   in
	   (sp,el,cpt+1)
	  ) (story_profiling,event_list,Counter.event counter) pert_events
      in
      (story_profiling,event_list,cpt)
    else
      (story_profiling,event_list,Counter.event counter)
  in
  let () = counter.Counter.perturbation_events <- cpt in

  (*3. Time advance*)
  let activity = State.total_activity state in
  if activity < 0. then invalid_arg "Activity invariant violation" ;
  let activity = abs_float activity (* -0 must become +0 *) in
  let dt = determine_time_advance activity state counter env in
  let () = if dt = infinity || activity <= 0. then
	     begin
	       if !Parameter.dumpIfDeadlocked then
		 let desc = if !Parameter.dotOutput
			    then open_out "deadlock.dot"
			    else open_out "deadlock.ka" in
		 let () =
		   State.snapshot state counter desc true env in
		 close_out desc
	       else () ;
	       raise Deadlock
	     end in
  Plot.fill state counter plot env dt ;
  Counter.inc_time counter dt ;

  State.dump state counter env ;

  let restart =
    match External.has_reached_a_stopping_time state counter env with
    | Some t ->
       let () =
	 Debug.tag_if_debug
	   "Next event time is beyond perturbation time, applying null event and resetting clock to %a"
	   Nbr.print t
       in let () = counter.Counter.time <- Nbr.to_float t in
	  let () = Counter.stat_null 5 counter in true
    | None -> false
  in

  (*4. Draw rule*)
  if !Parameter.debugModeOn then
    Debug.tag (Printf.sprintf "Drawing a rule... (activity=%f) " (State.total_activity state));

  (*let t_draw = StoryProfiling.start_chrono () in*)
  let opt_instance,state =
    if restart then (None,state)
    else
      try State.draw_rule state counter env with
      | Null_event i -> (Counter.stat_null i counter ; (None,state))
  in

  (*5. Apply rule & negative update*)
  let opt_new_state =
    match opt_instance with
    | None -> None
    | Some (r,embedding_t) ->
       (**********************************************)
       if !Parameter.debugModeOn then
	 begin
	   let version,embedding = match embedding_t with
	     | State.Embedding.DISJOINT emb -> ("binary",emb.State.Embedding.map)
	     | State.Embedding.CONNEX emb -> ("unary",emb.State.Embedding.map)
	     | State.Embedding.AMBIGUOUS emb -> ("ambig.",emb.State.Embedding.map)
	   in
	   Debug.tag
	     (Printf.sprintf "Applying %s version of '%s' with embedding:" version
			     (Dynamics.to_kappa r env)
	     );
	   Debug.tag (Printf.sprintf "%s" (string_of_map string_of_int string_of_int IntMap.fold embedding))
	 end
       else () ;
       (********************************************)
       try Some (State.apply state r embedding_t counter env,r)
       with Null_event _ -> None
  in

  (*6. Positive update*)

  let env,state,pert_ids,story_profiling,event_list =
    match opt_new_state with
    | None ->
       begin
	 if !Parameter.debugModeOn then Debug.tag "Null (clash or doesn't satisfy constraints)";
	 Counter.inc_null_events counter ;
	 Counter.inc_consecutive_null_events counter ;
	 (env,state,remain_pert_ids,story_profiling,event_list)
       end
    | Some ((env,state,side_effect,embedding_t,psi,pert_ids_rule),r) ->
       Counter.inc_events counter ;
       counter.Counter.cons_null_events <- 0;
       (*resetting consecutive null event counter since a real rule was applied*)
       let pert_ids = IntSet.union remain_pert_ids pert_ids_rule in

       (*Local positive update: adding new partial injection*)
       let env,state,pert_ids',new_injs,obs_from_rule_app =
	 State.positive_update state r (State.Embedding.map_of embedding_t,psi)
			       (side_effect,Int2Set.empty) counter env
       in

       (*Non local positive update: adding new possible intras*)
       let state =
	 if env.Environment.has_intra then
	   NonLocal.positive_update r embedding_t new_injs state counter env
	 else state
       in

       if !Parameter.safeModeOn then
	 State.Safe.check_invariants (State.Safe.check 4) state counter env ;
       (****************END POSITIVE UPDATE*****************)

       (****************CFLOW PRODUCTION********************)
       let phi = State.Embedding.map_of embedding_t in

       let story_profiling,event_list =
	 if Environment.tracking_enabled env then (*if logging events is required*)
	   begin
	     let story_profiling,event_list =
	       Compression_main.D.S.PH.B.PB.CI.Po.K.store_event story_profiling (Compression_main.D.S.PH.B.PB.CI.Po.K.import_event ((r,phi,psi),(obs_from_rule_app,r,Counter.event counter,side_effect))) event_list
	     in
	     (story_profiling,event_list)
	   end
         else
	   (story_profiling,event_list)
       in
       let story_profiling,event_list =
         if Environment.tracking_enabled env && !Parameter.causalModeOn then (*if tracking the observable is required*)
           begin
	     let simulation_info =
	       {Mods.story_id=  0 ;
		Mods.story_time= counter.Mods.Counter.time ;
		Mods.story_event= counter.Mods.Counter.events ;
		Mods.profiling_info = ()}
	     in
	     let story_profiling,event_list =
	       List.fold_left
		 (fun (story_profiling,event_list) (obs,phi) ->
		  let lhs = State.kappa_of_id obs state in
		  Compression_main.D.S.PH.B.PB.CI.Po.K.store_obs story_profiling (obs,lhs,phi,simulation_info) event_list
		 )
		 (story_profiling,event_list) obs_from_rule_app
	     in
	     (story_profiling,event_list)
	   end
	 else
	   (story_profiling,event_list)
       in
       (**************END CFLOW PRODUCTION********************)
       (env,state,IntSet.union pert_ids pert_ids',story_profiling,event_list)
  in
  (state,pert_ids,story_profiling,event_list,env)

let loop state story_profiling event_list counter plot env =
  (*Before entering the loop*)
  
  Counter.tick counter counter.Counter.time counter.Counter.events ;
  Plot.output state counter.Counter.time plot env counter ;
  
  let rec iter state pert_ids story_profiling event_list counter plot env =
    if !Parameter.debugModeOn then 
      Debug.tag (Printf.sprintf "[**Event %d (Activity %f)**]" counter.Counter.events (State.total_activity state));
    if (Counter.check_time counter) && (Counter.check_events counter) && not (Counter.stop counter) then
      let state,pert_ids,story_profiling,event_list,env =
	event state pert_ids story_profiling event_list counter plot env
      in
      iter state pert_ids story_profiling event_list counter plot env
    else (*exiting the loop*)
      begin
	let _ = 
	  Plot.fill state counter plot env 0.0; (*Plotting last measures*)
	  Plot.flush_ticks counter ;
	  Plot.close plot
	in 
        if Environment.tracking_enabled env then
	  begin
	    let causal,weak,strong = (*compressed_flows:[(key_i,list_i)] et list_i:[(grid,_,sim_info option)...] et sim_info:{with story_id:int story_time: float ; story_event: int}*)
              if !Parameter.weakCompression || !Parameter.mazCompression || !Parameter.strongCompression (*if a compression is required*)
              then Compression_main.compress env state story_profiling event_list
              else None,None,None
	    in
	    let g prefix label x = 
	      match x with 
	      | None -> ()
	      | Some flows -> 
		 Causal.pretty_print Graph_closure.config_std prefix label flows state env
	    in 
	    let _ = g "" "" causal in 
	    let _ = g "Weakly" "weakly " weak in 
	    let _ = g "Strongly" "strongly " strong in 
	    ()
	  end
      end
  in
  iter state (State.all_perturbations state) story_profiling event_list counter plot env
