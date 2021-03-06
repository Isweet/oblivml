open Core
open Stdio

exception TypeError of Section.t * String.t

type env_t = (Var.t, Type.t Option.t, Var.comparator_witness) Map.t

let maybe_t_to_string m_t =
  match m_t with
  | None -> "*"
  | Some t -> Type.to_string t

let env_to_string tenv =
  Printf.sprintf "{ %s }"
    (String.concat
       (List.map
          (Map.to_alist tenv)
          ~f:(fun (k, v) ->
            Printf.sprintf "%s -> %s" (Var.to_string k) (maybe_t_to_string v)))
       ~sep:"; ")

let env_join tenv1 tenv2 =
  let type_meet t1 t2 =
    match t1, t2 with
    | (None    , _)       -> None
    | (_       , None)    -> None
    (* TODO(ins): FIXME -- assert should be TypeError or something *)
    | (Some t1 , Some t2) -> assert (Type.equal t1 t2); Some t1
  in

  Map.merge
    tenv1
    tenv2
    ~f:(fun ~key:_ v ->
        match v with
        | `Left v1       -> Some v1
        | `Right v2      -> Some v2
        | `Both (v1, v2) -> Some (type_meet v1 v2))

let env_update tenv1 tenv2 =
  Map.merge
    tenv1
    tenv2
    ~f:(fun ~key:_ v ->
        match v with
        | `Left v1       -> Some v1
        | `Right v2      -> Some v2
        | `Both (v1, v2) -> Some v2)

let env_clear tenv vars =
  List.fold
    vars
    ~init:tenv
    ~f:(fun m x ->
        Map.remove m x)

let rec env_consume path tenv =
  (* Printf.printf "%s\n" (env_to_string tenv); *)
  match path with
  | [ ] -> failwith "Impossible: forbidden by lexer / parser."
  | [ x ] ->
    (* Printf.printf "%s\n" (Var.to_string x); *)
    (try
       let x_t = Map.find_exn tenv x in
       (match x_t with
        | None ->
          let msg =
            Printf.sprintf
              "The variable %s on the path has already been consumed."
              (Var.to_string x)
          in
          Or_error.error_string msg
        | Some t ->
          (match Type.accessible t with
           | Kind.Universal -> Or_error.return (t, tenv)
           | Kind.Affine    -> Or_error.return (t, Map.set tenv x None)))
     with
     | Not_found ->
       let msg =
         Printf.sprintf
           "The variable %s on the path does not exist."
           (Var.to_string x)
       in
       Or_error.error_string msg)
  | x :: xs ->
    (* Printf.printf "%s\n" (Var.to_string x); *)
    (try
       let x_t = Map.find_exn tenv x in
       (match x_t with
        | None ->
          let msg =
            Printf.sprintf
              "The variable %s on the path has already been consumed."
              (Var.to_string x)
          in
          Or_error.error_string msg
        | Some t ->
          (match t with
           | TRecord next ->
             let open Or_error.Monad_infix in
             env_consume xs next >>= fun (t_ret, next_env) ->
             Or_error.return (t_ret, Map.set tenv ~key:x ~data:(Some (TRecord next_env)))
           | _ ->
             let msg =
               Printf.sprintf
                 "The variable %s on the path is not a record type, it has type %s."
                 (Var.to_string x)
                 (Type.to_string t)
             in
             Or_error.error_string msg))
     with
     | Not_found ->
       let msg = Printf.sprintf
           "The variable %s on the path does not exist."
           (Var.to_string x)
       in
       Or_error.error_string msg)

let option_to_string m f =
  match m with
  | None -> "*"
  | Some v -> f v

let rec mux_merge loc l_guard r_guard t1 t2 =

  match t1, t2 with
  | Type.TBase (tb1, l1, r1), Type.TBase (tb2, l2, r2) when Type.Base.equal tb1 tb2 ->
    let kind = Type.Base.accessible tb1 in
    if Kind.equal kind Kind.Affine && Type.Base.safe tb1 then
      if Region.lt r_guard r1 && Region.lt r_guard r2 then
        let l' = Label.secret in
        let r' = Region.join r1 r2 in
        (* Printf.printf "%s @ %s\n" (Region.to_string r') (option_to_string loc Section.to_string); *)
        Type.TBase (tb1, l', r')
      else
        let msg =
              Printf.sprintf
                "Arguments of mux are not lt the guard: ~(%s < %s and %s)."
                (Region.to_string r_guard)
                (Region.to_string r1)
                (Region.to_string r2)
        in
        raise (TypeError (loc, msg))
    else
      let l' = Label.join l_guard (Label.join l1 l2) in
      let r' = Region.join r_guard (Region.join r1 r2) in
      (* Printf.printf "%s @ %s\n" (Region.to_string r') (option_to_string loc Section.to_string); *)
      Type.TBase (tb1, l', r')
  | Type.TTuple (t11, t12), Type.TTuple (t21, t22) ->
    let t1_ret = mux_merge loc l_guard r_guard t11 t21 in
    let t2_ret = mux_merge loc l_guard r_guard t12 t22 in
    Type.TTuple (t1_ret, t2_ret)
  | Type.TRecord bs1, Type.TRecord bs2 ->
    Type.TRecord (List.fold
                    (Map.keys bs1)
                    ~init:(Map.empty (module Var))
                    ~f:(fun acc key ->
                        let m_t1' = Map.find_exn bs1 key in
                        let m_t2' = Map.find_exn bs2 key in
                        let d =
                          match m_t1', m_t2' with
                          | None, None -> None
                          | Some t1', Some t2' -> Some (mux_merge loc l_guard r_guard t1' t2')
                          | _ ->
                            let msg =
                              Printf.sprintf
                                "Fields of records being muxed mismatch on consumption."
                            in
                            raise (TypeError (loc, msg))
                        in
                        Map.set acc ~key:key ~data:d))
  | _ -> raise (TypeError (loc, "Unimplemented"))

type alias_t = (Var.t, Type.t, Var.comparator_witness) Map.t

let rec static (tenv : env_t) (talias : alias_t) (e : Source.t) : Type.t * env_t =
  match e.datum with
  | Source.ELit l ->
    let t_lit = Type.TBase (Literal.to_type l.datum, l.label, Region.bottom) in
    (t_lit, tenv)

  | Source.EFlip r ->
    if Region.equiv r Region.bottom then
      let msg = "Region annotation cannot be bottom." in
      raise (TypeError (e.source_location, msg))
    else
      let t_flip = Type.TBase (Type.Base.TBRBool, Label.secret, r) in
      (t_flip, tenv)

  | Source.ERnd r ->
    if Region.equiv r Region.bottom then
      let msg = "Region annotation cannot be bottom." in
      raise (TypeError (e.source_location, msg))
    else
      let t_rnd = Type.TBase (Type.Base.TBRInt, Label.secret, r) in
      (t_rnd, tenv)

  | Source.EVar path ->
    (match env_consume path tenv with
     | Result.Ok r      -> r
     | Result.Error err -> raise (TypeError (e.source_location, Error.to_string_hum err)))

  | Source.EBOp bo ->
    let ((l', r'), tenv') =
      List.fold
        ~init:((Label.public, Region.bottom), tenv)
        ~f:(fun ((l_acc, r_acc), env_acc) arg ->
            let (t', tenv') = static env_acc talias arg in
            match t' with
            | Type.TBase (Type.Base.TBBool, l, r) -> ((Label.join l_acc l, Region.join r_acc r), tenv')
            | _ ->
              let msg =
                Printf.sprintf
                  "Expected type `bool`, but got %s."
                  (Type.to_string t')
              in
              raise (TypeError (e.source_location, msg)))
        bo.args
    in
    (Type.TBase (Type.Base.TBBool, l', r'), tenv')

  | Source.EAOp ao ->
    let ((l', r'), tenv') =
      List.fold
        ~init:((Label.public, Region.bottom), tenv)
        ~f:(fun ((l_acc, r_acc), env_acc) arg ->
            let (t', tenv') = static env_acc talias arg in
            match t' with
            | Type.TBase (Type.Base.TBInt, l, r) -> ((Label.join l_acc l, Region.join r_acc r), tenv')
            | _ ->
              let msg =
                Printf.sprintf
                  "Expected type `bool`, but got %s."
                  (Type.to_string t')
              in
              raise (TypeError (e.source_location, msg)))
        ao.args
    in
    (Type.TBase (Type.Base.TBInt, l', r'), tenv')

  | Source.EARel ar ->
    let ((l', r'), tenv') =
      List.fold
        ~init:((Label.public, Region.bottom), tenv)
        ~f:(fun ((l_acc, r_acc), env_acc) arg ->
            let (t', tenv') = static env_acc talias arg in
            match t' with
            | Type.TBase (Type.Base.TBInt, l, r) -> ((Label.join l_acc l, Region.join r_acc r), tenv')
            | _ ->
              let msg =
                Printf.sprintf
                  "Expected type `bool`, but got %s."
                  (Type.to_string t')
              in
              raise (TypeError (e.source_location, msg)))
        ar.args
    in
    (Type.TBase (Type.Base.TBBool, l', r'), tenv')

  | Source.ETuple (left, right) ->
    let (t_left, tenv')   = static tenv talias left in
    let (t_right, tenv'') = static tenv' talias right in
    let t_tuple           = Type.TTuple (t_left, t_right) in
    (t_tuple, tenv'')

  | Source.ERecord bindings ->
    let (t_bindings, tenv') =
      List.fold_left
        bindings
        ~init:(Map.empty (module Var), tenv)
        ~f:(fun (t_bindings_acc, env_acc) (field, binding) ->
            let (t, tenv_curr) = static env_acc talias binding in
            (Map.set t_bindings_acc field (Some t), tenv_curr))
    in
    (Type.TRecord t_bindings, tenv')

  | Source.EArrInit arr ->
    let (t_size, tenv') = static tenv talias arr.size in
    (match t_size with
     | Type.TBase (Type.Base.TBInt, l_size, r_size) ->
       if Label.equiv l_size Label.public then
         if Region.equiv r_size Region.bottom then
           let (t_body, tenv'') = static tenv' talias arr.init in
           (match t_body with
            | Type.TFun (Type.TBase (Type.Base.TBInt, l_body, r_body), t_arr) ->
              if Label.equiv l_body Label.public then
                if Region.equiv r_body Region.bottom then
                  (TArray t_arr, tenv'')
                else
                  let msg =
                    Printf.sprintf
                      "The parameter of the initializer must have bottom region. It's region is %s."
                      (Region.to_string r_body)
                  in
                  raise (TypeError (arr.init.source_location, msg))
              else
                let msg =
                  Printf.sprintf
                    "The parameter of the initializer must have public label. It's label is %s."
                    (Label.to_string l_body)
                in
                raise (TypeError (arr.init.source_location, msg))
            | _ ->
              let msg =
                Printf.sprintf
                  "The parameter of the initializer must be an int. It's type is %s."
                  (Type.to_string t_body)
              in
              raise (TypeError (arr.init.source_location, msg)))
         else
           let msg =
             Printf.sprintf
               "The size argument to this array initialization must have bottom region. It's region is %s."
               (Region.to_string r_size)
           in
           raise (TypeError (arr.size.source_location, msg))
       else
         let msg =
           Printf.sprintf
             "The size argument to this array initialization must have public label. It's label is %s."
             (Label.to_string l_size)
         in
         raise (TypeError (arr.size.source_location, msg))
     | _ ->
       let msg =
         Printf.sprintf
           "The size argument to this array initialization must be an int. It's type is %s."
           (Type.to_string t_size)
       in
       raise (TypeError (arr.size.source_location, msg)))

  | Source.EArrRead read ->
    let (t_addr, tenv') = static tenv talias read.loc in
    (match t_addr with
     | Type.TArray t_ele ->
       let (t_idx, tenv'') = static tenv' talias read.idx in
       (match t_idx with
        | Type.TBase (Type.Base.TBInt, l_idx, r_idx) ->
          if Label.equiv l_idx Label.public then
            if Region.equiv r_idx Region.bottom then
              (match Type.accessible t_ele with
               | Kind.Universal ->
                 (t_ele, tenv'')
               | Kind.Affine ->
                 let msg =
                   Printf.sprintf
                     "Attempting to read from %s (affine) array without a write."
                     (Type.to_string t_ele)
                 in
                 raise (TypeError (e.source_location, msg)))
            else
              let msg =
                Printf.sprintf
                  "The index to this array read must have bottom region. It's region is %s."
                  (Region.to_string r_idx)
              in
              raise (TypeError (read.idx.source_location, msg))
          else
            let msg =
              Printf.sprintf
                "The index to this array read must have public label. It's label is %s."
                (Label.to_string l_idx)
            in
            raise (TypeError (read.idx.source_location, msg))
        | _ ->
          let msg =
            Printf.sprintf
              "The index to this array read must be an int. It's type is %s."
              (Type.to_string t_idx)
          in
          raise (TypeError (read.idx.source_location, msg)))
     | _ ->
       let msg =
         Printf.sprintf
           "This isn't an array. It's type is %s."
           (Type.to_string t_addr)
       in
       raise (TypeError (read.loc.source_location, msg)))

  | Source.EArrWrite write ->
    let (t_addr, tenv') = static tenv talias write.loc in
    (match t_addr with
     | Type.TArray t_ele ->
       let (t_idx, tenv'') = static tenv' talias write.idx in
       (match t_idx with
        | Type.TBase (Type.Base.TBInt, l_idx, r_idx) ->
          if Label.equiv l_idx Label.public then
            if Region.equiv r_idx Region.bottom then
              let (t_value, tenv''') = static tenv'' talias write.value in
              if Type.equal t_value t_ele then
                (t_ele, tenv''')
              else
                let msg =
                  Printf.sprintf
                    "Attempting to write a value of type %s to an array of type %s."
                    (Type.to_string t_value)
                    (Type.to_string t_ele)
                in
                raise (TypeError (write.value.source_location, msg))
            else
              let msg =
                Printf.sprintf
                  "The index to this array write must have bottom region. It's region is %s."
                  (Region.to_string r_idx)
              in
              raise (TypeError (write.idx.source_location, msg))
          else
            let msg =
              Printf.sprintf
                "The index to this array write must have public label. It's label is %s."
                (Label.to_string l_idx)
            in
            raise (TypeError (write.idx.source_location, msg))
        | _ ->
          let msg =
            Printf.sprintf
              "The index to this array write must be an int. It's type is %s."
              (Type.to_string t_idx)
          in
          raise (TypeError (write.idx.source_location, msg)))
     | _ ->
       let msg =
         Printf.sprintf
           "This isn't an array. It's type is %s."
           (Type.to_string t_addr)
       in
       raise (TypeError (write.loc.source_location, msg)))

  | Source.EArrLen len ->
    let (t_addr, tenv') = static tenv talias len in
    (match t_addr with
     | Type.TArray _ ->
       let l'       = Label.bottom in
       let r'       = Region.bottom in
       let t_arrlen = Type.TBase (Type.Base.TBInt, l', r') in
       (t_arrlen, tenv')
     | _ ->
       let msg =
         Printf.sprintf
           "This isn't an array. It's type is %s."
           (Type.to_string t_addr)
       in
       raise (TypeError (len.source_location, msg)))

  | Source.ECast use when Label.equiv use.label Label.secret ->
    (try
       let x_t = Map.find_exn tenv use.var in
       match x_t with
       | None ->
         let msg =
           Printf.sprintf
             "Attempted to reference the variable %s, which has been consumed."
             (Var.to_string use.var)
         in
         raise (TypeError (e.source_location, msg))
       | Some t ->
         (match t with
          | Type.TBase (t_base, l, r) ->
            let t_base' =
              (match t_base with
               | Type.Base.TBRBool -> Type.Base.TBBool
               | Type.Base.TBRInt  -> Type.Base.TBInt
               | _ ->
                 let msg =
                   Printf.sprintf
                     "Attempted to secret-coerce (use) variable with non-random type. It's type is %s."
                     (Type.to_string t)
                 in
                 raise (TypeError (e.source_location, msg)))
            in
            let t_use = Type.TBase (t_base', Label.top, r) in
            (t_use, tenv)
          | _ ->
            let msg =
              Printf.sprintf
                "The variable %s must be type rbool or rint, but is %s."
                (Var.to_string use.var)
                (Type.to_string t)
            in
            raise (TypeError (e.source_location, msg)))
     with
     | Not_found ->
       let msg =
         Printf.sprintf
           "The variable %s is undefined."
           (Var.to_string use.var)
       in
       raise (TypeError (e.source_location, msg)))

  | Source.ECast rev when Label.equiv rev.label Label.public ->
    (try
       let x_t = Map.find_exn tenv rev.var in
       match x_t with
       | None ->
         let msg =
           Printf.sprintf
             "Attempted to reference the variable %s, which has been consumed."
             (Var.to_string rev.var)
         in
         raise (TypeError (e.source_location, msg))
       | Some t ->
         (match t with
          | Type.TBase (t_base, l, r) ->
            let t_base' =
              (match t_base with
               | Type.Base.TBRBool -> Type.Base.TBBool
               | Type.Base.TBRInt  -> Type.Base.TBInt
               | _ ->
                 let msg =
                   Printf.sprintf
                     "Attempted to public-coerce (reveal) variable with non-random type. It's type is %s."
                     (Type.to_string t)
                 in
                 raise (TypeError (e.source_location, msg)))
            in
            let t_reveal = Type.TBase (t_base', Label.bottom, Region.bottom) in
            (t_reveal, tenv)
          | _ ->
            let msg =
              Printf.sprintf
                "The variable %s must be type rbool or rint, but is %s."
                (Var.to_string rev.var)
                (Type.to_string t)
            in
            raise (TypeError (e.source_location, msg)))
     with
     | Not_found ->
       let msg =
         Printf.sprintf
           "The variable %s is undefined."
           (Var.to_string rev.var)
       in
       raise (TypeError (e.source_location, msg)))

  | Source.EMux mux ->
    let (t_guard, tenv') = static tenv talias mux.guard in
    (match t_guard with
     | Type.TBase (Type.Base.TBBool, l_guard, r_guard) ->
       let (t_lhs, tenv'') = static tenv' talias mux.lhs in
       let (t_rhs, tenv''') = static tenv'' talias mux.rhs in
       let t_ret = mux_merge e.source_location l_guard r_guard t_lhs t_rhs in
       (Type.TTuple (t_ret, t_ret), tenv''')
     | _ ->
       let msg =
         Printf.sprintf
           "The guard of this mux isn't a `bool` type, it has type %s."
           (Type.to_string t_guard)
       in
       raise (TypeError (mux.guard.source_location, msg)))

  | Source.EAbs abs ->
    let param' = Pattern.resolve_alias abs.pat talias in
    (match param' with
     | Pattern.XAscr (p, t_param) ->
       let plus =
         try
           Pattern.get_binders p t_param
         with
         | Pattern.PatternError ->
           let msg =
             Printf.sprintf
               "The pattern of the parameter does not match the ascribed type. The type is %s."
               (Type.to_string t_param)
           in
           raise (TypeError (e.source_location, msg))
         | Pattern.BindingError (x, err_msg) ->
           let msg =
             Printf.sprintf
               "There was an error during binding (%s): %s."
               (Var.to_string x)
               err_msg
           in
           raise (TypeError (e.source_location, msg))
         | Pattern.AscriptionError (t_claim, t_actual) ->
           let msg =
             Printf.sprintf
               "The type of an ascription in this parameter does not match the type of the toplevel ascription: %s <> %s."
               (Type.to_string t_claim)
               (Type.to_string t_actual)
           in
           raise (TypeError (e.source_location, msg))
       in
       let tenv_plus            = env_update tenv plus in
       let (t_body, tenv'_plus) = static tenv_plus talias abs.body in
       let tenv'                = env_clear tenv'_plus (Map.keys plus) in
       (Type.TFun (t_param, t_body), tenv')
     | _ ->
       let msg =
         Printf.sprintf
           "Function parameters must be annotated with their type."
       in
       raise (TypeError (e.source_location, msg)))

  | Source.ERec recabs ->
    let param' = Pattern.resolve_alias recabs.pat talias in
    let t_ret' = Type.resolve_alias recabs.t_ret talias in
    (match param' with
     | Pattern.XAscr (p, t_param) ->
       let plus =
         try
           Map.set (Pattern.get_binders p t_param) recabs.name (Some (Type.TFun (t_param, t_ret')))
         with
         | Pattern.PatternError ->
           let msg =
             Printf.sprintf
               "The pattern of the parameter does not match the ascribed type. The type is %s."
               (Type.to_string t_param)
           in
           raise (TypeError (e.source_location, msg))
         | Pattern.BindingError (x, err_msg) ->
           let msg =
             Printf.sprintf
               "There was an error during binding (%s): %s."
               (Var.to_string x)
               err_msg
           in
           raise (TypeError (e.source_location, msg))
         | Pattern.AscriptionError (t_claim, t_actual) ->
           let msg =
             Printf.sprintf
               "The type of an ascription in this parameter does not match the type of the toplevel ascription: %s <> %s."
               (Type.to_string t_claim)
               (Type.to_string t_actual)
           in
           raise (TypeError (e.source_location, msg))
       in
       let tenv_plus            = env_update tenv plus in
       let (t_body, tenv'_plus) = static tenv_plus talias recabs.body in
       let tenv'                = env_clear tenv'_plus (Map.keys plus) in
       (Type.TFun (t_param, t_body), tenv')
     | _ ->
       let msg =
         Printf.sprintf
           "Function parameters must be annotated with their type."
       in
       raise (TypeError (e.source_location, msg)))

  | Source.EApp app ->
    let (t_lam, tenv') = static tenv talias app.lam in
    (match t_lam with
     | Type.TFun (t_param, t_body) ->
       let (t_arg, tenv'') = static tenv' talias app.arg in
       if Type.equal t_param t_arg then
         (t_body, tenv'')
       else
         let msg =
           Printf.sprintf
             "The function parameter has type %s but is being applied to a value of type %s."
             (Type.to_string t_param)
             (Type.to_string t_arg)
         in
         raise (TypeError (e.source_location, msg))
     | _ ->
       let msg =
         Printf.sprintf
           "The value in function position does not have function type, it's type is %s."
           (Type.to_string t_lam)
       in
       raise (TypeError (app.lam.source_location, msg)))

  | Source.ELet binding ->
    let pat' = Pattern.resolve_alias binding.pat talias in
    let (t_value, tenv') = static tenv talias binding.value in
    let plus             =
      try
        Pattern.get_binders pat' t_value
      with
      | Pattern.PatternError ->
        let msg =
          Printf.sprintf
            "The pattern of this let-binding does not match the type of the bound expression. The type is %s."
            (Type.to_string t_value)
        in
        raise (TypeError (e.source_location, msg))
      | Pattern.BindingError (x, err_msg) ->
        let msg =
          Printf.sprintf
            "There was an error during binding (%s): %s"
            (Var.to_string x)
            err_msg
        in
        raise (TypeError (e.source_location, msg))
      | Pattern.AscriptionError (t_claim, t_actual) ->
        let msg =
          Printf.sprintf
            "The type of an ascription in this let-binding does not match the type of the bound expression: %s <> %s."
            (Type.to_string t_claim)
            (Type.to_string t_actual)
        in
        raise (TypeError (e.source_location, msg))
    in
    let tenv'_plus            = env_update tenv' plus in
    let (t_body, tenv''_plus) = static tenv'_plus talias binding.body in
    let tenv''                = env_clear tenv''_plus (Map.keys plus) in
    (t_body, tenv'')

  | Source.EType alias ->
    static tenv (Map.set talias ~key:alias.name ~data:alias.typ) alias.body

  | Source.EIf ite ->
    let (t_guard, tenv') = static tenv talias ite.guard in
    (match t_guard with
     | Type.TBase (Type.Base.TBBool, l_guard, _) when Label.equiv l_guard Label.public ->
       let (t_thenb, tenv'') = static tenv' talias ite.thenb in
       let (t_elseb, tenv''') = static tenv'' talias ite.elseb in
       if Type.equal t_thenb t_elseb then
         (t_thenb, env_join tenv'' tenv''')
       else
         let msg = Printf.sprintf "The branches of an if-statement must be the same type. The types are %s and %s." (Type.to_string t_thenb) (Type.to_string t_elseb) in
         raise (TypeError (e.source_location, msg))
     | _ ->
       let msg = Printf.sprintf "The guard of an if-statement must be a public boolean. Got: %s." (Type.to_string t_guard) in
       raise (TypeError (ite.guard.source_location, msg)))

  | Source.EPrint e -> static tenv talias e

  | Source.ECast _ -> failwith "Impossible"

let rec typecheck (e : Source.t) : Type.t =
  let emp = Map.empty (module Var) in
  let (r, _) = static emp emp e in
  r
