---- MODULE Space ----
(***************************************************************************)
(* A write of a row against a read of the grid (boids_space). The space   *)
(* has one row for each boid, and the grid has a copy of the row in the   *)
(* cell of its position. Only the process of a boid writes its row, in    *)
(* three steps: the row, the new copy in the grid, then the removal of    *)
(* the old copy (put/2). A reader reads the cells one after the other,    *)
(* while the boids write, and keeps one copy of each boid (near/3).       *)
(*                                                                         *)
(* The reader must find each boid one time at most. It must find a boid   *)
(* that stays in its cell. A boid that changes its cell during the read   *)
(* can be absent: the reader read its new cell before the boid came, and  *)
(* its old cell after the boid went.                                      *)
(***************************************************************************)
EXTENDS Naturals, FiniteSets

CONSTANTS
    Boids,       \* the boids
    Cells,       \* the cells of the grid
    Writes,      \* the writes of each boid (a bound of the model)
    InsertFirst, \* FALSE: the fault model where a write removes the old copy first
    Dedupe       \* FALSE: the fault model where the reader keeps each copy

VARIABLES
    row,         \* the row of each boid: its cell, and the number of its writes
    grid,        \* the copies of the rows in the grid
    old,         \* the row of each boid before its last write
    pc,          \* of the write of each boid: "idle", "row" (the row is written), "half"
    reader,      \* "idle", "reads", "done"
    todo,        \* the cells that the reader did not read
    seen,        \* the copies that the reader read
    moved,       \* the boids that changed their cell during the read
    result       \* how many times each boid is in the result of the read

vars == <<row, grid, old, pc, reader, todo, seen, moved, result>>

Copy(b, r) == [boid |-> b, cell |-> r.cell, ver |-> r.ver]

Init ==
    /\ row \in [Boids -> [cell : Cells, ver : {0}]]
    /\ grid = {Copy(b, row[b]) : b \in Boids}
    /\ old = row
    /\ pc = [b \in Boids |-> "idle"]
    /\ reader = "idle"
    /\ todo = {}
    /\ seen = {}
    /\ moved = {}
    /\ result = [b \in Boids |-> 0]

\* --- The write of a boid -----------------------------------------------

\* A boid writes its row, with a new position in the cell c.
Write(b, c) ==
    /\ pc[b] = "idle" /\ row[b].ver < Writes
    /\ old' = [old EXCEPT ![b] = row[b]]
    /\ row' = [row EXCEPT ![b] = [cell |-> c, ver |-> row[b].ver + 1]]
    /\ pc' = [pc EXCEPT ![b] = "row"]
    /\ moved' = IF reader = "reads" /\ c /= row[b].cell THEN moved \cup {b} ELSE moved
    /\ UNCHANGED <<grid, reader, todo, seen, result>>

\* The boid puts the new copy of its row into the grid.
Insert(b) ==
    /\ pc[b] = (IF InsertFirst THEN "row" ELSE "half")
    /\ grid' = grid \cup {Copy(b, row[b])}
    /\ pc' = [pc EXCEPT ![b] = IF InsertFirst THEN "half" ELSE "idle"]
    /\ UNCHANGED <<row, old, reader, todo, seen, moved, result>>

\* The boid removes the old copy of its row from the grid.
Delete(b) ==
    /\ pc[b] = (IF InsertFirst THEN "half" ELSE "row")
    /\ grid' = grid \ {Copy(b, old[b])}
    /\ pc' = [pc EXCEPT ![b] = IF InsertFirst THEN "idle" ELSE "half"]
    /\ UNCHANGED <<row, old, reader, todo, seen, moved, result>>

\* --- The read ----------------------------------------------------------

\* The read starts. A boid in the middle of a write to another cell
\* counts as a boid that changes its cell during the read.
Begin ==
    /\ reader = "idle"
    /\ reader' = "reads"
    /\ todo' = Cells
    /\ moved' = {b \in Boids : pc[b] /= "idle" /\ old[b].cell /= row[b].cell}
    /\ UNCHANGED <<row, grid, old, pc, seen, result>>

\* The reader reads all the copies of one cell (one ets:lookup/2).
Read(c) ==
    /\ reader = "reads" /\ c \in todo
    /\ seen' = seen \cup {x \in grid : x.cell = c}
    /\ todo' = todo \ {c}
    /\ UNCHANGED <<row, grid, old, pc, reader, moved, result>>

\* The reader read each cell: it keeps one copy of each boid.
End ==
    /\ reader = "reads" /\ todo = {}
    /\ result' = [b \in Boids |->
                    LET n == Cardinality({x \in seen : x.boid = b})
                    IN IF Dedupe /\ n > 1 THEN 1 ELSE n]
    /\ reader' = "done"
    /\ UNCHANGED <<row, grid, old, pc, todo, seen, moved>>

\* Each boid made its writes, and the read is done.
Over ==
    /\ reader = "done"
    /\ \A b \in Boids : pc[b] = "idle" /\ row[b].ver = Writes
    /\ UNCHANGED vars

Next ==
    \/ \E b \in Boids : (\E c \in Cells : Write(b, c)) \/ Insert(b) \/ Delete(b)
    \/ Begin
    \/ \E c \in Cells : Read(c)
    \/ End
    \/ Over

Spec == Init /\ [][Next]_vars /\ WF_vars(Next)

\* --- Invariants --------------------------------------------------------

\* A boid is in the result of a read one time at most.
OneTime == reader = "done" => \A b \in Boids : result[b] <= 1

\* A boid that did not change its cell during the read is in the result.
Finds == reader = "done" => \A b \in Boids \ moved : result[b] >= 1

\* When a boid does not write, the grid has one copy of its row, in the
\* cell of the row: no old copy stays.
Whole == \A b \in Boids : pc[b] = "idle" => {x \in grid : x.boid = b} = {Copy(b, row[b])}

\* --- Liveness ----------------------------------------------------------

\* The read ends.
Reads == <>(reader = "done")
====
