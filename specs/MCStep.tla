---- MODULE MCStep ----
(***************************************************************************)
(* A small model of Step: three boids and two steps. MCStep.cfg checks     *)
(* the step as the library makes it, with boids that have a manual tick.   *)
(* The fault models must fail: MCStepOnePart.cfg (a boid moves when it     *)
(* calculates, so the next boid reads a space that changed) and            *)
(* MCStepClock.cfg (a boid also moves on its own clock, during the step).  *)
(***************************************************************************)
EXTENDS Step, TLC
====
