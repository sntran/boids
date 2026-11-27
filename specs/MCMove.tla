---- MODULE MCMove ----
(***************************************************************************)
(* A small model of Move: two nodes, and one boid that crosses the border  *)
(* some times. MCMove.cfg checks the move with no lost answer, and with a  *)
(* node that can stop. MCMoveLost.cfg also loses calls and answers. The    *)
(* fault models must fail: MCMoveOlder.cfg (a node always keeps its        *)
(* process, so two processes can stop for each other) and                  *)
(* MCMoveStays.cfg (a process stays when the other node has the boid, so   *)
(* a move does not end). MCMoveTwo.cfg shows a limit: after a lost         *)
(* answer, the boid can have a process on each node.                       *)
(***************************************************************************)
EXTENDS Move, TLC
====
