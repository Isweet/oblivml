open Core
open Stdio

type t =
  { loc  : Section.t Option.t
  ; node : t'
  }

and t' =
  (** Literal *)
  | ELit      of { value  : Literal.t
                 ; label  : Label.t
                 ; region : Region.t
                 }

  (** Values *)
  | EVal      of { value : value
                 ; label : Label.t
                 }

  (** Random Boolean *)
  | EFlip     of { label  : Label.t
                 ; region : Region.t
                 }

  (** Random Integer *)
  | ERnd      of { label  : Label.t
                 ; region : Region.t
                 }

  (** Variable *)
  | EVar      of { path : Var.t list
                 }

  (** Unary Boolean Operation *)
  | EBUnOp    of { op  : Boolean.Un.Op.t
                 ; arg : t
                 }

  (** Binary Boolean Operation *)
  | EBBinOp   of { op  : Boolean.Bin.Op.t
                 ; lhs : t
                 ; rhs : t
                 }

  (** Unary Arithmetic Operation *)
  | EAUnOp    of { op  : Arith.Un.Op.t
                 ; arg : t
                 }

  (** Binary Arithmetic Operation *)
  | EABinOp   of { op  : Arith.Bin.Op.t
                 ; lhs : t
                 ; rhs : t
                 }

  (** Unary Arithmetic Relation *)
  | EAUnRel   of { rel : Arith.Un.Rel.t
                 ; arg : t
                 }

  (** Binary Arithmetic Relation *)
  | EABinRel  of { rel : Arith.Bin.Rel.t
                 ; lhs : t
                 ; rhs : t
                 }

  (** Tuple *)
  | ETuple    of { contents : (t, t) Tuple.T2.t
                 }

  (** Record *)
  | ERecord   of { contents : (Var.t * t) list
                 }

  (** Array Initialization *)
  | EArrInit  of { size : t
                 ; init : t
                 }

  (** Array Read *)
  | EArrRead  of { addr : t
                 ; idx  : t
                 }

  (** Array Write *)
  | EArrWrite of { addr  : t
                 ; idx   : t
                 ; value : t
                 }

  (** Array Length *)
  | EArrLen   of { addr : t
                 }

  (** Random -> Secret *)
  | EUse      of { arg : Var.t
                 }

  (** Random -> Public *)
  | EReveal   of { arg : Var.t
                 }

  (** Random -> Non-Uniform *)
  | ETrust    of { arg : Var.t
                 }

  (** Non-Uniform -> Random *)
  | EProve    of { arg : Var.t
                 }

  (** Mux *)
  | EMux      of { guard : t
                 ; lhs   : t
                 ; rhs   : t
                 }

  (** Abstraction *)
  | EAbs      of { param : Pattern.t
                 ; body  : t
                 }

  (** Recursive Abstraction *)
  | ERec      of { name  : Var.t
                 ; param : Pattern.t
                 ; body  : t
                 ; t_ret : Type.t
                 }

  (** Application *)
  | EApp      of { lam : t
                 ; arg : t
                 }

  (** Let-Binding *)
  | ELet      of { pat   : Pattern.t
                 ; value : t
                 ; body  : t
                 }

  (** Type Alias *)
  | EType     of { name : Var.t
                 ; typ  : Type.t
                 ; body : t
                 }

  (** Conditional *)
  | EIf       of { guard : t
                 ; thenb : t
                 ; elseb : t
                 }

and value =
  | VUnit   of Unit.t IDist.t
  | VBool   of Bool.t IDist.t
  | VInt    of Int.t IDist.t
  | VFlip   of Bool.t IDist.t
  | VRnd    of (Bool.t IDist.t) List.t
  | VLoc    of Loc.t
  | VAbs    of { param : Pattern.t
               ; body : t}
  | VRec    of { name : Var.t
               ; param : Pattern.t
               ; body : t }
  | VTuple  of (value, value) Tuple.T2.t
  | VRecord of (Var.t * value) list
