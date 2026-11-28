---- MODULE Facts ----
(***************************************************************************)
(* The facts of a world on several nodes (boids_world: set/3, learn,       *)
(* keep, the join of a node, drop_marks). A fact is what all the boids of  *)
(* a world perceive, and that is not a boid: an obstacle, the scale of     *)
(* the time, or a grid. Each node has a copy of each fact, and all the     *)
(* nodes must have the same facts.                                         *)
(*                                                                         *)
(* A user changes a fact on one node (Change). The change gets a version:  *)
(* a counter and the node. The counter is larger than the largest counter  *)
(* that the node knows. In the code it is the time of the system in        *)
(* microseconds, or the largest counter that the node knows plus 1 when    *)
(* that is more. The model has no time: the counter is larger by one of    *)
(* the steps of the constant Steps (1, or more for a clock that is         *)
(* ahead). The world of that node sends the change to the worlds that it   *)
(* knows (its peers), and it does not wait for them.                       *)
(*                                                                         *)
(* A node takes a fact that comes only when its version is larger than     *)
(* the version that the node has for the key: the counter first, then the  *)
(* node (Learn). Thus the nodes come to the same facts in each order of    *)
(* the messages, and for each clock of each computer. The time only tells  *)
(* which change wins: the last one in time, when the clocks agree.         *)
(*                                                                         *)
(* A fact that is removed stays as a mark, with its version: an older      *)
(* change that comes later does not bring the fact back.                   *)
(*                                                                         *)
(* The connection between two nodes can end (Split): the messages between  *)
(* them that are on their way are lost, and each side can change the       *)
(* facts. When a node sees another node (Join: a new node, or a node after *)
(* a split), it sends all its facts and its marks to that node, and that   *)
(* node is one of its peers from that moment.                              *)
(*                                                                         *)
(* A node drops a mark after some time (Drop). The time is longer than     *)
(* each split and than the time of a message: at that moment each node     *)
(* has the mark or a newer fact, and no older fact is on its way. The      *)
(* model has this as the condition of Drop. A fault model drops a mark at  *)
(* each moment: that is a node with no connection for a longer time than   *)
(* the time of a mark.                                                     *)
(***************************************************************************)
EXTENDS Naturals, FiniteSets

CONSTANTS
    Nodes,       \* the nodes: numbers, in the order of their names
    Keys,        \* the keys of the facts
    Changes,     \* the changes that the users make (a bound of the model)
    Splits,      \* the splits of the network (a bound of the model)
    Steps,       \* how much the counter of a change is larger than the largest counter that its node knows
                 \* ({0}: the fault model where the counter is only the time of a clock that stands still)
    ByNode,      \* FALSE: the fault model where a node compares only the counters of two versions
    Marks,       \* FALSE: the fault model where a fact that is removed keeps no mark
    Wait         \* FALSE: the fault model where a node drops a mark at each moment

VARIABLES
    fact,        \* the fact of each key on each node: its counter, its node, "set" or "none", and the number of its change
    clock,       \* the largest counter that each node knows
    linked,      \* the pairs of nodes that have a connection
    peers,       \* the nodes that each node sends its changes to
    msgs,        \* the facts on their way
    removed,     \* the newest removal of each key that each node took (to check the model)
    changes,     \* the changes that were made
    splits       \* the splits that were made

vars == <<fact, clock, linked, peers, msgs, removed, changes, splits>>

AllPairs == {p \in SUBSET Nodes : Cardinality(p) = 2}
Linked(n, m) == {n, m} \in linked

\* A key with no fact: its version is before each version.
Zero == [c |-> 0, n |-> 0, v |-> "none", i |-> 0]

\* The version of f is after the version of g.
After(f, g) == f.c > g.c \/ (f.c = g.c /\ f.n > g.n)

\* A node takes the fact f when it has the fact g.
Newer(f, g) == f.c > g.c \/ (ByNode /\ f.c = g.c /\ f.n > g.n)

\* What a node keeps for a fact: a fact that is removed stays as a mark.
Keep(f) == IF f.v = "none" /\ ~Marks THEN Zero ELSE f

\* What the boids of a node perceive for a fact: nothing, or the change
\* that made it.
Seen(f) == IF f.v = "none" THEN Zero ELSE f

Later(f, g) == IF After(f, g) THEN f ELSE g

Init ==
    /\ fact = [n \in Nodes |-> [k \in Keys |-> Zero]]
    /\ clock = [n \in Nodes |-> 0]
    /\ linked = AllPairs
    /\ peers = [n \in Nodes |-> Nodes \ {n}]
    /\ msgs = {}
    /\ removed = [n \in Nodes |-> [k \in Keys |-> Zero]]
    /\ changes = 0
    /\ splits = 0

\* The node n keeps the fact f of the key k.
Put(n, k, f) ==
    /\ fact' = [fact EXCEPT ![n] = [fact[n] EXCEPT ![k] = Keep(f)]]
    /\ removed' = IF f.v = "none"
                  THEN [removed EXCEPT ![n] = [removed[n] EXCEPT ![k] = Later(f, removed[n][k])]]
                  ELSE removed

\* A user changes the fact of the key k on the node n: a new value, or
\* its removal. The counter of the change is larger than the largest
\* counter that the node knows, by the step d. The world of the node
\* sends the change to its peers.
Change(n, k, v, d) ==
    LET f == [c |-> clock[n] + d, n |-> n, v |-> v, i |-> changes + 1] IN
    /\ changes < Changes
    /\ Put(n, k, f)
    /\ clock' = [clock EXCEPT ![n] = f.c]
    /\ msgs' = msgs \cup {[to |-> m, from |-> n, key |-> k, f |-> f] : m \in peers[n]}
    /\ changes' = changes + 1
    /\ UNCHANGED <<linked, peers, splits>>

\* A fact comes to its node. The node takes it only when its version is
\* larger than the version that the node has.
Learn(x) ==
    /\ x \in msgs
    /\ IF Newer(x.f, fact[x.to][x.key])
       THEN Put(x.to, x.key, x.f)
       ELSE UNCHANGED <<fact, removed>>
    /\ clock' = [clock EXCEPT ![x.to] = IF x.f.c > clock[x.to] THEN x.f.c ELSE clock[x.to]]
    /\ msgs' = msgs \ {x}
    /\ UNCHANGED <<linked, peers, changes, splits>>

\* The connection between two nodes ends. The messages between them that
\* are on their way are lost, and each of the two has one peer less.
Split(n, m) ==
    /\ Linked(n, m) /\ splits < Splits
    /\ linked' = linked \ {{n, m}}
    /\ peers' = [peers EXCEPT ![n] = peers[n] \ {m}, ![m] = peers[m] \ {n}]
    /\ msgs' = {x \in msgs : {x.to, x.from} /= {n, m}}
    /\ splits' = splits + 1
    /\ UNCHANGED <<fact, clock, removed, changes>>

\* Two nodes have a connection again.
Heal(n, m) ==
    /\ n /= m /\ ~Linked(n, m)
    /\ linked' = linked \cup {{n, m}}
    /\ UNCHANGED <<fact, clock, peers, msgs, removed, changes, splits>>

\* The node n sees the node m: it sends all its facts and its marks to m,
\* and m is one of its peers.
Join(n, m) ==
    /\ n /= m /\ Linked(n, m) /\ m \notin peers[n]
    /\ peers' = [peers EXCEPT ![n] = peers[n] \cup {m}]
    /\ msgs' = msgs \cup {[to |-> m, from |-> n, key |-> k, f |-> fact[n][k]] : k \in {j \in Keys : fact[n][j].c > 0}}
    /\ UNCHANGED <<fact, clock, linked, removed, changes, splits>>

\* Each node took the mark f of the key k or has a newer fact, and no
\* older fact of the key is on its way.
Everywhere(k, f) ==
    /\ \A m \in Nodes : ~After(f, Later(fact[m][k], removed[m][k]))
    /\ \A x \in msgs : x.key = k => ~After(f, x.f)

\* The node n drops the mark of the key k.
Drop(n, k) ==
    /\ fact[n][k].c > 0 /\ fact[n][k].v = "none"
    /\ Wait => Everywhere(k, fact[n][k])
    /\ fact' = [fact EXCEPT ![n] = [fact[n] EXCEPT ![k] = Zero]]
    /\ UNCHANGED <<clock, linked, peers, msgs, removed, changes, splits>>

\* All the nodes have a connection, each node knows each other node, and
\* no fact is on its way.
Quiet ==
    /\ linked = AllPairs
    /\ \A n \in Nodes : peers[n] = Nodes \ {n}
    /\ msgs = {}

\* The users made their changes, the network made its splits, and the
\* world is at rest.
Rest ==
    /\ Quiet /\ changes = Changes /\ splits = Splits
    /\ \A n \in Nodes, k \in Keys : fact[n][k].v = "set" \/ fact[n][k].c = 0
    /\ UNCHANGED vars

Next ==
    \/ \E n \in Nodes, k \in Keys, v \in {"set", "none"}, d \in Steps : Change(n, k, v, d)
    \/ \E x \in msgs : Learn(x)
    \/ \E n \in Nodes, m \in Nodes : Split(n, m) \/ Heal(n, m) \/ Join(n, m)
    \/ \E n \in Nodes, k \in Keys : Drop(n, k)
    \/ Rest

Spec == Init /\ [][Next]_vars /\ WF_vars(Next)

\* --- Invariants --------------------------------------------------------

\* When all the nodes have a connection and no fact is on its way, the
\* boids of all the nodes perceive the same facts.
Same == Quiet => \A n \in Nodes, m \in Nodes, k \in Keys : Seen(fact[n][k]) = Seen(fact[m][k])

\* An older change never brings back a fact that was removed: a fact of
\* a node is after each removal of its key that the node took.
NoReturn == \A n \in Nodes, k \in Keys : fact[n][k].v = "set" => After(fact[n][k], removed[n][k])

\* The next change of a node is after each fact that the node has.
Counts == \A n \in Nodes, k \in Keys : fact[n][k].c <= clock[n]

\* --- Liveness ----------------------------------------------------------

\* The world comes to rest: all the nodes have a connection, and no fact
\* is on its way.
Settles == <>[]Quiet
====
