# The specifications of boids

The boids of a world are processes. They act at the same time,
and the order of their acts changes from run to run. A test sees one
order of the acts. A specification sees all of them.

This document tells what the library specifies in TLA+, what the checks
prove, what they do not prove, and how to run them. The checker is the
native TLA+ checker of [Accord](https://github.com/sntran/accord) (the
branch `feat/native-tla-checker`), in Elixir: the checks need no Java,
and they run with the tests.

## The chain of the checks

| Check | What it reads | What it proves | Where |
|---|---|---|---|
| 1. The model checks | Each specification of `specs/`, a small model | In each possible order of the acts, the invariants hold, and the liveness property holds. | `test/boids_spec_test.exs` |
| 2. The fault models | The same specifications, with one rule removed | The checker finds the fault. A check that cannot fail proves nothing. | the same tests |
| 3. The replay | The messages that the process of a real world handles, with its answers | The code does only what `specs/Members.tla` permits: each message is one step of the specification, each answer is the answer of the specification, and the table at the end is the table of the specification. | `test/support/members_spec.ex`, `test/boids_members_spec_test.exs` |

The checks 1 and 2 prove the design. The check 3 ties the code of the
world to the design.

## The specifications

| Specification | The flow | The code |
|---|---|---|
| `specs/Members.tla` | The members of a world: a process asks for the row of an id, the world watches it, and the row goes when the process stops, leaves, or is removed. | `boids_world`, `boids:add/2`, `boids:remove/2`, `boids:join/2`, `boids:leave/2` |
| `specs/Space.tla` | A write of a row against a read of the grid, and a write of an obstacle against a read of the obstacles near a boid. | `boids_space:put/2`, `boids_space:near/3`, `boids_world:set/3`, `boids_space:set_obstacle/4`, `boids_space:obstacles/3` |
| `specs/Kept.tla` | A write of a grid or of a field against the boids that keep what they read. | `boids_world:set/3`, `boids_space:set_grid/3`, `boids_space:set_field/3`, `boids_space:named/3` |
| `specs/Step.tla` | One step of all the boids in two parts. | `boids:step/2`, `gen_boid` |
| `specs/Move.tla` | The move of a boid to another node of its world. | `gen_boid` (`settle`, `adopt/2`), `boids_world` (the join of a boid that comes, `moved/3`) |
| `specs/MoveMany.tla` | The same move in a world on three nodes: a boid with a process on each node, and a decision for two processes at a time. | `boids_world` (`adopt/5`, the messages `census`, `claim` and `yield`) |
| `specs/Facts.tla` | The facts of a world (the obstacles, the scale of the time, the grids, the fields) on several nodes: a change with a version, a node that comes later, and a split of the network. | `boids_world` (`set/3`, the messages `fact` and `facts`, `drop_marks/2`) |

### `specs/Members.tla`

The constants: the ids (`Ids`), the processes (`Procs`, each starts one
time), and two guards for the fault models. The world handles one
message at a time. The messages of two processes come in each order.

| Action | When it can occur | In the code |
|---|---|---|
| `Start(p, i)` | `p` is new: it asks the world for the row of `i`. | The start of a `gen_boid`, or `boids:join/2` in another process, also one that its supervisor starts again |
| `Stop(p)` | `p` runs: an error, a kill, or the end of its work. The world gets `'DOWN'` when it watches `p`. | |
| `Find(p)` | `p` has the row of its id: a caller reads the table. | the start of `boids:remove/2` |
| `Remove(p)` | A caller found `p`: it stops `p`, then sends a leave. | the end of `boids:remove/2` |
| `Quit(p)` | `p` runs with its row: it sends a leave. | `boids:leave/2` |
| `Join(p)` | The world handles the join of `p`. It first forgets the row of a process that stopped. A free id gives the row, and the world watches `p`. | `{join, Pid, Entry}` |
| `Down(p)` | The world handles the `'DOWN'` of `p`: its row goes. | `{'DOWN', Ref, process, Pid, Reason}` |
| `Leave(p)` | The world handles a leave for `p`: the row of its id goes only when `p` has it. | `{leave, Id, Pid}` |

| Invariant or property | What it says | The fault that it stops |
|---|---|---|
| `LiveHasRow` | A process that runs as a boid has the row of its id. | A boid that moves, but that no boid sees and no caller finds. |
| `Watched` | The world watches each process that has a row, and no other process. | A row that stays after the end of its process. |
| `NoLostRow` | When the world handled each message, each row has a process that runs. | A boid that does not move in the world. |
| `Fair` | The world refuses an id only when its process did not stop. | A process of yours that cannot be a boid again after an error. |
| `Cleans` | In the end, each row has a process that runs. | |

The small model (`specs/MCMembers.tla`): three processes for one id (a
boid, the process that starts again with its id, and one more).
`MCMembersTwo.cfg` has two ids and two processes. `MCMembersKeep.cfg` keeps
the row of a process that stopped until its `'DOWN'`: the checker must
find `Fair` violated, because the join of the new process can come
before that `'DOWN'`. `MCMembersLeave.cfg` lets a leave remove the row of
each process: the checker must find `LiveHasRow` violated.

The fault of `MCMembersLeave.cfg` was in the code. `boids:remove/2` stops
the process of a boid, then sends a leave for its id. When another
caller adds a boid with the same id between the two, the leave removed
the row of the new boid. The leave now has the process of the caller,
and the world checks it (`CheckOwner`).

### `specs/Space.tla`

The constants: the boids (`Boids`), the cells (`Cells`), the writes of
each boid (`Writes`, a bound of the model), and two guards for the fault
models. The grid has a copy of each row in the cell of its position.

| Action | When it can occur | In the code |
|---|---|---|
| `Write(b, c)` | `b` does not write: it writes its row, with a position in the cell `c`. | `ets:insert/2` of the row in `put/2` |
| `Insert(b)` | The row is written: the new copy goes into the grid. | `ets:insert/2` of the copy |
| `Delete(b)` | The new copy is in the grid: the old copy goes. | `ets:delete_object/2` |
| `Kill(b)` | The process of `b` runs: it stops, also in the middle of a write. | |
| `Remove(b)` | The process of `b` stopped: the world removes its row, the copy of the row, and the copy before its last write. | `remove/2` |
| `Begin` | A read starts, one time. | `near/3` |
| `Read(c)` | The reader reads all the copies of the cell `c`. | one `ets:lookup/2` |
| `End` | Each cell is read: the reader keeps one copy of each boid. | `lists:ukeysort/2` |

| Invariant or property | What it says | The fault that it stops |
|---|---|---|
| `OneTime` | A boid is in the result of a read one time at most. | A neighbor that counts two times. |
| `Finds` | A boid that runs, and that did not change its cell during the read, is in the result. | A neighbor that a boid does not see, and hits. |
| `Whole` | When a boid that runs does not write, the grid has one copy of its row, in the cell of the row. | An old copy that stays: a boid at two places. |
| `Gone` | The grid has no copy of a boid whose row the world removed. | A boid that is not in the world, but that the other boids see and move away from. |
| `Reads` | The read ends. | |

A boid that changes its cell during the read can be absent from the
result: the reader read its new cell before the boid came, and its old
cell after the boid went. The specification says this (`moved`), and so
does the documentation of `near/3`.

The small model (`specs/MCSpace.tla`): two cells, and two boids that
write one time each. `MCSpaceLong.cfg` has one boid that writes three
times during one read. `MCSpaceGap.cfg` removes the old copy before it
adds the new copy: `Finds` violated. `MCSpaceTwice.cfg` keeps each copy
that the reader read: `OneTime` violated. `MCSpaceLeak.cfg` removes only
the copy of the row at the end of a boid: `Gone` violated.

Two of these faults were in the code. The first version of `put/2` had
the order of `MCSpaceGap.cfg`. The first version of `remove/2` was
`MCSpaceLeak.cfg`: a review found copies in the grid after the kill of
boids that wrote at that moment. The row now keeps the copy before its
last write, and `remove/2` removes the two copies.

#### The obstacles

The second part of `Space.tla` has the obstacles. The constants: the
obstacles (`Obstacles`), the processes that write them (`Writers`), the
writes of each writer (`Moves`, a bound of the model), and a guard for a
fault model. Each obstacle has a row, and an index has the cell of each
obstacle (in the code, each cell that it touches). In the models of the
boids, there is no obstacle, and in the models of the obstacles, no
boid.

Only the owner of the space writes the obstacles. In a world, the owner
is the process of the world, and each change is a message to it
(`boids_world:set/3`). So the library has one writer, and its writes
come one after the other. The tables of the obstacles are protected:
another process cannot write them. When the process of the world stops,
its tables go with it, so no write stays in its middle. The scale of
the time has the same writer. It is one row, so it needs no
specification: a read sees it before or after a write.

| Action | When it can occur | In the code |
|---|---|---|
| `Get(w, o, c)` | The writer does not write: it gets a change, the obstacle `o` moves to the cell `c`. | the next message `{set, {obstacle, Id}, Value}` of the process of the world |
| `Open(w)` | A new version, and the read of the row. | `ets:update_counter/3`, `ets:lookup/2` |
| `AddCell(w)` | The new cell goes into the index. | `ets:insert/2` |
| `MoveRow(w)` | The row changes. | `ets:insert/2` |
| `DropCell(w)` | The old cell goes from the index. | `ets:delete_object/2` |
| `Close(w)` | A new version. | `ets:update_counter/3` |
| `Look` | A read starts. With a write that runs, it reads all the rows. | `obstacles/3`: the version is odd |
| `LookAt(c)` | The reader reads the obstacles of the cell `c`. | one `ets:lookup/2` |
| `Check` | Each cell is read. With a new version, the reader reads all the rows. | the second read of the version |
| `LookAll` | The reader reads all the rows: each obstacle one time. | `ets:match_object/2` |

| Invariant or property | What it says | The fault that it stops |
|---|---|---|
| `Exact` | A read finds each obstacle one time, also an obstacle that moves during the read. | A boid that does not see a rock that moves, and goes into it. |
| `Indexed` | At each moment, the index has the cell of the row of each obstacle. | An obstacle that no boid sees again. |
| `Clean` | When no write runs, the index has only the cells of the rows. | An index that grows with each move. |
| `ReadsObstacles` | The read ends. | |

The small models: `MCSpaceObstacles.cfg` has two obstacles, and one
writer that moves them two times in all. `MCSpaceObstaclesLong.cfg` has
one writer that moves an obstacle three times during one read.
`MCSpaceTwoWriters.cfg` has two writers: `Indexed` violated (two writes
of one obstacle at the same time remove the cell of the row). That is
why only one process writes the obstacles. `MCSpaceNoCheck.cfg` has a
reader that does not check the version: `Exact` violated (the reader
reads the new cell before the obstacle comes, and the old cell after it
goes).

### `specs/Kept.tla`

A grid of a world is one row of the table of the facts: a large binary.
So is a field of directions (`boids_field`). The two have the same
write and the same read, so one specification has the two.
A process that reads such a row from the table at each step gets a new
reference to the binary at each step, and its garbage collection then
runs at each step. So a boid keeps what it read. The space has the
number of the changes of these rows (an `atomics`). At each step, a
boid reads the number, and it reads the rows again only when the number
changed.

The owner of the space is the only writer, as for the obstacles: in a
world, the process of the world of the node. It writes a change of a
caller of its node, and a change that comes from another node
(`Facts.tla`), with the same function (`write/3` of `boids_world`), one
after the other. So the number of the changes also gets 1 more for a
grid or a field that comes from another node, and the boids of this
node read it at their next step. The model is about one node: each
node has its own row and its own number.

The constants: the boids (`Boids`), the writes of the owner (`Writes`, a
bound of the model), and two guards for the fault models.

| Action | When it can occur | In the code |
|---|---|---|
| `Change` | No write runs: the row changes. | `ets:insert/2` or `ets:delete/2` in `set_grid/3`, `remove_grid/2`, `set_field/3` and `remove_field/2`, for a change of this node (`set/3`) and for a fact of another node (`learn/2`) |
| `Close` | The row changed: the number of the changes gets 1 more. | `atomics:add/3` |
| `Look(b)` | The number that `b` keeps is not the number of the space: `b` reads the number. | `atomics:get/2` in `named/3` |
| `Keep(b)` | `b` read the number: it reads the row, and keeps the two. | `ets:lookup/2` |

A boid whose number is the number of the space uses what it kept, and
reads no row: that is no action of the model.

| Invariant or property | What it says | The fault that it stops |
|---|---|---|
| `Fresh` | When no write runs, a boid that uses what it kept has the row of the table. | A boid that goes through a door that closed, for all the time. |
| `Settles` | After the last write, each boid comes to keep the last row. | |

A step of a boid during a write can use the row before the write or the
row after it. The model permits the two.

The small model (`specs/MCKept.tla`): three boids, and three writes.
`MCKeptEarly.cfg` changes the number before the row: `Fresh` violated (a
boid reads the new number and the old row, and the row then changes).
`MCKeptLate.cfg` reads the row before the number: `Fresh` violated (the
row and the number change between the two reads). In the two fault
models, the boid has the number of the space, so it does not read the
row again.

### `specs/Step.tla`

The constants: the boids (`Boids`), the boids that also move on their
own clock (`Clocks`), the steps of the caller (`Steps`, a bound of the
model), and a guard for a fault model. The position of a boid is a
number: a boid that reads the positions `s` goes to `See(s)`.

| Action | When it can occur | In the code |
|---|---|---|
| `Begin` | No step runs: the caller asks each boid for its plan. | `boids:step/2` |
| `Plan(b)` | `b` runs and did not answer: it calculates its new position, and does not move. | `{plan, Dt}`: sense (`handle_sense/2`), decide (`handle_decide/2`), then the forces |
| `Turn` | Each boid that runs answered: the caller asks each boid to move. | |
| `Commit(b)` | `b` runs and did not answer: it moves to the position of its plan. | `commit`: act (`handle_act/1`), then the write of the row |
| `End` | Each boid that runs moved. | |
| `Tick(b)` | `b` has a clock: it moves at its tick. | `tick` |
| `Stop(b)` | The process of `b` stops, at each moment. | |

| Invariant or property | What it says | The fault that it stops |
|---|---|---|
| `Quiet` | While the boids calculate, no boid moves. | A result that changes with the order of the processes. |
| `OneMoment` | After a step, each boid is where a boid that read the world at the start of the step goes. A boid whose process stopped before it moved is where it was. | The same. |
| `Ends` | Each step ends, also when processes stop during the step. | A caller that waits for a process that stopped. |

The small model (`specs/MCStep.tla`): three boids and two steps.
`MCStepOnePart.cfg` lets a boid move when it calculates: `Quiet`
violated. `MCStepClock.cfg` gives a clock to one boid: `Quiet` violated.
Thus a run gives the same result each time only when each boid has
`tick => manual`.

### `specs/Move.tla`

A world with a name is on several nodes, and each tile of the world is
on one node. The process of a boid is on the node of its tile. A boid
that goes into a tile of another node moves: a new process starts on
that node, and the first process stops. The two nodes talk with a call
that has no time limit. The connection between the nodes can end at
each moment (a split), and it can come again (a heal). A node can stop
at each moment.

The constants: the two nodes (`Nodes`), the times that a process crosses
the border (`Crossings`), the times that the connection can end
(`Splits`), the nodes that can stop (`Stops`), and three guards for the
fault models. The model has one boid.

Each process has an age: the number of moves of the boid before it. A
node that has a process for the boid keeps it only when it is not older
than the process that calls.

After a split, the boid can have a process on each node. After the
heal, the world of the first node (the node with the smaller name)
decides which process stays: the one with more moves, then the one of
the second node. It stops its own process, or it tells the second node
to stop the process of the age that it saw. The decision does not use
the tile of a process: `specs/MoveMany.tla` shows why.

| Action | When it can occur | In the code |
|---|---|---|
| `Cross(n)` | The process of `n` is in a tile of its node, and the nodes have a connection: its boid goes across the border. | A step of the boid |
| `Show(n)` | The process of `n` runs: the other node gets a row of the boid. | `boids_world:settle/3`, the message `{show, Entry}` |
| `Expire(n)` | `n` has a row of a boid of the other node: the row goes. | The sweep of `boids_world` |
| `Call(n)` | The process of `n` is in a tile of the other node: it calls that node, with its age plus 1. | `erpc:call(Home, gen_boid, adopt, ..., infinity)` |
| `Adopt(n)` | The call of `n` comes to the other node. With no process, or with an older process, that node starts a process for the boid, which takes the row: `ok`. If not: `exists`. | `gen_boid:adopt/2`, the join in `boids_world` |
| `Split`, `Heal` | The connection between the nodes ends, or comes again. Without a connection, each node has all the tiles. | The end of a connection of Erlang, and the `join` of `pg` |
| `LoseCall(n)`, `LoseAnswer(n)`, `LoseYield(n)` | A call, an answer or a decision that was on its way at a split does not come. | `erpc` gives an error to the process that calls |
| `Moved(n)` | The answer is `ok` or `exists`: `n` removes its row. | `boids_world:moved/3` |
| `Stay(n)` | No answer: the process stays, and calls again at its next step. | |
| `Stop(n)` | The process whose boid moved stops. | The reason `{shutdown, {moved, Node}}` |
| `Judge` | Each node has a process for the boid, and the nodes have a connection: the world of the first node stops its own process, or sends the decision to the second node. | `claim` in `boids_world`, after the messages `{census, ...}`, `{claim, ...}` and `{show, Entry}` |
| `Yield(n)` | The decision comes to the node `n`: it stops its process when that process has the age of the decision. | The message `{yield, Id, Moves}` |
| `Down(n)` | The node `n` stops, with its process and its rows. Its tiles go to the other node. | |

| Invariant or property | What it says | The fault that it stops |
|---|---|---|
| `RowOwner` | A node has its own row of the boid when it has a process of the boid, and only then. | A row with no process, and a process with no row. |
| `NotLost` | While the two nodes run, the boid has a process. | Two processes that stop for each other, and a decision that stops the only process. |
| `OneProcess` | With no split: after each move, the boid has a process on one node. | Two boids from one boid. |
| `Lands` | Each move ends, and then the nodes have a connection and the boid has one process. | A process that calls a node without end, and two processes that stay after a heal. |

The small model (`specs/MCMove.tla`): `MCMove.cfg` has no split, six
crossings and a node that can stop. `MCMoveSplit.cfg` has two splits
and five crossings: `RowOwner`, `NotLost` and `Lands` hold. Thus the
boid keeps a process in each order of the acts, and it has one process
after the last heal.

- `MCMoveOlder.cfg` lets a node always keep its process: `NotLost`
  violated. This was the first design of the move. After a split, the
  world has an old process and a new process for the boid. When the
  new process comes back to the first node at that moment, each of the
  two processes gets `exists`, and the two stop. The age of a process
  stops that: the old process loses its row to the new process.
- `MCMoveStays.cfg` lets a process stay when the other node has the
  boid: `Lands` violated.
- `MCMoveAny.cfg` lets a node stop its process of each age when the
  decision comes: `NotLost` violated. The process that lost the
  decision can go before the decision comes, and a new process of the
  boid can come to that node. The decision then stops the new process,
  which is the only one. The age in the decision stops that.
- `MCMoveTwo.cfg` is not a fault model. It shows a limit of the move:
  with a split, `OneProcess` is violated. During the split, the world
  has two boids with one id.

### `specs/MoveMany.tla`

`Move.tla` has two nodes. With three nodes, a boid can have a process
on each node, and the code decides for two processes at a time: each
pair of nodes has its own decision. `MoveMany.tla` is the move for a
set of nodes. It has less detail of one move than `Move.tla` (no row,
and no node that stops), and each message is on its way in a set, so
the messages come in each order.

The constants: the nodes (`Nodes`, numbers in the order of their
names), the times that a process goes into a tile of another node
(`Crossings`), the splits (`Splits`), a bound for the splits (`Apart`),
and three guards for the fault models. The model has one boid.

| Action | When it can occur | In the code |
|---|---|---|
| `Cross(n, m)` | The process of `n` is in a tile of its node, and the two nodes have a connection: its boid goes into a tile of `m`. | A step of the boid |
| `Call(n)` | The process of `n` is in a tile of another node: it calls that node, with its age plus 1. | `erpc:call(Home, gen_boid, adopt, ..., infinity)` |
| `Adopt(c)` | The call comes. With no process, or with an older process, the node starts a process and sends a claim with the call to all the other nodes. | `gen_boid:adopt/2`, `boids_world:adopt/5`, the message `{claim, Id, Node, Moves, Caller}` |
| `Answer(a)` | The answer comes to the process that waits for it: that process stops. An answer for a process that is gone does nothing. | `boids_world:moved/3`, the reason `{shutdown, {moved, Node}}` |
| `LoseCall(c)`, `LoseAnswer(a)` | A split cut the two nodes: the call or the answer does not come, and the process that called stays. | `erpc` gives an error to the process that calls |
| `Claim(cl)` | A node gets the claim of another node. The node whose process waits for the answer of the call of the claim does nothing. The node with the smaller number decides. The node with the larger number sends its own claim to the other node. | `claim` in `boids_world`, after the messages `{census, ...}`, `{claim, ...}` and `{show, Entry}` |
| `Yield(y)` | The decision comes: the node stops its process when that process has the age of the decision. | The message `{yield, Id, Moves}` |
| `Split` | One node loses its connections to all the other nodes, or (with `Apart`) all the connections end. The claims and the decisions between the nodes that it cuts are lost. | The end of a connection of Erlang |
| `Heal` | All the connections come again. Each node of a pair that had no connection sends a claim for its process to the other. | The `join` of `pg`, the message `{census, Node, Claims}` |

| Invariant or property | What it says | The fault that it stops |
|---|---|---|
| `NotLost` | The boid has a process. | Two decisions for the same two processes that stop the two, and a decision that stops the only process. |
| `Settled` | When all the nodes have a connection, no process is in a tile of another node, and no message is on its way, the boid has one process. | Two processes that stay with nothing more to do. |
| `Lands` | In the end, all the nodes have a connection, nothing is on its way, and the boid has one process. | A flow of messages that does not end. |

The small model (`specs/MCMoveThree.tla`) has three nodes and one boid:

| Model | The bounds | The checks | The result |
|---|---|---|---|
| `MCMoveThree.cfg` | 3 crossings, 1 split that cuts one node from the two others | `NotLost`, `Settled` | They hold: 518,063 states, about 50 seconds. |
| `MCMoveThreeSplits.cfg` | 2 crossings, 2 splits, each of one node or of all the nodes | `NotLost`, `Settled`, `Lands` | They hold: 21,594 states, about 6 seconds. |

The model found two faults of the code, which two nodes cannot show.
The code and the specification changed together, and each fault stays
as a fault model:

- `MCMoveThreeTiles.cfg` lets a decision also use the tile of each
  process, as the code did: with the same number of moves, the process
  in a tile of its node stayed. `NotLost` is violated. On two nodes,
  two processes never have the same number of moves: the processes of
  one node have an even number, and those of the other node an odd
  number. On three nodes they can. The boid moves from the node 1 to
  the node 2, and a split loses the answer. After the heal, the process
  of the node 1 moves to the node 3: the processes of the node 2 and of
  the node 3 each made one move. Two claims for the process of the node
  3 are on their way to the node 2: one from before that process went
  into a tile of another node, and one from after. The node 2 decides
  two times, with opposite results: it tells the node 3 to stop its
  process, and then it stops its own process. The boid has no process.
  The decision now uses only what does not change: the moves of a
  process, then its node.
- `MCMoveThreeAlone.cfg` lets a node start a process and tell no other
  node, as the code did. `Settled` is violated. A boid moves from the
  node 1 to the node 2, and a split loses the answer: the node 1 keeps
  its process. Then the boid moves from the node 2 to the node 3. The
  node 1 and the node 3 always had their connection, so no heal makes
  them compare their boids, and the two processes stay. A node that
  starts a process now sends a claim to all the other nodes.
- `MCMoveThreeAny.cfg` lets a node stop its process of each age when
  the decision comes: `NotLost` violated, as in `MCMoveAny.cfg`.

The claim of a new process has the call that started it. A first
design sent that claim to all the nodes but the node of the call, and
the model found a fault there too: the call of a process that is gone
can start a process that no node compares. With the call in the claim,
only the node whose process waits for that call does nothing.

### `specs/Facts.tla`

The facts of a world are what all its boids perceive, and that is not a
boid: the obstacles, the scale of the time, the grids and the fields of
directions. Each node of a world has a copy of each fact, and all the
nodes must have the same facts. The model has no part for one kind of
fact, as the code: a grid or a field is a fact as an obstacle is.

The constants: the nodes (`Nodes`, numbers in the order of their
names), the keys of the facts (`Keys`), the changes of the users and
the splits of the network (`Changes` and `Splits`, bounds of the
model), the steps of a counter (`Steps`), and three guards for the
fault models. The fact of a key on a node is a version (a counter and a
node), a value ("set", or "none" for a fact that was removed), and the
number of its change. A message is a fact on its way from a node to a
node. The messages have no order: a node can get them in each order.

The counter of a change is a clock of two parts. In the code, it is the
time of the system in microseconds (`erlang:system_time/1`), or the
largest counter that the node knows plus 1 when that is more. So a
counter of a node is always larger than each counter that the node
knows, and that is all that the model needs: it has no time. In the
model, the counter of a change is larger than the largest counter that
its node knows by one of the `Steps`: 1, or 2 for a clock that is
ahead. The invariants hold for each step, so they hold for each clock
of each computer. The time decides only which change is the last one.

The unit of the time is the microsecond, because one change takes more
than a microsecond (3 to 7 microseconds in a measurement). Thus the
changes of a node do not put its counter ahead of its clock: after
100,000 changes with no pause, the counter was 1 to 3 microseconds
behind the time of the system. With milliseconds, each change in the
same millisecond adds 1 to the counter: 10,000 changes with no pause
put the counter 10 seconds ahead, and a later change of another node
then loses against them after a split.

| Action | When it can occur | In the code |
|---|---|---|
| `Change(n, k, v, d)` | A user changes the fact of the key `k` on the node `n`. The counter of the version is the largest counter that `n` knows, plus the step `d`. The world of `n` sends the fact to its peers. | the call `{set, Key, Value, Ack}` in `boids_world` |
| `Learn(x)` | A fact comes to its node. The node takes it only when its version is larger than the version that the node has: the counter first, then the node. | `learn/2`, for the messages `{fact, Fact, Ack}`, `{facts, Facts}` and `{facts, Facts, Ack}`, and for the call `{merge, Facts, Ack}` |
| `Split(n, m)` | The connection between two nodes ends. The messages between them are lost, and each of the two has one peer less. | the event `leave` of `pg` |
| `Heal(n, m)` | The two nodes have a connection again. | |
| `Join(n, m)` | The node `n` sees the node `m`: it sends all its facts and its marks to `m`, and `m` is one of its peers. | the event `join` of `pg` |
| `Drop(n, k)` | The node `n` drops the mark of the key `k`. Each node took that mark or has a newer fact, and no older fact of the key is on its way. | `drop_marks/2`, after `boids:mark_time/0` |

| Invariant or property | What it says | The fault that it stops |
|---|---|---|
| `Same` | When all the nodes have a connection, each node knows each other node, and no fact is on its way, the boids of all the nodes perceive the same facts. | A rock that is a rock on one node only. A world that stops on one node and runs on another node. |
| `NoReturn` | A fact of a node is after each removal of its key that the node took: an older change never brings back a fact that was removed. | An obstacle that a game removed, and that is there again after a split. |
| `Counts` | The counter of a node is not less than the counter of each fact that it has. | A new change that loses against an older fact of its own node. |
| `Settles` | The world comes to rest: all the nodes have a connection, and no fact is on its way. | |

The small models (`specs/MCFacts.tla`): `MCFacts.cfg` has two nodes, one
key, three changes and two splits, and the steps 1 and 2.
`MCFactsThree.cfg` has three nodes, two changes and one split.
`MCFactsKeys.cfg` has two keys, which share the counter of a node.
`MCFactsCounter.cfg` compares only the counters of two versions: `Same`
violated (two nodes change one fact at the same time, the two changes
have the same counter, and each node keeps its own). `MCFactsClock.cfg`
has the step 0: the counter of a change is only the time, and the clock
stands still (or goes back). `Same` violated: two changes of one node
have one version, and the other node keeps the first one. That is why
the counter is not the time alone. `MCFactsNoMark.cfg` keeps no mark
for a fact that was removed: `NoReturn` violated (a node removes a
fact, and an older change of the other node, which was on its way or
comes after a split, makes the fact again).

The condition of `Drop` is the place of the time of a mark in the
model. In the code, a node drops a mark when it is older than
`boids:mark_time/0` (10 minutes by default, or never with `infinity`).
The model has what that time must give: each
node took the mark, and no older fact is on its way. That is true when
the time of a mark is longer than each split of the network and than
the time of each message. `MCFactsEarly.cfg` drops a mark at each
moment: `NoReturn` violated. This is a limit of the library, not a
fault of the code: a node that has no connection for longer than the
time of a mark can bring back a fact that the other nodes removed in
that time.

The process that asks for a change waits for the answers of the other
nodes (`boids_world:set/3`). The model does not have this wait: it
changes nothing in the facts. No world waits for another world.

A world can get facts with their versions from a save
(`boids_world:merge/2`, which `boids:import/2` uses). The model has no
action for this, because it is not a new flow. For the nodes, the facts
of a save are facts that were on their way for a long time. The node
that gets them takes each of them with `Learn`, and sends them to its
peers, as a node that comes to the world does (`Join`). So `Same` holds
for them as for each other fact. `NoReturn` has the limit of
`MCFactsEarly.cfg`: a save that is older than the time of a mark can
bring back a fact that the world removed, because the world dropped the
mark of that removal.

### The save and the load of a world have no specification

`boids:export/1` and `boids:import/2` make no new flow. Each part of
them is a part of a flow that has a specification, or it has one writer
only.

- An export is a read. Each boid answers the request of the export
  between two of its steps, as it answers `boids:boid/2`: its process
  handles one message at a time. The export writes nothing. As
  `boids:snapshot/1`, it is not of one moment in a world with a clock.
- A boid of a save starts as a new boid. Its process joins the world
  with the action `Join` of `Members.tla`, which refuses an id that is
  in the world. The boid made no move from node to node, as a boid of
  `boids:add/2`: `Move.tla` and `MoveMany.tla` have nothing new. The
  relations come after the boids, with `boids:relate/4`.
- The facts of a save are facts with versions: see `Facts.tla` above.
- The order of `boids:snapshot/1` is a number in the row of a boid. Only
  the process of the world gives the number, in the join of the boid.
  The process of the boid copies it at each write of its row. The
  number is not in the copy of the row in the grid, so `Space.tla` does
  not change. A boid that moves to another node takes the number with
  it, as it takes its state: `Move.tla` does not have the state of a
  boid.

The result of a run with a save and a load is a behavior of the code,
not an order of processes: the tests check it
(`test/boids_save_test.exs`). 100 steps, a save, a load into a new
world and 100 steps give the same rows as 200 steps.

## The replay: the code against the specification

`Boids.MembersSpec` (`test/support/members_spec.ex`) does two things.

`trace/1` and `events/2` record the messages that the process of a real
world handles, with a trace session of Erlang on
`boids_world:handle_call/3` and `boids_world:handle_info/2`:
a join with its answer, a leave, and a `'DOWN'` with the id of its
monitor.

`replay/3` takes the events and the rows of the real table at the end,
and:

1. writes a module `Run.tla` that extends `Members` with the constants of
   the events: one process for each join, and the ids;
2. loads it in the machine of the checker
   (`Accord.TLA.Checker.Machine`);
3. takes each event as one action of the world (`Join`, `Leave`,
   `Down`), and checks the answer of each join against the row of the
   specification;
4. checks each invariant after each step;
5. checks that each row of the real table is a row of the specification,
   and that no other id has a row.

The world does not see the acts of the other processes (`Start`,
`Stop`, `Find`, `Remove`, `Quit`). The replay puts them where the events
need them. When two orders are possible, it follows each one: for a
join, the process of the row stopped, or not. The result is `:ok`,
`{:error, {:diverged, event}}` when no order explains an event, or
`{:error, {:violated, invariant, event}}`.

`test/boids_members_spec_test.exs` replays:

- a world with boids that start, stop, start again with their id,
  leave and go;
- boids that a test kills, each with a new boid of the same id at once:
  the join of the new process and the `'DOWN'` of the old process come
  in the two orders;
- 40 random lists of acts, where the processes of the test and of the
  world run at the same time (a property test);
- events that are not a behavior of the specification, which must
  diverge: the events of the two fault models, a wrong answer, a lost
  row, and a row that no join made.

## What the checks do not prove

- A model is small: three processes, two boids, two cells, three nodes.
  A fault that needs more is not found.
- `Space.tla`, `Kept.tla`, `Step.tla`, `Move.tla` and `Facts.tla` have
  no replay. Their tie to the code is the comments in `boids_space`,
  `gen_boid` and `boids_world`, and the tests of the behavior
  (`test/boids_space_test.exs`, `test/boids_test.exs`,
  `test/boids_nodes_test.exs`, `test/boids_facts_test.exs`).
- `Move.tla` has two nodes and one call of a node on its way at one
  time. `MoveMany.tla` has three nodes, one boid, three crossings and
  two splits at most, and no node that stops. A fault that needs four
  nodes, more crossings or more splits is not found. The two do not
  have the relations of a boid, which move with it.
- In `MoveMany.tla`, a split cuts one node from all the others, or all
  the nodes. That is what Erlang does by default: a node that loses one
  connection loses the others too. A network where a node has only a
  part of its connections for a long time is not in the model.
- In `Move.tla`, the world that decides sees the two processes at one
  moment. In the code, and in `MoveMany.tla`, it sees its own process
  now, and the other process as a message told it. The age in the
  decision keeps a decision that comes late from a process that it did
  not see.
- The ids of a world are for one boid each. The code cannot tell two
  boids with one id on two nodes from two processes of one boid, and it
  stops one of them. Only a boid that the world supervises is in these
  decisions: a boid below a supervisor of yours always stays.
- A boid that comes from another node, after more moves, takes the row
  of a process of its id that runs (`Move.tla`, `Adopt`). `Members.tla`
  does not have this: there, a process that runs keeps its row.
- The replay sees the process of one world on one node. It follows
  the orders that the tests make.
- The specifications say nothing about the forces of the rules, the
  time of a tick, or the speed.
- The relations between the boids (`boids:relate/4`) are not in
  `Members.tla`. The process of the world has their graph, and it
  removes the relations of a boid where the specification removes its
  row. The replay does not see the messages of the relations.
- A boid with the option `search` reads the rows of the neighbors that
  it knows, one row at a time. `Space.tla` is about the read of the
  grid. A read of one row sees the row before or after a write, and
  never a part of it.
- In `Space.tla`, an obstacle is in one cell. In the code, it is in each
  cell that it touches. The read of all the rows of the obstacles is one
  step of the model: the code uses a read of an ETS table of the kind
  `set`, which gets each row one time, also a row that a write changes
  during the read.
- `Facts.tla` has three nodes, two keys, three changes and two splits at
  most, and no node that stops. A node sends its changes only to the
  nodes that it has a connection to, and no node sends the fact of
  another node again, except when two nodes see each other (`Join`).
  Thus a node that stops before all the nodes have its last change, in
  a network where a node has only a part of its connections, can leave
  two nodes with different facts. Erlang does not keep such a network:
  a node that loses one connection loses the others too.
- `Facts.tla` has no time. It proves that all the nodes get the same
  facts for each clock of each computer. It does not say which change
  is the last one: that is the time of the system in the code. With
  clocks that agree, the last change in time wins. With a clock that is
  ahead, the change of that computer can win against a later change of
  another computer, when the two did not see each other (a split).
- A world that starts again has no fact, until it gets the facts of the
  other nodes. The counter of its changes is the time of its computer,
  so its changes are after the older facts of the other nodes when the
  clocks agree. When its clock is behind the counter of an older fact
  of another node, a change that it makes before it has that fact loses
  against it. The model has no node that starts again.
- In `Facts.tla`, a mark goes only when each node took it. In the code,
  a mark goes after a time (`boids:mark_time/0`): see the limit of
  `MCFactsEarly.cfg`.
- `Facts.tla` has no save. The facts of a save have the versions of
  another run of the world (`boids_world:merge/2`). They are facts as
  the others while each version is the version of one change only. A
  counter is the time of the system in microseconds, so two changes with
  one version need a node with the same name and a clock that went back
  to the same microsecond.
- In `Kept.tla`, the boids keep one row. In the code, a boid can keep
  more than one grid and more than one field: it reads the number of
  the changes one time, and then one row for each name. `Kept.tla` has
  one node. In a world on several nodes, each node has a space with its
  own number of changes, and one writer: the process of the world of
  that node, which makes the writes of its node and the writes of the
  facts that it gets from the other nodes (`Facts.tla`), one after the
  other.

## How to run the checks

```sh
mix deps.get
mix test test/boids_spec_test.exs test/boids_members_spec_test.exs
```

A change of `boids_world`, of `boids_space:put/2` and `near/3`, of the
writes and the reads of the obstacles, of the write and the kept read
of a grid, of the two parts of `boids:step/2`, of the facts of a world
on several nodes, or of the move of a boid to another node
changes its specification in the same commit, and the tests of the
models and the replay must pass.
