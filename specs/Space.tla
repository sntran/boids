---- MODULE Space ----
(***************************************************************************)
(* A write against a read of the space (boids_space), in two parts.        *)
(*                                                                         *)
(* The boids. The space has one row for each boid, and the grid has a     *)
(* copy of the row in the cell of its position. Only the process of a      *)
(* boid writes its row, in three steps: the row, the new copy in the       *)
(* grid, then the removal of the old copy (put/2). A reader reads the      *)
(* cells one after the other, while the boids write, and keeps one copy    *)
(* of each boid (near/3).                                                  *)
(*                                                                         *)
(* The reader must find each boid one time at most. It must find a boid    *)
(* that stays in its cell. A boid that changes its cell during the read    *)
(* can be absent: the reader read its new cell before the boid came, and   *)
(* its old cell after the boid went.                                       *)
(*                                                                         *)
(* The process of a boid can stop at each moment, also in the middle of a  *)
(* write. The space then removes the row and its copies (remove/2). No     *)
(* copy must stay in the grid.                                             *)
(*                                                                         *)
(* The obstacles. Each obstacle has one row, and an index has the cells    *)
(* of each obstacle (here, one cell). Only the owner of the space writes   *)
(* the obstacles: in a world, the process of the world, which gets each    *)
(* change as a message (boids_world:set/3, set_obstacle/4). So there is    *)
(* one writer, and its writes come one after the other. When that process  *)
(* stops, its tables go with it: no write stays in its middle.             *)
(*                                                                         *)
(* A write changes a version at its start and at its end. It adds the new  *)
(* cell, then changes the row, then removes the old cell. A reader reads   *)
(* the cells one after the other (obstacles/3). When it sees a write that  *)
(* runs, at its start, or a new version at its end, it reads all the rows  *)
(* instead: a read of all the rows of an ETS table of the kind set gets     *)
(* each row one time.                                                      *)
(*                                                                         *)
(* The reader must find each obstacle one time: not two times, and not     *)
(* zero times, also an obstacle that moves during the read.                *)
(*                                                                         *)
(* The writers are a constant of the model. The models of the library      *)
(* have one writer. A fault model has two writers, which shows why the     *)
(* library has only one.                                                   *)
(***************************************************************************)
EXTENDS Naturals, FiniteSets

CONSTANTS
    Boids,       \* the boids
    Cells,       \* the cells of the grid
    Writes,      \* the writes of each boid (a bound of the model)
    InsertFirst, \* FALSE: the fault model where a write removes the old copy first
    Dedupe,      \* FALSE: the fault model where the reader keeps each copy
    RemoveLast,  \* FALSE: the fault model where the space removes only the copy of the row
    Obstacles,   \* the obstacles
    Writers,     \* the processes that write the obstacles: one, or two in a fault model
    Moves,       \* the writes of each writer (a bound of the model)
    CheckVersion \* FALSE: the fault model where the reader of the obstacles does not check the version

VARIABLES
    row,         \* the row of each boid: its cell, and the number of its writes
    grid,        \* the copies of the rows in the grid
    old,         \* the row of each boid before its last write (the row keeps it)
    pc,          \* of the write of each boid: "idle", "row" (the row is written), "half"
    dead,        \* the boids whose process stopped, with their row
    gone,        \* the boids whose row the space removed
    reader,      \* "idle", "reads", "done"
    todo,        \* the cells that the reader did not read
    seen,        \* the copies that the reader read
    moved,       \* the boids that changed their cell during the read
    result,      \* how many times each boid is in the result of the read
    orow,        \* the cell of the row of each obstacle
    index,       \* the cells of the obstacles in the index
    version,     \* the version of the obstacles
    busy,        \* TRUE from the start to the end of a write of an obstacle
    wpc,         \* of each writer: "idle", "open", "add", "row", "drop", "close"
    wob,         \* the obstacle that each writer writes
    wcell,       \* the new cell of that obstacle
    wold,        \* the cell of its row before the write
    wn,          \* the number of the writes of each writer
    oreader,     \* "idle", "cells", "all", "done"
    otodo,       \* the cells that the reader of the obstacles did not read
    ofound,      \* the obstacles that it found in the cells
    over,        \* the version at the start of its read
    oresult      \* how many times each obstacle is in the result of the read

boidVars == <<row, grid, old, pc, dead, gone, reader, todo, seen, moved, result>>
obstacleVars == <<orow, index, version, busy, wpc, wob, wcell, wold, wn,
                  oreader, otodo, ofound, over, oresult>>
vars == <<boidVars, obstacleVars>>

\* The boids whose process runs.
Live == Boids \ (dead \cup gone)

Copy(b, r) == [boid |-> b, cell |-> r.cell, ver |-> r.ver]

Entry(o, c) == [ob |-> o, cell |-> c]

Init ==
    /\ row \in [Boids -> [cell : Cells, ver : {0}]]
    /\ grid = {Copy(b, row[b]) : b \in Boids}
    /\ old = row
    /\ pc = [b \in Boids |-> "idle"]
    /\ dead = {}
    /\ gone = {}
    /\ reader = "idle"
    /\ todo = {}
    /\ seen = {}
    /\ moved = {}
    /\ result = [b \in Boids |-> 0]
    /\ orow \in [Obstacles -> Cells]
    /\ index = {Entry(o, orow[o]) : o \in Obstacles}
    /\ version = 0
    /\ busy = FALSE
    /\ wpc = [w \in Writers |-> "idle"]
    /\ wob = [w \in Writers |-> CHOOSE o \in Obstacles : TRUE]
    /\ wcell = [w \in Writers |-> CHOOSE c \in Cells : TRUE]
    /\ wold = wcell
    /\ wn = [w \in Writers |-> 0]
    /\ oreader = "idle"
    /\ otodo = {}
    /\ ofound = {}
    /\ over = 0
    /\ oresult = [o \in Obstacles |-> 0]

\* --- The write of a boid -----------------------------------------------

\* A boid writes its row, with a new position in the cell c.
Write(b, c) ==
    /\ b \in Live /\ pc[b] = "idle" /\ row[b].ver < Writes
    /\ old' = [old EXCEPT ![b] = row[b]]
    /\ row' = [row EXCEPT ![b] = [cell |-> c, ver |-> row[b].ver + 1]]
    /\ pc' = [pc EXCEPT ![b] = "row"]
    /\ moved' = IF reader = "reads" /\ c /= row[b].cell THEN moved \cup {b} ELSE moved
    /\ UNCHANGED <<grid, dead, gone, reader, todo, seen, result, obstacleVars>>

\* The boid puts the new copy of its row into the grid.
Insert(b) ==
    /\ b \in Live /\ pc[b] = (IF InsertFirst THEN "row" ELSE "half")
    /\ grid' = grid \cup {Copy(b, row[b])}
    /\ pc' = [pc EXCEPT ![b] = IF InsertFirst THEN "half" ELSE "idle"]
    /\ UNCHANGED <<row, old, dead, gone, reader, todo, seen, moved, result, obstacleVars>>

\* The boid removes the old copy of its row from the grid.
Delete(b) ==
    /\ b \in Live /\ pc[b] = (IF InsertFirst THEN "half" ELSE "row")
    /\ grid' = grid \ {Copy(b, old[b])}
    /\ pc' = [pc EXCEPT ![b] = IF InsertFirst THEN "idle" ELSE "half"]
    /\ UNCHANGED <<row, old, dead, gone, reader, todo, seen, moved, result, obstacleVars>>

\* --- The end of a boid ---------------------------------------------------

\* The process of a boid stops, at each moment: its write stops where it is.
Kill(b) ==
    /\ b \in Live
    /\ dead' = dead \cup {b}
    /\ UNCHANGED <<row, grid, old, pc, gone, reader, todo, seen, moved, result, obstacleVars>>

\* The space removes the row of a boid whose process stopped, with the
\* copy of the row and the copy before its last write.
Remove(b) ==
    /\ b \in dead
    /\ grid' = grid \ ({Copy(b, row[b])} \cup (IF RemoveLast THEN {Copy(b, old[b])} ELSE {}))
    /\ dead' = dead \ {b}
    /\ gone' = gone \cup {b}
    /\ UNCHANGED <<row, old, pc, reader, todo, seen, moved, result, obstacleVars>>

\* --- The read of the boids -----------------------------------------------

\* The read starts. A boid in the middle of a write to another cell
\* counts as a boid that changes its cell during the read.
Begin ==
    /\ Boids /= {} /\ reader = "idle"
    /\ reader' = "reads"
    /\ todo' = Cells
    /\ moved' = {b \in Boids : pc[b] /= "idle" /\ old[b].cell /= row[b].cell}
    /\ UNCHANGED <<row, grid, old, pc, dead, gone, seen, result, obstacleVars>>

\* The reader reads all the copies of one cell (one ets:lookup/2).
Read(c) ==
    /\ reader = "reads" /\ c \in todo
    /\ seen' = seen \cup {x \in grid : x.cell = c}
    /\ todo' = todo \ {c}
    /\ UNCHANGED <<row, grid, old, pc, dead, gone, reader, moved, result, obstacleVars>>

\* The reader read each cell: it keeps one copy of each boid.
End ==
    /\ reader = "reads" /\ todo = {}
    /\ result' = [b \in Boids |->
                    LET n == Cardinality({x \in seen : x.boid = b})
                    IN IF Dedupe /\ n > 1 THEN 1 ELSE n]
    /\ reader' = "done"
    /\ UNCHANGED <<row, grid, old, pc, dead, gone, todo, seen, moved, obstacleVars>>

\* --- The write of an obstacle ---------------------------------------------

\* The writer w gets a change: the obstacle o moves to the cell c. For
\* the process of a world, this is the next message.
Get(w, o, c) ==
    /\ wpc[w] = "idle" /\ wn[w] < Moves
    /\ wpc' = [wpc EXCEPT ![w] = "open"]
    /\ wob' = [wob EXCEPT ![w] = o]
    /\ wcell' = [wcell EXCEPT ![w] = c]
    /\ UNCHANGED <<boidVars, orow, index, version, busy, wold, wn, oreader, otodo, ofound, over, oresult>>

\* The write starts: a new version, and the read of the row.
Open(w) ==
    /\ wpc[w] = "open"
    /\ version' = version + 1
    /\ busy' = TRUE
    /\ wold' = [wold EXCEPT ![w] = orow[wob[w]]]
    /\ wpc' = [wpc EXCEPT ![w] = "add"]
    /\ UNCHANGED <<boidVars, orow, index, wob, wcell, wn, oreader, otodo, ofound, over, oresult>>

\* The new cell goes into the index (ets:insert/2).
AddCell(w) ==
    /\ wpc[w] = "add"
    /\ index' = index \cup {Entry(wob[w], wcell[w])}
    /\ wpc' = [wpc EXCEPT ![w] = "row"]
    /\ UNCHANGED <<boidVars, orow, version, busy, wob, wcell, wold, wn, oreader, otodo, ofound, over, oresult>>

\* The row changes (ets:insert/2).
MoveRow(w) ==
    /\ wpc[w] = "row"
    /\ orow' = [orow EXCEPT ![wob[w]] = wcell[w]]
    /\ wpc' = [wpc EXCEPT ![w] = "drop"]
    /\ UNCHANGED <<boidVars, index, version, busy, wob, wcell, wold, wn, oreader, otodo, ofound, over, oresult>>

\* The old cell goes from the index (ets:delete_object/2).
DropCell(w) ==
    /\ wpc[w] = "drop"
    /\ index' = IF wold[w] = wcell[w] THEN index ELSE index \ {Entry(wob[w], wold[w])}
    /\ wpc' = [wpc EXCEPT ![w] = "close"]
    /\ UNCHANGED <<boidVars, orow, version, busy, wob, wcell, wold, wn, oreader, otodo, ofound, over, oresult>>

\* The write ends: a new version.
Close(w) ==
    /\ wpc[w] = "close"
    /\ version' = version + 1
    /\ busy' = FALSE
    /\ wn' = [wn EXCEPT ![w] = wn[w] + 1]
    /\ wpc' = [wpc EXCEPT ![w] = "idle"]
    /\ UNCHANGED <<boidVars, orow, index, wob, wcell, wold, oreader, otodo, ofound, over, oresult>>

\* --- The read of the obstacles ---------------------------------------------

\* The read starts. When a write runs, the reader reads all the rows.
Look ==
    /\ Obstacles /= {} /\ oreader = "idle"
    /\ oreader' = IF CheckVersion /\ busy THEN "all" ELSE "cells"
    /\ otodo' = Cells
    /\ over' = version
    /\ UNCHANGED <<boidVars, orow, index, version, busy, wpc, wob, wcell, wold, wn, ofound, oresult>>

\* The reader reads the obstacles of one cell (one ets:lookup/2).
LookAt(c) ==
    /\ oreader = "cells" /\ c \in otodo
    /\ ofound' = ofound \cup {e.ob : e \in {x \in index : x.cell = c}}
    /\ otodo' = otodo \ {c}
    /\ UNCHANGED <<boidVars, orow, index, version, busy, wpc, wob, wcell, wold, wn, oreader, over, oresult>>

\* The reader read each cell. A new version since the start of the read
\* means a write during the read: then the reader reads all the rows.
\* The obstacles that it found are a set: each one time.
Check ==
    /\ oreader = "cells" /\ otodo = {}
    /\ oresult' = IF CheckVersion /\ version /= over
                  THEN [o \in Obstacles |-> 1]
                  ELSE [o \in Obstacles |-> IF o \in ofound THEN 1 ELSE 0]
    /\ oreader' = "done"
    /\ UNCHANGED <<boidVars, orow, index, version, busy, wpc, wob, wcell, wold, wn, otodo, ofound, over>>

\* The reader reads all the rows: each obstacle one time.
LookAll ==
    /\ oreader = "all"
    /\ oresult' = [o \in Obstacles |-> 1]
    /\ oreader' = "done"
    /\ UNCHANGED <<boidVars, orow, index, version, busy, wpc, wob, wcell, wold, wn, otodo, ofound, over>>

\* --- The end -------------------------------------------------------------

\* Each boid made its writes or went, each writer made its writes, and
\* the reads are done.
Over ==
    /\ reader = "done" \/ Boids = {}
    /\ oreader = "done" \/ Obstacles = {}
    /\ \A b \in Boids : b \in gone \/ (b \in Live /\ pc[b] = "idle" /\ row[b].ver = Writes)
    /\ \A w \in Writers : wpc[w] = "idle" /\ wn[w] = Moves
    /\ UNCHANGED vars

Next ==
    \/ \E b \in Boids : (\E c \in Cells : Write(b, c)) \/ Insert(b) \/ Delete(b) \/ Kill(b) \/ Remove(b)
    \/ Begin
    \/ \E c \in Cells : Read(c)
    \/ End
    \/ \E w \in Writers :
        \/ \E o \in Obstacles, c \in Cells : Get(w, o, c)
        \/ Open(w) \/ AddCell(w) \/ MoveRow(w) \/ DropCell(w) \/ Close(w)
    \/ Look
    \/ \E c \in Cells : LookAt(c)
    \/ Check
    \/ LookAll
    \/ Over

Spec == Init /\ [][Next]_vars /\ WF_vars(Next)

\* --- Invariants --------------------------------------------------------

\* A boid is in the result of a read one time at most.
OneTime == reader = "done" => \A b \in Boids : result[b] <= 1

\* A boid that runs, and that did not change its cell during the read, is
\* in the result.
Finds == reader = "done" => \A b \in Live \ moved : result[b] >= 1

\* When a boid that runs does not write, the grid has one copy of its
\* row, in the cell of the row: no old copy stays.
Whole == \A b \in Live : pc[b] = "idle" => {x \in grid : x.boid = b} = {Copy(b, row[b])}

\* The grid has no copy of a boid whose row the space removed.
Gone == \A b \in gone : {x \in grid : x.boid = b} = {}

\* A read of the obstacles finds each obstacle one time: not two times,
\* and not zero times, also an obstacle that moved during the read.
Exact == oreader = "done" => \A o \in Obstacles : oresult[o] = 1

\* At each moment, the index has the cell of the row of each obstacle.
Indexed == \A o \in Obstacles : Entry(o, orow[o]) \in index

\* When no write runs, the index has only the cells of the rows: no old
\* cell stays.
Clean == (\A w \in Writers : wpc[w] = "idle") => index = {Entry(o, orow[o]) : o \in Obstacles}

\* --- Liveness ----------------------------------------------------------

\* The reads end.
Reads == <>(reader = "done" \/ Boids = {})
ReadsObstacles == <>(oreader = "done" \/ Obstacles = {})
====
