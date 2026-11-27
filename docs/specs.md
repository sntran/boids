# The specifications of boids

The boids of an environment are processes. They act at the same time,
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
| 3. The replay | The messages that the process of a real environment handles, with its answers | The code does only what `specs/Members.tla` permits: each message is one step of the specification, each answer is the answer of the specification, and the table at the end is the table of the specification. | `test/support/members_spec.ex`, `test/boids_members_spec_test.exs` |

The checks 1 and 2 prove the design. The check 3 ties the code of the
environment to the design.

## The specifications

| Specification | The flow | The code |
|---|---|---|
| `specs/Members.tla` | The members of an environment: a process asks for the row of an id, the environment watches it, and the row goes when the process stops, leaves, or is removed. | `boids_environment`, `boids:add/2`, `boids:remove/2`, `boids:join/2`, `boids:leave/2` |
| `specs/Space.tla` | A write of a row against a read of the grid. | `boids_space:put/2`, `boids_space:near/3` |
| `specs/Step.tla` | One step of all the boids in two parts. | `boids:step/2`, `gen_boid` |

### `specs/Members.tla`

The constants: the ids (`Ids`), the processes (`Procs`, each starts one
time), and two guards for the fault models. The environment handles one
message at a time. The messages of two processes come in each order.

| Action | When it can occur | In the code |
|---|---|---|
| `Start(p, i)` | `p` is new: it asks the environment for the row of `i`. | The start of a `gen_boid`, or `boids:join/2` in another process, also one that its supervisor starts again |
| `Stop(p)` | `p` runs: an error, a kill, or the end of its work. The environment gets `'DOWN'` when it watches `p`. | |
| `Find(p)` | `p` has the row of its id: a caller reads the table. | the start of `boids:remove/2` |
| `Remove(p)` | A caller found `p`: it stops `p`, then sends a leave. | the end of `boids:remove/2` |
| `Quit(p)` | `p` runs with its row: it sends a leave. | `boids:leave/2` |
| `Join(p)` | The environment handles the join of `p`. It first forgets the row of a process that stopped. A free id gives the row, and the environment watches `p`. | `{join, Pid, Entry}` |
| `Down(p)` | The environment handles the `'DOWN'` of `p`: its row goes. | `{'DOWN', Ref, process, Pid, Reason}` |
| `Leave(p)` | The environment handles a leave for `p`: the row of its id goes only when `p` has it. | `{leave, Id, Pid}` |

| Invariant or property | What it says | The fault that it stops |
|---|---|---|
| `LiveHasRow` | A process that runs as a boid has the row of its id. | A boid that moves, but that no boid sees and no caller finds. |
| `Watched` | The environment watches each process that has a row, and no other process. | A row that stays after the end of its process. |
| `NoLostRow` | When the environment handled each message, each row has a process that runs. | A boid that does not move in the environment. |
| `Fair` | The environment refuses an id only when its process did not stop. | A process of yours that cannot be a boid again after an error. |
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
and the environment checks it (`CheckOwner`).

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
| `Remove(b)` | The process of `b` stopped: the environment removes its row, the copy of the row, and the copy before its last write. | `remove/2` |
| `Begin` | A read starts, one time. | `near/3` |
| `Read(c)` | The reader reads all the copies of the cell `c`. | one `ets:lookup/2` |
| `End` | Each cell is read: the reader keeps one copy of each boid. | `lists:ukeysort/2` |

| Invariant or property | What it says | The fault that it stops |
|---|---|---|
| `OneTime` | A boid is in the result of a read one time at most. | A neighbor that counts two times. |
| `Finds` | A boid that runs, and that did not change its cell during the read, is in the result. | A neighbor that a boid does not see, and hits. |
| `Whole` | When a boid that runs does not write, the grid has one copy of its row, in the cell of the row. | An old copy that stays: a boid at two places. |
| `Gone` | The grid has no copy of a boid whose row the environment removed. | A boid that is not in the environment, but that the other boids see and move away from. |
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
| `OneMoment` | After a step, each boid is where a boid that read the environment at the start of the step goes. A boid whose process stopped before it moved is where it was. | The same. |
| `Ends` | Each step ends, also when processes stop during the step. | A caller that waits for a process that stopped. |

The small model (`specs/MCStep.tla`): three boids and two steps.
`MCStepOnePart.cfg` lets a boid move when it calculates: `Quiet`
violated. `MCStepClock.cfg` gives a clock to one boid: `Quiet` violated.
Thus a run gives the same result each time only when each boid has
`tick => manual`.

## The replay: the code against the specification

`Boids.MembersSpec` (`test/support/members_spec.ex`) does two things.

`trace/1` and `events/2` record the messages that the process of a real
environment handles, with a trace session of Erlang on
`boids_environment:handle_call/3` and `boids_environment:handle_info/2`:
a join with its answer, a leave, and a `'DOWN'` with the id of its
monitor.

`replay/3` takes the events and the rows of the real table at the end,
and:

1. writes a module `Run.tla` that extends `Members` with the constants of
   the events: one process for each join, and the ids;
2. loads it in the machine of the checker
   (`Accord.TLA.Checker.Machine`);
3. takes each event as one action of the environment (`Join`, `Leave`,
   `Down`), and checks the answer of each join against the row of the
   specification;
4. checks each invariant after each step;
5. checks that each row of the real table is a row of the specification,
   and that no other id has a row.

The environment does not see the acts of the other processes (`Start`,
`Stop`, `Find`, `Remove`, `Quit`). The replay puts them where the events
need them. When two orders are possible, it follows each one: for a
join, the process of the row stopped, or not. The result is `:ok`,
`{:error, {:diverged, event}}` when no order explains an event, or
`{:error, {:violated, invariant, event}}`.

`test/boids_members_spec_test.exs` replays:

- an environment with boids that start, stop, start again with their id,
  leave and go;
- boids that a test kills, each with a new boid of the same id at once:
  the join of the new process and the `'DOWN'` of the old process come
  in the two orders;
- 40 random lists of acts, where the processes of the test and of the
  environment run at the same time (a property test);
- events that are not a behavior of the specification, which must
  diverge: the events of the two fault models, a wrong answer, a lost
  row, and a row that no join made.

## What the checks do not prove

- A model is small: three processes, two boids, two cells. A fault that
  needs more is not found.
- `Space.tla` and `Step.tla` have no replay. Their tie to the code is
  the comments in `boids_space` and `gen_boid`, and the tests of the
  behavior (`test/boids_space_test.exs`, `test/boids_test.exs`).
- The replay sees the process of one environment on one node. It follows
  the orders that the tests make.
- The specifications say nothing about the forces of the rules, the
  time of a tick, or the speed.
- The relations between the boids (`boids:relate/4`) are not in
  `Members.tla`. The process of the environment has their graph, and it
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

A change of `boids_environment`, of `boids_space:put/2` and `near/3`, or of
the two parts of `boids:step/2` changes its specification in the same
commit, and the tests of the models and the replay must pass.
