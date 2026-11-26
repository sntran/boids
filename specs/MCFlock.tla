---- MODULE MCFlock ----
(***************************************************************************)
(* A small model of Flock. MCFlock.cfg checks the flock as the library    *)
(* makes it, with three processes for one id: a boid, the process that    *)
(* starts again with its id, and one more. MCFlockTwo.cfg has two ids and *)
(* two processes. The fault models must fail: MCFlockKeep.cfg (the flock  *)
(* keeps the row of a process that stopped, so it refuses the process     *)
(* that starts again with its id) and MCFlockLeave.cfg (a leave removes   *)
(* the row of each process, so a late leave takes the row of a new        *)
(* process with the same id).                                             *)
(***************************************************************************)
EXTENDS Flock, TLC
====
