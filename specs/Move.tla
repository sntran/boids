---- MODULE Move ----
(***************************************************************************)
(* The move of a boid from one node to another node (gen_boid, settle and  *)
(* adopt; boids_world, join and moved). A world is on two nodes here, and  *)
(* it has one boid.                                                        *)
(*                                                                         *)
(* The process of the boid is on one node. When the boid is in a tile of   *)
(* the other node, its process calls that node (Call). That node starts a  *)
(* process for the boid, which takes the row (Adopt), and answers. With    *)
(* the answer, the first node removes its row (Moved), and the first       *)
(* process stops (Stop).                                                   *)
(*                                                                         *)
(* The answer of a call can be lost. Then the first process stays, and     *)
(* calls again later: the world has two processes for the boid for some    *)
(* time. Each process has an age: the number of moves before it. A node    *)
(* that has a process for the boid keeps it only when it is not older      *)
(* than the process that calls. Thus the two processes cannot stop for     *)
(* each other.                                                             *)
(***************************************************************************)
EXTENDS Naturals, FiniteSets

CONSTANTS
    Nodes,       \* the two nodes
    Crossings,   \* the times that a process crosses the border (a bound of the model)
    Losses,      \* the answers and the calls that can be lost (a bound of the model)
    Stops,       \* the nodes that can stop (0 or 1)
    None,        \* no call
    Ages,        \* FALSE: the fault model where a node always keeps its process
    Yields       \* FALSE: the fault model where a process stays when the other node has the boid

VARIABLES
    proc,        \* the process of the boid on each node: "none", "runs", "calls" or "stops"
    age,         \* the age of the process of each node
    at,          \* the node of the tile where the process of each node is
    row,         \* the row of the boid on each node: "none", "own" or "ghost"
    req,         \* the call of each node that is on its way: the age for the new process, or None
    ans,         \* the answer for the process of each node: "none", "ok", "exists" or "lost"
    orphan,      \* the nodes whose call has no process that waits for its answer
    up,          \* the nodes that run
    crossed,     \* the times that a process crossed the border
    lost         \* the answers and the calls that were lost

vars == <<proc, age, at, row, req, ans, orphan, up, crossed, lost>>

Other(n) == CHOOSE m \in Nodes : m /= n
First == CHOOSE n \in Nodes : TRUE
Alive(n) == proc[n] \in {"runs", "calls"}

Init ==
    /\ proc = [n \in Nodes |-> IF n = First THEN "runs" ELSE "none"]
    /\ row = [n \in Nodes |-> IF n = First THEN "own" ELSE "none"]
    /\ age = [n \in Nodes |-> 0]
    /\ at = [n \in Nodes |-> n]
    /\ req = [n \in Nodes |-> None]
    /\ ans = [n \in Nodes |-> "none"]
    /\ orphan = {}
    /\ up = [n \in Nodes |-> TRUE]
    /\ crossed = 0
    /\ lost = 0

\* The boid of a process that is in a tile of its node goes across the border.
Cross(n) ==
    /\ proc[n] = "runs" /\ at[n] = n /\ up[Other(n)] /\ crossed < Crossings
    /\ at' = [at EXCEPT ![n] = Other(n)]
    /\ crossed' = crossed + 1
    /\ UNCHANGED <<proc, age, row, req, ans, orphan, up, lost>>

\* A process near the border shows its row to the other node.
Show(n) ==
    /\ proc[n] = "runs" /\ up[Other(n)] /\ row[Other(n)] = "none"
    /\ row' = [row EXCEPT ![Other(n)] = "ghost"]
    /\ UNCHANGED <<proc, age, at, req, ans, orphan, up, crossed, lost>>

\* A row of a boid of the other node that gets no update goes.
Expire(n) ==
    /\ row[n] = "ghost"
    /\ row' = [row EXCEPT ![n] = "none"]
    /\ UNCHANGED <<proc, age, at, req, ans, orphan, up, crossed, lost>>

\* A process in a tile of the other node calls that node.
Call(n) ==
    /\ proc[n] = "runs" /\ at[n] /= n /\ req[n] = None /\ ans[n] = "none"
    /\ proc' = [proc EXCEPT ![n] = "calls"]
    /\ req' = [req EXCEPT ![n] = age[n] + 1]
    /\ UNCHANGED <<age, at, row, ans, orphan, up, crossed, lost>>

\* The call of the node n comes to the other node. That node keeps a
\* process of its own that is not older. If not, it starts a process for
\* the boid, which takes the row.
Adopt(n) ==
    LET m == Other(n) IN
    /\ req[n] /= None /\ up[m]
    /\ IF row[m] = "own" /\ (~Ages \/ age[m] >= req[n])
       THEN /\ ans' = IF n \in orphan THEN ans ELSE [ans EXCEPT ![n] = "exists"]
            /\ orphan' = orphan \ {n}
            /\ UNCHANGED <<proc, age, at, row>>
       ELSE /\ proc' = [proc EXCEPT ![m] = "runs"]
            /\ age' = [age EXCEPT ![m] = req[n]]
            /\ at' = [at EXCEPT ![m] = m]
            /\ row' = [row EXCEPT ![m] = "own"]
            \* A process of the node m that waited for an answer is gone.
            /\ ans' = [k \in Nodes |-> IF k = m THEN "none" ELSE IF n \in orphan THEN ans[k] ELSE "ok"]
            /\ orphan' = (orphan \ {n}) \cup (IF req[m] /= None THEN {m} ELSE {})
    /\ req' = [req EXCEPT ![n] = None]
    /\ UNCHANGED <<up, crossed, lost>>

\* The call does not come to the other node: that node stopped, or the
\* network lost the call.
LoseCall(n) ==
    /\ req[n] /= None
    /\ ~up[Other(n)] \/ lost < Losses
    /\ req' = [req EXCEPT ![n] = None]
    /\ ans' = IF n \in orphan THEN ans ELSE [ans EXCEPT ![n] = "lost"]
    /\ orphan' = orphan \ {n}
    /\ lost' = IF up[Other(n)] THEN lost + 1 ELSE lost
    /\ UNCHANGED <<proc, age, at, row, up, crossed>>

\* The answer does not come to the process that waits for it.
LoseAnswer(n) ==
    /\ ans[n] \in {"ok", "exists"} /\ lost < Losses
    /\ ans' = [ans EXCEPT ![n] = "lost"]
    /\ lost' = lost + 1
    /\ UNCHANGED <<proc, age, at, row, req, orphan, up, crossed>>

\* The other node has the boid: the node of the process removes its row.
Moved(n) ==
    /\ proc[n] = "calls"
    /\ ans[n] = "ok" \/ (ans[n] = "exists" /\ Yields)
    /\ proc' = [proc EXCEPT ![n] = "stops"]
    /\ row' = [row EXCEPT ![n] = "none"]
    /\ ans' = [ans EXCEPT ![n] = "none"]
    /\ UNCHANGED <<age, at, req, orphan, up, crossed, lost>>

\* No answer: the process stays, and it calls again later.
Stay(n) ==
    /\ proc[n] = "calls"
    /\ ans[n] = "lost" \/ (ans[n] = "exists" /\ ~Yields)
    /\ proc' = [proc EXCEPT ![n] = "runs"]
    /\ ans' = [ans EXCEPT ![n] = "none"]
    /\ UNCHANGED <<age, at, row, req, orphan, up, crossed, lost>>

\* The process whose boid moved stops.
Stop(n) ==
    /\ proc[n] = "stops"
    /\ proc' = [proc EXCEPT ![n] = "none"]
    /\ age' = [age EXCEPT ![n] = 0]
    /\ UNCHANGED <<at, row, req, ans, orphan, up, crossed, lost>>

\* A node stops, with its process and its rows. Its tiles go to the other node.
Down(n) ==
    /\ up[n] /\ Cardinality({k \in Nodes : ~up[k]}) < Stops
    /\ up' = [up EXCEPT ![n] = FALSE]
    /\ proc' = [proc EXCEPT ![n] = "none"]
    /\ age' = [age EXCEPT ![n] = 0]
    /\ row' = [row EXCEPT ![n] = "none"]
    /\ ans' = [ans EXCEPT ![n] = "none"]
    /\ at' = [at EXCEPT ![Other(n)] = Other(n)]
    /\ orphan' = orphan \cup (IF req[n] /= None THEN {n} ELSE {})
    /\ UNCHANGED <<req, crossed, lost>>

\* All the moves are done, and each process is in a tile of its node.
Rest ==
    \A n \in Nodes :
        /\ req[n] = None /\ ans[n] = "none"
        /\ proc[n] \in {"none", "runs"}
        /\ proc[n] = "runs" => at[n] = n

Done == crossed = Crossings \/ \E n \in Nodes : ~up[n]

Over == Done /\ Rest /\ UNCHANGED vars

Next ==
    \/ Over
    \/ \E n \in Nodes :
        \/ Cross(n) \/ Show(n) \/ Expire(n) \/ Call(n) \/ Adopt(n) \/ LoseCall(n)
        \/ LoseAnswer(n) \/ Moved(n) \/ Stay(n) \/ Stop(n) \/ Down(n)

\* The processes and the nodes that run continue, and a call to a node
\* that stopped fails. A call or an answer can be lost or not, and a
\* node can stop or not.
Work ==
    \E n \in Nodes :
        \/ Cross(n) \/ Call(n) \/ Adopt(n) \/ Moved(n) \/ Stay(n) \/ Stop(n)
        \/ (~up[Other(n)] /\ LoseCall(n))

Spec == Init /\ [][Next]_vars /\ WF_vars(Work)

\* --- Invariants --------------------------------------------------------

\* A row of a node that is not the row of a boid of the other node has a
\* process of that node, and a process has its row.
RowOwner == \A n \in Nodes : row[n] = "own" <=> Alive(n)

\* While the two nodes run, the boid has a process.
NotLost == (\A n \in Nodes : up[n]) => \E n \in Nodes : Alive(n)

\* With no lost answer: after each move, the boid has a process on one node.
OneProcess == Rest => Cardinality({n \in Nodes : Alive(n)}) <= 1

\* --- Liveness ----------------------------------------------------------

\* Each move ends.
Lands == <>(Done /\ Rest)
====
