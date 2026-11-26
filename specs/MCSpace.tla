---- MODULE MCSpace ----
(***************************************************************************)
(* A small model of Space, with two cells and one read. MCSpace.cfg       *)
(* checks the space as the library makes it, with two boids that write    *)
(* one time each. MCSpaceLong.cfg has one boid that writes three times.   *)
(* The fault models must fail: MCSpaceGap.cfg (a write removes the old    *)
(* copy before it adds the new copy, so a reader does not find a boid     *)
(* that stays in its cell) and MCSpaceTwice.cfg (the reader keeps each    *)
(* copy, so a boid is in the result two times).                           *)
(***************************************************************************)
EXTENDS Space, TLC
====
