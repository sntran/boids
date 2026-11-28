---- MODULE MCKept ----
(***************************************************************************)
(* Small models of Kept. MCKept.cfg checks a fact that the boids keep as   *)
(* the library writes and reads it: three boids, and three writes. The     *)
(* fault models must fail: MCKeptEarly.cfg (a write changes the number of  *)
(* the changes before the row) and MCKeptLate.cfg (a read gets the number  *)
(* after the row). In each of them, a boid keeps an old row with the new   *)
(* number, and it does not read the row again.                             *)
(***************************************************************************)
EXTENDS Kept, TLC
====
