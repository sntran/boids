---- MODULE Move ----
(***************************************************************************)
(* The move of a boid from one node to another node (gen_boid, settle and  *)
(* adopt; boids_world, join, moved, claim and yield). A world is on two    *)
(* nodes here, and it has one boid.                                        *)
(*                                                                         *)
(* The process of the boid is on one node. When the boid is in a tile of   *)
(* the other node, its process calls that node (Call). That node starts a  *)
(* process for the boid, which takes the row (Adopt), and answers. With    *)
(* the answer, the first node removes its row (Moved), and the first       *)
(* process stops (Stop).                                                   *)
(*                                                                         *)
(* A call has no time limit: its answer comes, or the connection between   *)
(* the two nodes ends (Split). After a split, a call or an answer that     *)
(* was on its way is lost. Then the first process stays: the world has     *)
(* two processes for the boid. Each process has an age: the number of      *)
(* moves before it. A node that has a process for the boid keeps it only   *)
(* when it is not older than the process that calls. Thus the two          *)
(* processes cannot stop for each other.                                   *)
(*                                                                         *)
(* When the nodes have a connection again (Heal), the world of the first   *)
(* node (the smaller name) decides which of two processes stays (Judge):   *)
(* the one with more moves, then the one in a tile of its node, then the   *)
(* one of the second node. It stops its own process, or it tells the       *)
(* other node to stop the process of the age that it saw (Yield). Only     *)
(* one world decides, and a process that came after the decision has       *)
(* another age, so the boid keeps a process.                               *)
(***************************************************************************)
EXTENDS Naturals, FiniteSets

CONSTANTS
    Nodes,       \* the two nodes
    Crossings,   \* the times that a process crosses the border (a bound of the model)
    Splits,      \* the times that the connection between the nodes can end (a bound of the model)
    Stops,       \* the nodes that can stop (0 or 1)
    None,        \* no call
    Ages,        \* FALSE: the fault model where a node always keeps its process
    Yields,      \* FALSE: the fault model where a process stays when the other node has the boid
    Exact        \* FALSE: the fault model where a node stops its process of each age when it is told

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
    linked,      \* the two nodes have a connection
    splits,      \* the times that the connection ended
    yield        \* the message to each node to stop its process: the age of that process, or None

vars == <<proc, age, at, row, req, ans, orphan, up, crossed, linked, splits, yield>>

Other(n) == CHOOSE m \in Nodes : m /= n
First == CHOOSE n \in Nodes : TRUE
Second == Other(First)
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
    /\ linked = TRUE
    /\ splits = 0
    /\ yield = [n \in Nodes |-> None]

\* The boid of a process that is in a tile of its node goes across the
\* border. Without a connection, each node has all the tiles.
Cross(n) ==
    /\ proc[n] = "runs" /\ at[n] = n /\ up[Other(n)] /\ linked /\ crossed < Crossings
    /\ at' = [at EXCEPT ![n] = Other(n)]
    /\ crossed' = crossed + 1
    /\ UNCHANGED <<proc, age, row, req, ans, orphan, up, linked, splits, yield>>

\* A process near the border shows its row to the other node.
Show(n) ==
    /\ proc[n] = "runs" /\ up[Other(n)] /\ linked /\ row[Other(n)] = "none"
    /\ row' = [row EXCEPT ![Other(n)] = "ghost"]
    /\ UNCHANGED <<proc, age, at, req, ans, orphan, up, crossed, linked, splits, yield>>

\* A row of a boid of the other node that gets no update goes.
Expire(n) ==
    /\ row[n] = "ghost"
    /\ row' = [row EXCEPT ![n] = "none"]
    /\ UNCHANGED <<proc, age, at, req, ans, orphan, up, crossed, linked, splits, yield>>

\* A process in a tile of the other node calls that node.
Call(n) ==
    /\ proc[n] = "runs" /\ at[n] /= n /\ req[n] = None /\ ans[n] = "none" /\ linked
    /\ proc' = [proc EXCEPT ![n] = "calls"]
    /\ req' = [req EXCEPT ![n] = age[n] + 1]
    /\ UNCHANGED <<age, at, row, ans, orphan, up, crossed, linked, splits, yield>>

\* The call of the node n comes to the other node. That node keeps a
\* process of its own that is not older. If not, it starts a process for
\* the boid, which takes the row.
Adopt(n) ==
    LET m == Other(n) IN
    /\ req[n] /= None /\ up[m] /\ linked
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
    /\ UNCHANGED <<up, crossed, linked, splits, yield>>

\* The call does not come to the other node: that node stopped, or the
\* connection ended.
LoseCall(n) ==
    /\ req[n] /= None
    /\ ~up[Other(n)] \/ ~linked
    /\ req' = [req EXCEPT ![n] = None]
    /\ ans' = IF n \in orphan THEN ans ELSE [ans EXCEPT ![n] = "lost"]
    /\ orphan' = orphan \ {n}
    /\ UNCHANGED <<proc, age, at, row, up, crossed, linked, splits, yield>>

\* The connection ended before the answer came to the process that
\* waits for it.
LoseAnswer(n) ==
    /\ ans[n] \in {"ok", "exists"} /\ ~linked
    /\ ans' = [ans EXCEPT ![n] = "lost"]
    /\ UNCHANGED <<proc, age, at, row, req, orphan, up, crossed, linked, splits, yield>>

\* The other node has the boid: the node of the process removes its row.
Moved(n) ==
    /\ proc[n] = "calls"
    /\ ans[n] = "ok" \/ (ans[n] = "exists" /\ Yields)
    /\ proc' = [proc EXCEPT ![n] = "stops"]
    /\ row' = [row EXCEPT ![n] = "none"]
    /\ ans' = [ans EXCEPT ![n] = "none"]
    /\ UNCHANGED <<age, at, req, orphan, up, crossed, linked, splits, yield>>

\* No answer: the process stays, and it calls again later.
Stay(n) ==
    /\ proc[n] = "calls"
    /\ ans[n] = "lost" \/ (ans[n] = "exists" /\ ~Yields)
    /\ proc' = [proc EXCEPT ![n] = "runs"]
    /\ ans' = [ans EXCEPT ![n] = "none"]
    /\ UNCHANGED <<age, at, row, req, orphan, up, crossed, linked, splits, yield>>

\* The process whose boid moved stops.
Stop(n) ==
    /\ proc[n] = "stops"
    /\ proc' = [proc EXCEPT ![n] = "none"]
    /\ age' = [age EXCEPT ![n] = 0]
    /\ UNCHANGED <<at, row, req, ans, orphan, up, crossed, linked, splits, yield>>

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
    /\ UNCHANGED <<req, crossed, linked, splits, yield>>

\* The connection between the two nodes ends. Each node then has all
\* the tiles of the world.
Split ==
    /\ linked /\ splits < Splits /\ \A n \in Nodes : up[n]
    /\ linked' = FALSE
    /\ splits' = splits + 1
    /\ at' = [n \in Nodes |-> n]
    /\ UNCHANGED <<proc, age, row, req, ans, orphan, up, crossed, yield>>

\* The two nodes have a connection again. What was on its way at the
\* split is lost before that.
Heal ==
    /\ ~linked
    /\ \A n \in Nodes : req[n] = None /\ ans[n] \in {"none", "lost"} /\ yield[n] = None
    /\ linked' = TRUE
    /\ UNCHANGED <<proc, age, at, row, req, ans, orphan, up, crossed, splits, yield>>

\* Of two processes of the boid, the process of the node n stops: it
\* made fewer moves; or the same number, and only the other process is
\* in a tile of its node; or that does not decide, and n is the first
\* node.
Loses(n) ==
    LET m == Other(n) IN
    \/ age[n] < age[m]
    \/ age[n] = age[m] /\ at[n] /= n /\ at[m] = m
    \/ age[n] = age[m] /\ ((at[n] = n) <=> (at[m] = m)) /\ n = First

\* The process of the node n goes, with what it waited for.
Gone(n) ==
    /\ proc' = [proc EXCEPT ![n] = "none"]
    /\ row' = [row EXCEPT ![n] = "none"]
    /\ age' = [age EXCEPT ![n] = 0]
    /\ at' = [at EXCEPT ![n] = n]
    /\ ans' = [ans EXCEPT ![n] = "none"]
    /\ orphan' = orphan \cup (IF req[n] /= None THEN {n} ELSE {})

\* Each node has a process for the boid. The world of the first node
\* decides: it stops its own process, or it tells the second node to
\* stop the process that it has now.
Judge ==
    /\ linked /\ row[First] = "own" /\ row[Second] = "own" /\ yield[Second] = None
    /\ IF Loses(First)
       THEN Gone(First) /\ UNCHANGED yield
       ELSE /\ yield' = [yield EXCEPT ![Second] = age[Second]]
            /\ UNCHANGED <<proc, row, age, at, ans, orphan>>
    /\ UNCHANGED <<req, up, crossed, linked, splits>>

\* The second node gets the decision. It stops its process only when
\* that process has the age of the decision: a process that came after
\* the decision stays.
Yield(n) ==
    /\ yield[n] /= None /\ linked
    /\ IF row[n] = "own" /\ (~Exact \/ age[n] = yield[n])
       THEN Gone(n)
       ELSE UNCHANGED <<proc, row, age, at, ans, orphan>>
    /\ yield' = [yield EXCEPT ![n] = None]
    /\ UNCHANGED <<req, up, crossed, linked, splits>>

\* The connection ended before the decision came to the second node.
LoseYield(n) ==
    /\ yield[n] /= None /\ ~linked
    /\ yield' = [yield EXCEPT ![n] = None]
    /\ UNCHANGED <<proc, age, at, row, req, ans, orphan, up, crossed, linked, splits>>

\* No call, no answer and no decision is on its way, and each process is
\* in a tile of its node.
Calm ==
    \A n \in Nodes :
        /\ req[n] = None /\ ans[n] = "none" /\ yield[n] = None
        /\ proc[n] \in {"none", "runs"}
        /\ proc[n] = "runs" => at[n] = n

One == Cardinality({n \in Nodes : Alive(n)}) <= 1

\* All the crossings are done with a connection, or a node stopped.
Done == (crossed = Crossings /\ linked) \/ \E n \in Nodes : ~up[n]

Over == Done /\ Calm /\ One /\ UNCHANGED vars

Next ==
    \/ Over \/ Split \/ Heal \/ Judge
    \/ \E n \in Nodes :
        \/ Cross(n) \/ Show(n) \/ Expire(n) \/ Call(n) \/ Adopt(n) \/ LoseCall(n)
        \/ LoseAnswer(n) \/ Moved(n) \/ Stay(n) \/ Stop(n) \/ Down(n)
        \/ Yield(n) \/ LoseYield(n)

\* The processes and the nodes that run continue. A split ends, and what
\* was on its way at a split is lost. A node can stop or not, and the
\* connection can end or not.
Work ==
    \/ Heal \/ Judge
    \/ \E n \in Nodes :
        \/ Cross(n) \/ Call(n) \/ Adopt(n) \/ Moved(n) \/ Stay(n) \/ Stop(n) \/ Yield(n)
        \/ ((~up[Other(n)] \/ ~linked) /\ LoseCall(n))
        \/ LoseAnswer(n) \/ LoseYield(n)

Spec == Init /\ [][Next]_vars /\ WF_vars(Work)

\* --- Invariants --------------------------------------------------------

\* A row of a node that is not the row of a boid of the other node has a
\* process of that node, and a process has its row.
RowOwner == \A n \in Nodes : row[n] = "own" <=> Alive(n)

\* While the two nodes run, the boid has a process: no move, no split
\* and no decision loses the boid.
NotLost == (\A n \in Nodes : up[n]) => \E n \in Nodes : Alive(n)

\* With no split: after each move, the boid has a process on one node.
OneProcess == Calm => One

\* --- Liveness ----------------------------------------------------------

\* Each move ends, and after the last heal the boid has one process.
Lands == <>(Done /\ Calm /\ One)
====
