open Core

(** Runtime values with source location information.
    Parameterized by underlying type. *)
type 'v t = { source_location : Section.t
            ; datum : 'v }