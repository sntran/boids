---- MODULE MCMembers ----
(***************************************************************************)
(* A small model of Members. MCMembers.cfg checks the world as the   *)
(* library makes it, with three processes for one id: a boid, the process  *)
(* that starts again with its id, and one more. MCMembersTwo.cfg has two   *)
(* ids and two processes. The fault models must fail: MCMembersKeep.cfg    *)
(* (the world keeps the row of a process that stopped, so it refuses *)
(* the process that starts again with its id) and MCMembersLeave.cfg (a    *)
(* leave removes the row of each process, so a late leave takes the row of *)
(* a new process with the same id).                                        *)
(***************************************************************************)
EXTENDS Members, TLC
====
