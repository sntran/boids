---- MODULE MoveMany ----
(***************************************************************************)
(* The move of a boid in a world on three nodes or more (gen_boid, settle  *)
(* and adopt; boids_world, join, census, claim and yield). Move.tla has    *)
(* the move between two nodes with all its steps. This module has less     *)
(* detail of one move, and it has what two nodes cannot show: the boid can *)
(* have a process on three nodes, and a world decides for two processes    *)
(* at a time.                                                              *)
(*                                                                         *)
(* A node is a number, as the order of the names of the nodes. Each        *)
(* message is on its way in a set, so the messages come in each order.     *)
(*                                                                         *)
(* A process in a tile of another node calls that node (Call). That node   *)
(* keeps a process of its own that is not older. If not, it starts a       *)
(* process for the boid (Adopt), and it tells the other nodes that it has  *)
(* the boid (a claim, with the call). The node of the call does nothing    *)
(* with that claim while its process waits for the answer of that call:    *)
(* with the answer, the first process stops. A split loses the calls and   *)
(* the answers between the nodes that it cuts: then the first process      *)
(* stays, and the boid has two processes.                                  *)
(*                                                                         *)
(* A claim tells a node that another node has a process of the boid with   *)
(* an age. When the two nodes have a connection again (Heal), each sends   *)
(* a claim for its process to the other. For two processes, the world of   *)
(* the node with the smaller number decides (Claim): the process with the  *)
(* larger age stays, then the process of the larger node. It stops its     *)
(* own process, or it tells the other node to stop the process of that     *)
(* age (Yield).                                                            *)
(*                                                                         *)
(* The age and the node of a process do not change. Thus two decisions     *)
(* for the same two processes are the same decision, and a world that      *)
(* told the other process to stop does not stop its own process later.     *)
(***************************************************************************)
EXTENDS Naturals, FiniteSets

CONSTANTS
    Nodes,       \* the nodes: numbers
    Crossings,   \* the times that a process goes into a tile of another node (a bound of the model)
    Splits,      \* the splits of the network (a bound of the model)
    Apart,       \* TRUE: a split can also cut all the nodes from each other (a bound of the model)
    Tiles,       \* TRUE: the fault model where a decision also uses the tile of each process
    Announce,    \* FALSE: the fault model where a node that starts a process tells no other node
    Exact        \* FALSE: the fault model where a node stops its process of each age when it is told

VARIABLES
    proc,        \* the process of the boid on each node: "none", "runs" or "calls"
    age,         \* the age of the process of each node: the moves before it
    at,          \* the node of the tile where the process of each node is
    wait,        \* the call that the process of each node waits for, or 0
    linked,      \* the pairs of nodes that have a connection
    calls,       \* the calls on their way
    answers,     \* the answers on their way
    claims,      \* the claims on their way
    yields,      \* the decisions on their way
    sent,        \* the calls that were made
    crossed,     \* the times that a process went into a tile of another node
    splits       \* the splits that were made

vars == <<proc, age, at, wait, linked, calls, answers, claims, yields, sent, crossed, splits>>

AllPairs == {p \in SUBSET Nodes : Cardinality(p) = 2}
Linked(n, m) == {n, m} \in linked
Alive(n) == proc[n] /= "none"
First == CHOOSE n \in Nodes : \A m \in Nodes : n <= m

Init ==
    /\ proc = [n \in Nodes |-> IF n = First THEN "runs" ELSE "none"]
    /\ age = [n \in Nodes |-> 0]
    /\ at = [n \in Nodes |-> n]
    /\ wait = [n \in Nodes |-> 0]
    /\ linked = AllPairs
    /\ calls = {}
    /\ answers = {}
    /\ claims = {}
    /\ yields = {}
    /\ sent = 0
    /\ crossed = 0
    /\ splits = 0

\* The boid of a process goes into a tile of another node.
Cross(n, m) ==
    /\ proc[n] = "runs" /\ at[n] = n /\ m /= n /\ Linked(n, m) /\ crossed < Crossings
    /\ at' = [at EXCEPT ![n] = m]
    /\ crossed' = crossed + 1
    /\ UNCHANGED <<proc, age, wait, linked, calls, answers, claims, yields, sent, splits>>

\* A process in a tile of another node calls that node.
Call(n) ==
    /\ proc[n] = "runs" /\ at[n] /= n /\ Linked(n, at[n])
    /\ proc' = [proc EXCEPT ![n] = "calls"]
    /\ wait' = [wait EXCEPT ![n] = sent + 1]
    /\ calls' = calls \cup {[id |-> sent + 1, from |-> n, to |-> at[n], age |-> age[n] + 1]}
    /\ sent' = sent + 1
    /\ UNCHANGED <<age, at, linked, answers, claims, yields, crossed, splits>>

\* A call comes to its node. That node keeps a process of its own that is
\* not older. If not, it starts a process for the boid, and it tells the
\* other nodes.
Adopt(c) ==
    LET m == c.to IN
    /\ Linked(c.from, m)
    /\ IF Alive(m) /\ age[m] >= c.age
       THEN UNCHANGED <<proc, age, at, wait, claims>>
       ELSE /\ proc' = [proc EXCEPT ![m] = "runs"]
            /\ age' = [age EXCEPT ![m] = c.age]
            /\ at' = [at EXCEPT ![m] = m]
            \* A process of the node m that waited for an answer is gone.
            /\ wait' = [wait EXCEPT ![m] = 0]
            /\ claims' =
                IF Announce
                THEN claims \cup {[to |-> k, about |-> m, age |-> c.age, home |-> TRUE, call |-> c.id] : k \in {k \in Nodes \ {m} : Linked(k, m)}}
                ELSE claims
    /\ calls' = calls \ {c}
    /\ answers' = answers \cup {[id |-> c.id, from |-> m, to |-> c.from]}
    /\ UNCHANGED <<linked, yields, sent, crossed, splits>>

\* The process of the node n goes.
Gone(n) ==
    /\ proc' = [proc EXCEPT ![n] = "none"]
    /\ age' = [age EXCEPT ![n] = 0]
    /\ at' = [at EXCEPT ![n] = n]
    /\ wait' = [wait EXCEPT ![n] = 0]

\* The process of the node n stays: its call or its answer is lost.
Stays(n) ==
    /\ proc' = [proc EXCEPT ![n] = "runs"]
    /\ wait' = [wait EXCEPT ![n] = 0]
    /\ UNCHANGED <<age, at>>

\* The answer comes to the process that waits for it: the other node has
\* the boid, and this process stops.
Answer(a) ==
    /\ Linked(a.from, a.to)
    /\ IF wait[a.to] = a.id THEN Gone(a.to) ELSE UNCHANGED <<proc, age, at, wait>>
    /\ answers' = answers \ {a}
    /\ UNCHANGED <<linked, calls, claims, yields, sent, crossed, splits>>

\* A split loses a call: its process stays.
LoseCall(c) ==
    /\ ~Linked(c.from, c.to)
    /\ IF wait[c.from] = c.id THEN Stays(c.from) ELSE UNCHANGED <<proc, age, at, wait>>
    /\ calls' = calls \ {c}
    /\ UNCHANGED <<linked, answers, claims, yields, sent, crossed, splits>>

\* A split loses an answer: the process that waits for it stays.
LoseAnswer(a) ==
    /\ ~Linked(a.from, a.to)
    /\ IF wait[a.to] = a.id THEN Stays(a.to) ELSE UNCHANGED <<proc, age, at, wait>>
    /\ answers' = answers \ {a}
    /\ UNCHANGED <<linked, calls, claims, yields, sent, crossed, splits>>

\* The process of the node n is in a tile of its node. Only the fault
\* model with tiles uses it: a claim of the library has no position.
Home(n) == ~Tiles \/ at[n] = n

\* The first process is stronger than the second: it has more moves; or,
\* in the fault model, the same number of moves and only it is in a tile
\* of its node; or that does not decide, and its node is larger.
Stronger(a1, h1, n1, a2, h2, n2) ==
    \/ a1 > a2
    \/ a1 = a2 /\ Tiles /\ h1 /\ ~h2
    \/ a1 = a2 /\ (~Tiles \/ (h1 <=> h2)) /\ n1 > n2

\* A claim comes to a node that has a process of the boid. The world of
\* the smaller node decides. The world of the larger node sends its own
\* claim to the smaller node. A node whose process waits for the answer
\* of the call of the claim does nothing: that process made the other
\* process, and it stops with the answer.
Claim(cl) ==
    LET n == cl.to IN
    /\ Linked(n, cl.about)
    /\ IF ~Alive(n) \/ (cl.call /= 0 /\ wait[n] = cl.call)
       THEN /\ claims' = claims \ {cl}
            /\ UNCHANGED <<proc, age, at, wait, yields>>
       ELSE IF n < cl.about
            THEN IF Stronger(cl.age, cl.home, cl.about, age[n], Home(n), n)
                 THEN /\ Gone(n)
                      /\ claims' = claims \ {cl}
                      /\ UNCHANGED yields
                 ELSE /\ yields' = yields \cup {[from |-> n, to |-> cl.about, age |-> cl.age]}
                      /\ claims' = claims \ {cl}
                      /\ UNCHANGED <<proc, age, at, wait>>
            ELSE /\ claims' = (claims \ {cl}) \cup {[to |-> cl.about, about |-> n, age |-> age[n], home |-> Home(n), call |-> 0]}
                 /\ UNCHANGED <<proc, age, at, wait, yields>>
    /\ UNCHANGED <<linked, calls, answers, sent, crossed, splits>>

\* A decision comes to its node. That node stops its process only when
\* the process has the age of the decision: a process that came after
\* the decision stays.
Yield(y) ==
    /\ Linked(y.from, y.to)
    /\ IF Alive(y.to) /\ (~Exact \/ age[y.to] = y.age)
       THEN Gone(y.to)
       ELSE UNCHANGED <<proc, age, at, wait>>
    /\ yields' = yields \ {y}
    /\ UNCHANGED <<linked, calls, answers, claims, sent, crossed, splits>>

\* A split of the network cuts these pairs of nodes. A process in a tile
\* of a node that it cannot reach is in a tile of its own node then:
\* each side has all the tiles of the world. The claims and the decisions
\* on their way between two nodes of a pair are lost. A call or an answer
\* is lost too, and its process learns that later (LoseCall, LoseAnswer).
Cut(pairs) ==
    /\ linked = AllPairs /\ splits < Splits
    /\ linked' = linked \ pairs
    /\ at' = [n \in Nodes |-> IF at[n] /= n /\ {n, at[n]} \in pairs THEN n ELSE at[n]]
    /\ splits' = splits + 1
    /\ claims' = {cl \in claims : {cl.to, cl.about} \notin pairs}
    /\ yields' = {y \in yields : {y.from, y.to} \notin pairs}
    /\ UNCHANGED <<proc, age, wait, calls, answers, sent, crossed>>

\* One node has no connection to the others, or no node has a connection.
Split ==
    \/ \E n \in Nodes : Cut({p \in AllPairs : n \in p})
    \/ Apart /\ Cut(AllPairs)

\* All the nodes have a connection again. What was on its way between
\* two nodes at their split is lost before that. Each node of a pair that
\* was cut sends a claim for its process to the other node.
Heal ==
    /\ linked /= AllPairs
    /\ \A c \in calls : Linked(c.from, c.to)
    /\ \A a \in answers : Linked(a.from, a.to)
    /\ linked' = AllPairs
    /\ claims' = claims \cup
        {[to |-> q[2], about |-> q[1], age |-> age[q[1]], home |-> Home(q[1]), call |-> 0] :
            q \in {q \in Nodes \X Nodes : Alive(q[1]) /\ q[1] /= q[2] /\ ~Linked(q[1], q[2])}}
    /\ UNCHANGED <<proc, age, at, wait, calls, answers, yields, sent, crossed, splits>>

\* Nothing is on its way, and each process is in a tile of its node.
Calm ==
    /\ calls = {} /\ answers = {} /\ claims = {} /\ yields = {}
    /\ \A n \in Nodes : proc[n] /= "calls" /\ at[n] = n

One == Cardinality({n \in Nodes : Alive(n)}) = 1

Over == linked = AllPairs /\ Calm /\ UNCHANGED vars

Work ==
    \/ Heal
    \/ \E n \in Nodes : Call(n) \/ \E m \in Nodes : Cross(n, m)
    \/ \E c \in calls : Adopt(c) \/ LoseCall(c)
    \/ \E a \in answers : Answer(a) \/ LoseAnswer(a)
    \/ \E cl \in claims : Claim(cl)
    \/ \E y \in yields : Yield(y)

Next == Over \/ Split \/ Work

Spec == Init /\ [][Next]_vars /\ WF_vars(Work)

\* --- Invariants --------------------------------------------------------

\* No move, no split and no decision loses the boid.
NotLost == \E n \in Nodes : Alive(n)

\* When all the nodes have a connection and nothing is on its way, the
\* boid has one process.
Settled == (linked = AllPairs /\ Calm) => One

\* --- Liveness ----------------------------------------------------------

\* After the last heal, the world comes to rest with one process.
Lands == <>(linked = AllPairs /\ Calm /\ One)
====
