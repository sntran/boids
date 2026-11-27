---- MODULE Members ----
(***************************************************************************)
(* The members of a world (boids_world). A process becomes a  *)
(* boid: it asks the world for the row of its id (join). The         *)
(* world gives the row when the id is free, and watches the process  *)
(* (a monitor). The row goes when the process stops (the message 'DOWN'),  *)
(* when boids:remove/2 stops the process and then tells the world    *)
(* (leave), or when the process itself tells the world (leave).      *)
(*                                                                         *)
(* The world handles one message at a time. The messages of two      *)
(* processes come in each order: the 'DOWN' of a process that stopped can  *)
(* come after the join of the process that starts again with its id, and a *)
(* leave for a process can come after another process has its id.          *)
(***************************************************************************)
EXTENDS Naturals, FiniteSets

CONSTANTS
    Ids,        \* the ids of the boids
    Procs,      \* the processes; each starts one time
    None,       \* no process, no id
    TakeOver,   \* FALSE: the fault model where the world keeps the row of a process that stopped
    CheckOwner  \* FALSE: the fault model where a leave removes the row of each process

VARIABLES
    state,      \* of each process: "new", "asked" (it waits for the answer to its join),
                \* "runs" (it has its row), "refused", "leaving" (it waits for the answer
                \* to its leave), "out" (it runs with no row), "stopped"
    idOf,       \* the id that each process asked for
    row,        \* the process that has the row of each id
    mon,        \* the processes that the world watches
    box,        \* the messages to the world that it did not handle
    found,      \* the processes that a caller of boids:remove/2 found in the table
    left,       \* the processes with a leave
    unfair      \* TRUE after the world refused an id whose process stopped

vars == <<state, idOf, row, mon, box, found, left, unfair>>

Msg(type, p) == [type |-> type, proc |-> p]

Init ==
    /\ state = [p \in Procs |-> "new"]
    /\ idOf = [p \in Procs |-> None]
    /\ row = [i \in Ids |-> None]
    /\ mon = {}
    /\ box = {}
    /\ found = {}
    /\ left = {}
    /\ unfair = FALSE

\* --- The processes -----------------------------------------------------

\* A process starts for an id (boids:add/2, or boids:join/2 in a process
\* that its supervisor starts again), and asks the world for the row.
Start(p, i) ==
    /\ state[p] = "new"
    /\ state' = [state EXCEPT ![p] = "asked"]
    /\ idOf' = [idOf EXCEPT ![p] = i]
    /\ box' = box \cup {Msg("join", p)}
    /\ UNCHANGED <<row, mon, found, left, unfair>>

\* A process stops: an error, a kill, or the end of its work. The world
\* gets 'DOWN' when it watches the process.
Stop(p) ==
    /\ state[p] \in {"asked", "runs", "leaving", "out"}
    /\ state' = [state EXCEPT ![p] = "stopped"]
    /\ box' = IF p \in mon THEN box \cup {Msg("down", p)} ELSE box
    /\ UNCHANGED <<idOf, row, mon, found, left, unfair>>

\* A caller of boids:remove/2 reads the table, and finds the process of an id.
Find(p) ==
    /\ idOf[p] /= None /\ row[idOf[p]] = p
    /\ found' = found \cup {p}
    /\ UNCHANGED <<state, idOf, row, mon, box, left, unfair>>

\* That caller stops the process that it found, then tells the world.
Remove(p) ==
    /\ p \in found /\ p \notin left
    /\ left' = left \cup {p}
    /\ state' = [state EXCEPT ![p] = "stopped"]
    /\ box' = box \cup {Msg("leave", p)} \cup
              (IF state[p] /= "stopped" /\ p \in mon THEN {Msg("down", p)} ELSE {})
    /\ UNCHANGED <<idOf, row, mon, found, unfair>>

\* A process that runs tells the world that it is not a boid now (boids:leave/2).
Quit(p) ==
    /\ state[p] = "runs" /\ p \notin left
    /\ left' = left \cup {p}
    /\ state' = [state EXCEPT ![p] = "leaving"]
    /\ box' = box \cup {Msg("leave", p)}
    /\ UNCHANGED <<idOf, row, mon, found, unfair>>

\* --- The world ---------------------------------------------------

\* The world handles a join. It first forgets the row of a process that
\* stopped (the 'DOWN' of that process is not necessary then). A free id
\* gives the row: the world watches the process, and a process that
\* stopped before this gives 'DOWN' at once.
Join(p) ==
    /\ Msg("join", p) \in box
    /\ LET i == idOf[p]
           o == row[i]
           take == TakeOver /\ o /= None /\ state[o] = "stopped"
           rest == (box \ {Msg("join", p)}) \ (IF take THEN {Msg("down", o)} ELSE {})
       IN IF o = None \/ take
          THEN /\ row' = [row EXCEPT ![i] = p]
               /\ mon' = (IF take THEN mon \ {o} ELSE mon) \cup {p}
               /\ state' = [state EXCEPT ![p] = IF @ = "asked" THEN "runs" ELSE @]
               /\ box' = IF state[p] = "stopped" THEN rest \cup {Msg("down", p)} ELSE rest
               /\ UNCHANGED unfair
          ELSE /\ state' = [state EXCEPT ![p] = IF @ = "asked" THEN "refused" ELSE @]
               /\ box' = rest
               /\ unfair' = (unfair \/ state[o] = "stopped")
               /\ UNCHANGED <<row, mon>>
    /\ UNCHANGED <<idOf, found, left>>

\* The world handles the 'DOWN' of a process that it watches: the row goes.
\* The join of a process comes before its 'DOWN'.
Down(p) ==
    /\ Msg("down", p) \in box
    /\ Msg("join", p) \notin box
    /\ box' = box \ {Msg("down", p)}
    /\ IF p \in mon
       THEN row' = [row EXCEPT ![idOf[p]] = None] /\ mon' = mon \ {p}
       ELSE UNCHANGED <<row, mon>>
    /\ UNCHANGED <<state, idOf, found, left, unfair>>

\* The world handles a leave for a process: the row of its id goes only
\* when that process has it. Then the world does not watch the process.
Leave(p) ==
    /\ Msg("leave", p) \in box
    /\ LET i == idOf[p]
           o == row[i]
           forget == o /= None /\ (o = p \/ ~CheckOwner)
       IN /\ row' = IF forget THEN [row EXCEPT ![i] = None] ELSE row
          /\ mon' = IF forget THEN mon \ {o} ELSE mon
          /\ box' = (box \ {Msg("leave", p)}) \ (IF forget THEN {Msg("down", o)} ELSE {})
    /\ state' = [state EXCEPT ![p] = IF @ = "leaving" THEN "out" ELSE @]
    /\ UNCHANGED <<idOf, found, left, unfair>>

Handle == \E p \in Procs : Join(p) \/ Down(p) \/ Leave(p)

\* Each process stopped or was refused, and the world handled each message.
Over == box = {} /\ (\A p \in Procs : state[p] \in {"stopped", "refused"}) /\ UNCHANGED vars

Next ==
    \/ \E p \in Procs : (\E i \in Ids : Start(p, i)) \/ Stop(p) \/ Find(p) \/ Remove(p) \/ Quit(p)
    \/ Handle
    \/ Over

Spec == Init /\ [][Next]_vars /\ WF_vars(Handle)

\* --- Invariants --------------------------------------------------------

\* A process that runs as a boid has the row of its id.
LiveHasRow == \A p \in Procs : state[p] = "runs" => row[idOf[p]] = p

\* The world watches each process that has a row, and no other process.
Watched == mon = {row[i] : i \in Ids} \ {None}

\* When the world handled each message, each row has a process that runs.
NoLostRow == box = {} => \A i \in Ids : row[i] /= None => state[row[i]] = "runs"

\* The world refuses an id only when its process did not stop.
Fair == ~unfair

\* --- Liveness ----------------------------------------------------------

\* In the end, each row has a process that runs: the row of a process
\* that stopped does not stay.
Cleans == <>[](\A i \in Ids : row[i] /= None => state[row[i]] = "runs")
====
