---- MODULE Kept ----
(***************************************************************************)
(* A fact of a world that the boids keep (boids_space:set_grid/3,          *)
(* named/3).                                                               *)
(*                                                                         *)
(* A grid of a world is one row of a table: a large binary. A boid that    *)
(* reads the row at each step gets a new reference to the binary at each   *)
(* step, and its garbage collection runs at each step. So a boid keeps     *)
(* what it read, with the number of the changes of the space at that       *)
(* read. At each step it reads the number, and it reads the row again      *)
(* only when the number changed.                                           *)
(*                                                                         *)
(* Only the owner of the space writes: in a world, the process of the      *)
(* world, which gets each change as a message. The message comes from a    *)
(* caller (boids_world:set/3), or from the world of another node: a fact   *)
(* of that node, or all its facts after a join (specs/Facts.tla). The      *)
(* process makes the two kinds of change with the same function, one       *)
(* after the other. So there is one writer on a node, and the model is     *)
(* about one node: each node has its own row and its own number.           *)
(*                                                                         *)
(* A write changes the row, and then it adds 1 to the number of the        *)
(* changes. A read gets the number, and then the row.                      *)
(*                                                                         *)
(* A boid must not keep an old row for all the time. When no write runs,   *)
(* a boid that uses what it kept (its number is the number of the space)   *)
(* has the row of the table. A step of a boid during a write can use the   *)
(* row before the write or the row after it: the two are right.            *)
(*                                                                         *)
(* The two orders are the two guards of the model. A fault model changes   *)
(* one of them, and a boid then keeps an old row with the new number.      *)
(***************************************************************************)
EXTENDS Naturals

CONSTANTS
    Boids,      \* the boids that keep the row
    Writes,     \* the writes of the owner (a bound of the model)
    RowFirst,   \* FALSE: the fault model where a write changes the number before the row
    CountFirst  \* FALSE: the fault model where a read gets the row before the number

VARIABLES
    row,        \* the row: the number of its last write
    changes,    \* the number of the changes of the space
    wpc,        \* the writer: "idle", or "half" between the two parts of a write
    done,       \* the writes that started
    rpc,        \* of each boid: "idle", or "half" between the two parts of a read
    got,        \* of each boid: what it read in the first part of its read
    kept        \* of each boid: the number and the row that it keeps

vars == <<row, changes, wpc, done, rpc, got, kept>>

Init ==
    /\ row = 0
    /\ changes = 0
    /\ wpc = "idle"
    /\ done = 0
    /\ rpc = [b \in Boids |-> "idle"]
    /\ got = [b \in Boids |-> 0]
    /\ kept = [b \in Boids |-> [count |-> 0, row |-> 0]]

\* The first part of a write. In the library: the row (ets:insert/2).
Change ==
    /\ wpc = "idle" /\ done < Writes
    /\ row' = IF RowFirst THEN done + 1 ELSE row
    /\ changes' = IF RowFirst THEN changes ELSE changes + 1
    /\ wpc' = "half"
    /\ done' = done + 1
    /\ UNCHANGED <<rpc, got, kept>>

\* The second part of a write. In the library: the number of the changes
\* (atomics:add/3).
Close ==
    /\ wpc = "half"
    /\ row' = IF RowFirst THEN row ELSE done
    /\ changes' = IF RowFirst THEN changes + 1 ELSE changes
    /\ wpc' = "idle"
    /\ UNCHANGED <<done, rpc, got, kept>>

\* A step of a boid whose number is not the number of the space: the
\* first part of its read. In the library: the number (atomics:get/2). A
\* boid with the number of the space uses what it kept, and reads no row.
Look(b) ==
    /\ rpc[b] = "idle" /\ kept[b].count /= changes
    /\ got' = [got EXCEPT ![b] = IF CountFirst THEN changes ELSE row]
    /\ rpc' = [rpc EXCEPT ![b] = "half"]
    /\ UNCHANGED <<row, changes, wpc, done, kept>>

\* The second part of the read. In the library: the row (ets:lookup/2).
Keep(b) ==
    /\ rpc[b] = "half"
    /\ kept' = [kept EXCEPT ![b] = IF CountFirst
                                   THEN [count |-> got[b], row |-> row]
                                   ELSE [count |-> changes, row |-> got[b]]]
    /\ rpc' = [rpc EXCEPT ![b] = "idle"]
    /\ UNCHANGED <<row, changes, wpc, done, got>>

\* The writes are done, and each boid has the number of the space.
Over ==
    /\ wpc = "idle" /\ done = Writes
    /\ \A b \in Boids : rpc[b] = "idle" /\ kept[b].count = changes
    /\ UNCHANGED vars

Next ==
    \/ Change
    \/ Close
    \/ \E b \in Boids : Look(b) \/ Keep(b)
    \/ Over

Spec == Init /\ [][Next]_vars /\ WF_vars(Next)

\* --- Invariants --------------------------------------------------------

\* When no write runs, a boid that uses what it kept has the row of the
\* table.
Fresh ==
    wpc = "idle" =>
        \A b \in Boids : (rpc[b] = "idle" /\ kept[b].count = changes) => kept[b].row = row

\* --- Liveness ----------------------------------------------------------

\* After the last write, each boid comes to keep the last row.
Settles == <>[](\A b \in Boids : kept[b].row = row)
====
