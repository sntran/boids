---- MODULE MCMoveThree ----
(***************************************************************************)
(* A small model of MoveMany: three nodes, and one boid. MCMoveThree.cfg   *)
(* checks the move as the library makes it, with three crossings and one   *)
(* split that cuts one node from the two others. MCMoveThreeSplits.cfg has *)
(* two crossings and two splits, which can also cut all the nodes, and it  *)
(* checks that the boid has one process in the end. The fault models must  *)
(* fail:                                                                   *)
(* MCMoveThreeTiles.cfg (a decision also uses the tile of each process, so *)
(* two decisions for the same two processes can stop the two),             *)
(* MCMoveThreeAlone.cfg (a node that starts a process tells no other node, *)
(* so two processes can stay on two nodes that always had a connection)    *)
(* and MCMoveThreeAny.cfg (a node stops its process of each age when it    *)
(* is told).                                                               *)
(***************************************************************************)
EXTENDS MoveMany, TLC
====
