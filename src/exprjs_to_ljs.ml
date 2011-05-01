open Prelude

module E = Exprjs_syntax
module S = Es5_syntax

let rec exprjs_to_ljs (e : E.expr) : S.exp = match e with
  | E.True (p) -> S.True (p)
  | E.False (p) -> S.False (p)
  | E.Num (p, n) -> S.Num (p, n)
  | E.Undefined (p) -> S.Undefined (p)
  | E.Null (p) -> S.Null (p)
  | E.String (p, s) -> S.String (p, s)
  | E.ObjectExpr (p, pl) ->
    (* Given a tuple, if it's a getter/setter, create a name-accessor pair and add to
     * sofar *)
    let add_accessor pr sofar = match pr with
      | (_, _, E.Getter (nm, exp)) ->
        let gval = get_fobj p [] exp (S.Id (p, "%context")) in
        let a = { S.getter = gval; S.setter = S.Undefined (p); } in
        (nm, S.Accessor (a, true, true)) :: sofar
      | (_, _, E.Setter (nm, exp)) ->
        let (param_name, sfunc) = match exp with
          | E.LetExpr (_, nm, _, body) -> (nm, body)
          | _ -> failwith "setter desugaring error: expected LetExpr here" in
        let sval = get_fobj p [param_name] sfunc (S.Id (p, "%context")) in
        let a = { S.getter = S.Undefined (p); S.setter = sval; } in
        (nm, S.Accessor (a, true, true)) :: sofar
          (*
        let sval = get_fobj p ["%setterparam"] exp (S.Id (p, "%context")) in
        let a = { S.getter = S.Undefined (p); S.setter = sval; } in
        (nm, S.Accessor (a, true, true)) :: sofar
    *)
      | _ -> sofar in
    (* Given a list of tuples, produce a list of name, accessor pairs *)
    let rec accessors tl sofar = match tl with
      | [] -> sofar
      | t :: rest -> accessors rest (add_accessor t sofar) in
    (* Get only those pairs with name = nm *)
    let tuples tl nm = List.filter (fun (n, _) -> n = nm) tl in
    (* Given a list of name-accessor pairs, reduce them to one *)
    let rec reduce al result = match al with
      | [] -> result
      | (nm, S.Accessor (a, wr, cfg)) :: rest ->
        let result_a = match result with
          | S.Accessor (aa, _, _) -> aa in
        let next = match a with
          | { S.getter = S.Undefined _; S.setter = s; } ->
            S.Accessor ({ S.getter = result_a.S.getter; S.setter = s; }, wr, cfg)
          | { S.getter = g; S.setter = S.Undefined _; } ->
            S.Accessor ({ S.getter = g; S.setter = result_a.S.setter; }, wr, cfg)
          | _ -> S.Accessor (a, wr, cfg) in
        reduce rest next in
    let dup_pairs = accessors pl [] in
    let name_lst = remove_dupes (map (fun (n, _) -> n) dup_pairs) in
    let name_assoc = map (fun n -> (n, tuples dup_pairs n)) name_lst in
    let dummy_prop = 
      S.Accessor (
        { S.getter = S.Undefined (p); S.setter = S.Undefined (p); }, true, true) in
    let reduced_assoc = map (fun (n, al) -> (n, reduce al dummy_prop)) name_assoc in
    let data_props = 
      List.filter (fun p -> let result = 
        match p with (_, _, E.Data _) -> true | _ -> false in result) pl in
    let rec ejsprop_to_sprop pr = match pr with
      | E.Data (e) -> 
          let rec v = exprjs_to_ljs e
          and d = { S.value = v; S.writable = true; } in
          S.Data (d, true, true)
      | E.Getter (nm, e) -> failwith "getters unimplemented"
      | E.Setter (nm, e) -> failwith "setters unimplemented"
    and tuple_to_prop t = match t with
      (p, s, pr) -> (s, ejsprop_to_sprop pr)
    and form_props props = match props with
      | [] -> []
      | first :: rest -> (tuple_to_prop first) :: form_props rest in
    let data_result = form_props data_props in
    S.Object (p, S.d_attrs, List.append reduced_assoc data_result)
  | E.ThisExpr (p) -> failwith "ThisExpr nyi"
  | E.IdExpr (p, nm) -> S.Id (p, nm)
  | E.BracketExpr (p, l, r) -> 
    let o = exprjs_to_ljs l
    and f = S.Op1 (p, "prim->str", exprjs_to_ljs r) in
    let argsobj = S.Object (p, S.d_attrs, []) in
    S.GetField (p, o, f, argsobj)
  | E.PrefixExpr (p, op, exp) -> S.Op1 (p, op, exprjs_to_ljs exp)
  | E.InfixExpr (p, op, l, r) -> let op = match op with
    | "===" -> "abs="
    | "==" -> "stx="
    | _ -> op in
    S.Op2 (p, op, exprjs_to_ljs l, exprjs_to_ljs r)
  | E.IfExpr (p, e1, e2, e3) -> let e1 = exprjs_to_ljs e1
    and e2 = exprjs_to_ljs e2
    and e3 = exprjs_to_ljs e3 in S.If (p, e1, e2, e3)
  | E.AssignExpr (p, obj, pr, vl) -> 
    let sobj = exprjs_to_ljs obj
    and spr = exprjs_to_ljs pr
    and svl = exprjs_to_ljs vl in
    let arecd = { S.value = svl; S.writable = true; } in
    let aprop = S.Data (arecd, true, true) in
    let aobj = S.Object (p, S.d_attrs, [("0", aprop)]) in
    S.SetField (p, sobj, spr, svl, aobj)
  | E.SeqExpr (p, e1, e2) -> S.Seq (p, exprjs_to_ljs e1, exprjs_to_ljs e2)
  | E.AppExpr (p, e, el) -> 
    let sl = List.map (fun x -> exprjs_to_ljs x) el
    and f = exprjs_to_ljs e in 
    let n_args = List.length sl in
    let indices = Prelude.iota n_args in
    let combined = List.combine indices sl in
    let records =
      List.map (fun (n, arg) -> (n, {S.value = arg; S.writable = true})) combined in
    let props = 
      List.map 
        (fun (n, rcrd) -> (string_of_int n, S.Data (rcrd, true, true))) records in
    let args_obj = S.Object (p, S.d_attrs, props) in
    S.App (p, f, [S.Id (p, "%this"); args_obj])
  | E.FuncExpr (p, args, body) -> get_fobj p args body (S.Id (p, "%context"))
  | E.FuncStmtExpr (p, nm, args, body) -> 
    let fobj = get_fobj p args body (S.Id (p, "%context")) in
    let arcrd = { S.value = fobj; S.writable = true; } in
    let aprop = S.Data (arcrd, true, true) in
    let aprops = [("0", aprop)] in
    let argsobj = S.Object (p, S.d_attrs, aprops) in
    S.SetField (p, S.Id (p, "%context"), S.String (p, nm), fobj, argsobj)
  | E.LetExpr (p, nm, vl, body) -> normal_let e
      (*
    let sv = exprjs_to_ljs vl
    and sb = exprjs_to_ljs body in
    let result_obj = match nm with
      | "%context" -> let orig_props = match sv with
        | S.Object (_, _, pl) -> pl
        | _ -> failwith "let bound %context to a non-object" in
        let c_attrs = { S.code = None;
                        S.proto = Some (S.Id (p, "%context"));
                        S.klass = "Object";
                        S.extensible = true; } in
        S.Object (p, c_attrs, orig_props)
      | _ -> sv in
    S.Let (p, nm, result_obj, sb)
    *)
  | E.BreakExpr (p, id, e) ->
    S.Break (p, id, exprjs_to_ljs e)
  | _ -> failwith "unimplemented exprjs type"

and get_fobj p args body context = 
  let call = get_lambda p args body in
  let fobj_attrs = 
    { S.code = Some (call); S.proto = Some (S.Null (p)); S.klass = "Function"; 
    S.extensible = true; } in
  let param_len = List.length args in
  let indices = Prelude.iota param_len in
  let combined = List.combine indices args in
  let rcds =
    List.map (fun (n, prm) -> (n, {S.value = S.String (p, prm); S.writable =
      true;})) combined in
  let props =
    List.map (fun (n, rcd) -> (string_of_int n, S.Data (rcd, false, false)))
    rcds in
  let param_obj = S.Object (p, S.d_attrs, props) in
  S.Let (p, "%parent", context,
    S.Let (p, "%params", param_obj,
      S.Object (p, fobj_attrs, [])))

and get_lambda p args body = 
  (* getter = function () {return %context["%y"];} *)
  let getter nm = 
    S.Lambda (p, ["this"; "args"], 
    S.Label (p, "%ret",
    S.Break (p, "%ret",
    S.GetField (p, S.Id (p, "%context"), S.String (p, "%" ^ nm), S.Null (p)))))
  (* setter = function(newY) {%context["%y"] = newy;} *)
  and setter nm =
    let newval = S.GetField (p, S.Id (p, "args"), S.String (p, "0"), S.Null (p)) in
    S.Lambda (p, ["this"; "args"],
    S.Label (p, "%ret",
    S.Break (p, "%ret",
    S.SetField (p, S.Id (p, "%context"), S.String (p, "%" ^ nm), 
      newval, S.Null (p))))) in
  (* Strip the lets from the top of the function body, and get a tuple containig
   * the name of all those ids (declared with var keyword) and the actual
   * function body *)
  let rec strip_lets e nms = match e with
    | E.LetExpr (p, nm, vl, rst) ->
      let prefix = String.sub nm 0 2 in
      if prefix = "%%" then
        let l = (String.length nm) - 2 in
        let next_nms = (String.sub nm 2 l) :: nms in strip_lets rst next_nms
      else
        let (final_nms, final_e) = strip_lets rst nms in
        (final_nms, E.LetExpr (p, nm, vl, final_e))
    | _ -> (nms, e) in
  (* For each name, create a data/accessor property *)
  let rec get_prop_pairs nms prs = match nms with
    | [] -> prs
    | nm :: rest ->
      let data_name = "%" ^ nm in
      let drc = { S.value = S.Undefined (p); S.writable = true; } in
      let d = S.Data (drc, true, true) in
      let arc = { S.getter = getter nm; S.setter = setter nm; } in
      let a = S.Accessor (arc, true, true) in
      get_prop_pairs rest ((data_name, d) :: ((nm, a) :: prs)) in
  let (nl, real_body) = strip_lets body [] in
  let prop_pairs = get_prop_pairs nl [] in
  let desugared = exprjs_to_ljs real_body in
  let final = 
    S.Seq (p,
      S.SetField (p, S.Id (p, "%context"), S.String (p, "arguments"), S.Id (p,
      "%args"), S.Null (p)), desugared) in
  let c_attrs = { S.code = None; 
    S.proto = Some (S.Id (p, "%parent"));
    S.klass = "Object";
    S.extensible = true; } in
  let ncontext = S.Object (p, c_attrs, prop_pairs) in
  let param_len = List.length args in
  let indices = Prelude.iota param_len in
  let combined = List.combine indices args in
  let seq_chain = get_chain p combined final in
  S.Lambda (p, ["%this"; "%args"],
    S.Label (p, "%ret",
      S.Let (p, "%context", ncontext, seq_chain)))

and prm_to_setfield p n prm =
  let argsobj = S.Object (p, S.d_attrs, []) in
  S.SetField (p, S.Id (p, "%context"), 
  S.GetField (p, S.Id (p, "%params"), S.String (p, string_of_int n), argsobj),
  S.GetField (p, S.Id (p, "%args"), S.String (p, string_of_int n), argsobj),
  S.Null (p))

and fv_to_setfield p v = 
  let arec = { S.value = S.Undefined (p); S.writable = true; } in
  let aprop = S.Data (arec, true, true) in
  let argsobj = S.Object (p, S.d_attrs, [(v, aprop)]) in
  S.SetField (p, S.Id (p, "%context"), S.String (p, v), S.Undefined (p),
  argsobj)

and get_chain p params final = match params with
  | [] -> final
  | (n, first) :: rest ->
    let a = prm_to_setfield p n (List.hd params) 
    and b = get_chain p (List.tl params) final in
    S.Seq (p, a, b)

and get_fv_chain p fvs final = match fvs with
  | [] -> final
  | first :: rest ->
    let a = fv_to_setfield p first
    and b = get_fv_chain p rest final in
    S.Seq (p, a, b)

and remove_dupes lst =
  let rec helper l seen result = match l with
    | [] -> result
    | first :: rest ->
      let next = if (List.mem first seen) then result else (first :: result) in
      helper rest (first :: seen) next in
  helper lst [] []

and normal_let exp = match exp with
  | E.LetExpr (p, nm, vl, body) -> 
    let sv = exprjs_to_ljs vl
    and sb = exprjs_to_ljs body in
    let result_obj = match nm with
      | "%context" -> let orig_props = match sv with
        | S.Object (_, _, pl) -> pl
        | _ -> failwith "let bound %context to a non-object" in
        let c_attrs = { S.code = None;
                        S.proto = Some (S.Id (p, "%context"));
                        S.klass = "Object";
                        S.extensible = true; } in
        S.Object (p, c_attrs, orig_props)
      | _ -> sv in
    S.Let (p, nm, result_obj, sb)
