---- MODULE MCFacts ----
(***************************************************************************)
(* Small models of Facts. MCFacts.cfg checks the facts as the library      *)
(* keeps them: two nodes, one key, three changes and two splits, with a    *)
(* counter that goes up by 1 or by 2 at a change. MCFactsThree.cfg has     *)
(* three nodes, and MCFactsKeys.cfg has two keys, which share the counter  *)
(* of a node. The fault models must fail: MCFactsCounter.cfg (a node       *)
(* compares only the counters, so two changes with the same counter stay   *)
(* different on two nodes), MCFactsClock.cfg (the counter of a change is   *)
(* only the time, with a clock that stands still, so two changes of one    *)
(* node have one version), MCFactsNoMark.cfg (a fact that is removed       *)
(* keeps no mark, so an older change brings it back) and                   *)
(* MCFactsEarly.cfg (a node drops a mark at each moment, so an older       *)
(* change of a node that had no connection brings the fact back: this is   *)
(* the limit of the time of a mark).                                       *)
(***************************************************************************)
EXTENDS Facts, TLC
====
