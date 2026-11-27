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
| `specs/Space.tla` | A write of a row against a read of the grid. | `boids_space:put/2`, `boids_space:near/3` |
| `specs/Step.tla` | One step of all the boids in two parts. | `boids:step/2`, `gen_boid` |
| `specs/Move.tla` | The move of a boid to another node of its world. | `gen_boid` (`settle`, `adopt/2`), `boids_world` (the join of a boid that comes, `moved/3`) |

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
that can fail, and a node can stop at each moment.

The constants: the two nodes (`Nodes`), the times that a process crosses
the border (`Crossings`), the calls and the answers that can be lost
(`Losses`), the nodes that can stop (`Stops`), and two guards for the
fault models. The model has one boid.

Each process has an age: the number of moves of the boid before it. A
node that has a process for the boid keeps it only when it is not older
than the process that calls.

| Action | When it can occur | In the code |
|---|---|---|
| `Cross(n)` | The process of `n` is in a tile of its node: its boid goes across the border. | A step of the boid |
| `Show(n)` | The process of `n` runs: the other node gets a row of the boid. | `boids_world:settle/2`, the message `{show, Entry}` |
| `Expire(n)` | `n` has a row of a boid of the other node: the row goes. | The sweep of `boids_world` |
| `Call(n)` | The process of `n` is in a tile of the other node: it calls that node, with its age plus 1. | `erpc:call(Home, gen_boid, adopt, ...)` |
| `Adopt(n)` | The call of `n` comes to the other node. With no process, or with an older process, that node starts a process for the boid, which takes the row: `ok`. If not: `exists`. | `gen_boid:adopt/2`, the join in `boids_world` |
| `LoseCall(n)`, `LoseAnswer(n)` | The call or its answer does not come. | A time limit, or the end of a connection |
| `Moved(n)` | The answer is `ok` or `exists`: `n` removes its row. | `boids_world:moved/3` |
| `Stay(n)` | No answer: the process stays, and calls again at its next step. | |
| `Stop(n)` | The process whose boid moved stops. | The reason `{shutdown, {moved, Node}}` |
| `Down(n)` | The node `n` stops, with its process and its rows. Its tiles go to the other node. | |

| Invariant or property | What it says | The fault that it stops |
|---|---|---|
| `RowOwner` | A node has its own row of the boid when it has a process of the boid, and only then. | A row with no process, and a process with no row. |
| `NotLost` | While the two nodes run, the boid has a process. | Two processes that stop for each other. |
| `OneProcess` | With no lost answer: after each move, the boid has a process on one node. | Two boids from one boid. |
| `Lands` | Each move ends. | A process that calls a node without end. |

The small model (`specs/MCMove.tla`): `MCMove.cfg` has no lost answer,
six crossings and a node that can stop. `MCMoveLost.cfg` also loses
three calls or answers: `RowOwner`, `NotLost` and `Lands` hold.

- `MCMoveOlder.cfg` lets a node always keep its process: `NotLost`
  violated. This was the first design of the move. After a lost answer,
  the world has an old process and a new process for the boid. When the
  new process comes back to the first node at that moment, each of the
  two processes gets `exists`, and the two stop. The age of a process
  stops that: the old process loses its row to the new process.
- `MCMoveStays.cfg` lets a process stay when the other node has the
  boid: `Lands` violated.
- `MCMoveTwo.cfg` is not a fault model. It shows a limit of the move:
  with a lost answer, `OneProcess` is violated. The old process can go
  back into a tile of its node before it calls again, or its call can
  come late to a node that the new process left. Then the world has two
  boids with one id, until one of them comes to the node of the other.

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

- A model is small: three processes, two boids, two cells, two nodes. A
  fault that needs more is not found.
- `Space.tla`, `Step.tla` and `Move.tla` have no replay. Their tie to
  the code is the comments in `boids_space`, `gen_boid` and
  `boids_world`, and the tests of the behavior
  (`test/boids_space_test.exs`, `test/boids_test.exs`,
  `test/boids_nodes_test.exs`).
- `Move.tla` has two nodes and one call of a node on its way at one
  time. It does not have the relations of a boid, which move with it.
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

## How to run the checks

```sh
mix deps.get
mix test test/boids_spec_test.exs test/boids_members_spec_test.exs
```

A change of `boids_world`, of `boids_space:put/2` and `near/3`, of the
two parts of `boids:step/2`, or of the move of a boid to another node
changes its specification in the same commit, and the tests of the
models and the replay must pass.
