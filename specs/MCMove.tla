---- MODULE MCMove ----
(***************************************************************************)
(* A small model of Move: two nodes, and one boid that crosses the border  *)
(* some times. MCMove.cfg checks the move with a connection that does not  *)
(* end, and with a node that can stop. MCMoveSplit.cfg also ends the       *)
(* connection two times: the boid keeps a process, and it has one process  *)
(* after the last heal. The fault models must fail: MCMoveOlder.cfg (a     *)
(* node always keeps its process, so two processes can stop for each       *)
(* other), MCMoveStays.cfg (a process stays when the other node has the    *)
(* boid, so a move does not end) and MCMoveAny.cfg (a node stops its       *)
(* process of each age when it is told, so a decision can stop the only    *)
(* process). MCMoveTwo.cfg shows a limit: during a split, the boid can     *)
(* have a process on each node.                                            *)
(***************************************************************************)
EXTENDS Move, TLC
====
