---- MODULE MCSpace ----
(***************************************************************************)
(* A small model of Space, with two cells and one read. MCSpace.cfg        *)
(* checks the space as the library makes it, with two boids that write     *)
(* one time each. MCSpaceLong.cfg has one boid that writes three times.    *)
(* The fault models must fail: MCSpaceGap.cfg (a write removes the old     *)
(* copy before it adds the new copy, so a reader does not find a boid      *)
(* that stays in its cell), MCSpaceTwice.cfg (the reader keeps each copy,  *)
(* so a boid is in the result two times) and MCSpaceLeak.cfg (the space    *)
(* removes only the copy of the row, so the old copy of a boid that        *)
(* stopped in the middle of a write stays).                                *)
(***************************************************************************)
EXTENDS Space, TLC
====
