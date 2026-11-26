# boids

Flocks of boids for Erlang and Elixir.

A boid is an object that moves by simple rules, and sees only the boids
near it. Many boids together move as a flock of birds, a school of fish
or a crowd of people. Craig Reynolds described the model in 1987, and
the steering rules in 1999.

- **Simple.** Start a flock, add boids with their rules, and read their
  positions. A rule of your own is a function.
- **Fast.** A boid is a value, not a process. A flock has one clock and
  a small number of worker processes, which make the steps of the boids
  on all the processors. See "The speed".
- **Exact.** In a step, all the boids calculate from the same state of
  the flock, then they all move. With a seed, a run gives the same
  result each time.
- **A process when you need one.** A boid that decides, answers
  messages and has its own state is a module of yours with the behavior
  `gen_boid`. It is in the same flock as the other boids.
- **Safe.** A boid whose rule has an error goes from its flock. The
  other boids continue.
- **No dependency.** The library is Erlang code. It uses only `kernel`
  and `stdlib`, from Erlang/OTP 27.

## The rules

| Rule | The boid... |
|---|---|
| `separation` | moves away from the near neighbors |
| `alignment` | moves in the direction of the neighbors |
| `cohesion` | moves to the center of the neighbors |
| `seek`, `flee` | moves to a target, or away from it |
| `arrive` | moves to a target, and stops there |
| `pursue`, `evade` | moves to where a target will be, or away from there |
| `wander` | moves in a direction that changes slowly |
| `avoid` | moves around the obstacles |
| `contain` | stays in a box |
| `follow` | moves along a path |
| `cruise` | keeps a speed |
| `leader` | stays behind a leader, and moves out of its way |
| `dodge` | moves away from a neighbor that will come too near |
| `flow` | moves in the direction of a field |
| a function of yours | gets the force that the function gives |

Each rule has a weight. A boid has two or three dimensions, a maximum
speed, a maximum force, a distance and an angle that it sees, and a
group. A target is a point, a boid, or the nearest boid of a group. The
module `boids_boid` has all the options.

## Install

With Mix:

```elixir
def deps do
  [{:boids, "~> 0.1"}]
end
```

With rebar3:

```erlang
{deps, [{boids, "~> 0.1"}]}.
```

## A first flock

In Erlang:

```erlang
1> {ok, Flock} = boids:start_flock(#{bounds => {{0, 0}, {100, 100}}, wrap => true}).
2> {ok, Ids} = boids:populate(Flock, 200, #{}).
3> boids:snapshot(Flock).
[#{id => #Ref<0.1.2.3>, pos => {61.2, 8.9}, vel => {-3.1, 7.4},
   group => default, data => undefined, pid => undefined} | _]
```

In Elixir, the module is `:boids`, and the options can be a keyword
list:

```elixir
{:ok, flock} = :boids.start_flock(bounds: {{0, 0}, {100, 100}}, wrap: true)
{:ok, ids} = :boids.populate(flock, 200, max_speed: 12.0)
:boids.snapshot(flock)
```

The 200 boids now move in real time: the flock makes a step each 50 ms.
`snapshot/1` reads their positions, for example to draw them.
`boids:subscribe/1` sends a message to your process after each step.
`examples/terminal.exs` draws a flock, a hawk and two obstacles in the
terminal:

```sh
mix run examples/terminal.exs
```

## The rules of a boid

The option `rules` is a list. Each rule is `{Name, Weight}` or `{Name,
Weight, Options}`:

```erlang
Birds = [
    {avoid, 4.0},
    {evade, 3.0, #{target => {group, hawks}, radius => 12}},
    {separation, 1.5, #{radius => 3}},
    {alignment, 1.0},
    {cohesion, 1.0}
],
{ok, _} = boids:populate(Flock, 70, #{group => birds, rules => Birds, combine => priority}),

Hawk = [{avoid, 4.0}, {pursue, 1.0, #{target => {group, birds}}}, {wander, 0.5}],
{ok, HawkId} = boids:add(Flock, #{pos => {50, 50}, group => hawks, rules => Hawk, perception => 25}),

ok = boids:set_obstacle(Flock, rock, {30, 30}, 5).
```

- `boids:update/3` changes the rules and the other options of a boid:
  `boids:update(Flock, HawkId, #{rules => [{arrive, 1.0, #{target =>
  {10, 10}}}]})`.
- `boids:add_rule/3` adds one rule to a boid, and `boids:delete_rule/3`
  removes one. `boids:which_rules/2` gives the names of its rules.
- A boid can have a rule two times, with a name for each one:
  `{{seek, home}, 1.0, #{target => {0, 0}}}` and `{{seek, food}, 2.0,
  #{target => {40, 10}}}`. `boids:delete_rule(Flock, Id, {seek, food})`
  removes the second one.
- With `combine => sum` (the default), the force of a boid is the sum of
  the forces of its rules. With `combine => priority`, the first rules
  of the list use the force first.
- `separation` sees all the groups. `alignment` and `cohesion` see only
  the group of the boid. The option `groups` of a rule changes this.

## A rule of your own

A rule of your own is a function. It gets the boid, the neighbors that
the boid sees (the nearest first) and the environment of the flock, and
it gives a force:

```erlang
%% A force down, and a force away from the nearest boid of the group cats.
Gravity = fun(_Boid, _Neighbors, _Env) -> {0, -9.81} end,
Fear = fun(Boid, Neighbors, _Env) ->
    case [Cat || Cat = #{group := cats} <- Neighbors] of
        [#{pos := Pos} | _] -> boids_steer:flee(Boid, Pos);
        [] -> {0, 0}
    end
end,
boids:add(Flock, #{pos => {0, 50}, rules => [{Gravity, 1.0}, {Fear, 3.0}, {wander, 0.5}]}).
```

```elixir
gravity = fn _boid, _neighbors, _env -> {0, -9.81} end
:boids.add(flock, pos: {0, 50}, rules: [{gravity, 1.0}, {:wander, 0.5}])
```

- The boid and each neighbor are maps: `maps:get(pos, Boid)`,
  `maps:get(dist, Neighbor)`. `Env` has `dt` (the seconds of the step),
  `obstacles`, `bounds` and `wrap`.
- The functions of `boids_steer` and `boids_vec` are the parts of a new
  rule: for example `boids_steer:seek/2` to a point that the rule
  calculates.
- Use `fun Module:Function/3` for a rule that stays when the code of
  its module changes.
- A function that has an error stops its boid: the flock writes the
  error to the log, and removes the boid.

## A boid with a behavior

A boid of `boids:add/2` has only its rules. A boid that decides, that
answers messages and that has its own state is a process: a module of
yours with the behavior `gen_boid`, as a module with the behavior
`gen_server`. Your module gives the options of the boid when it starts,
decides at each step, and answers messages. The library does the other
work.

```erlang
-module(hawk).
-behavior(gen_boid).
-export([init/1, handle_step/3, handle_call/4]).

%% The boid starts: its options, and the state of this module.
init(Pos) ->
    {ok, #{pos => Pos, group => hawks, perception => 25, rules => [{wander, 1.0}]}, #{meals => 0}}.

%% At each step, before the forces: the hawk hunts a bird that it sees.
handle_step(_Boid, Neighbors, State = #{meals := Meals}) ->
    case [N || N = #{group := birds} <- Neighbors] of
        [] -> {ok, #{rules => [{wander, 1.0}]}, State};
        [#{dist := Dist} | _] when Dist < 1 -> {ok, State#{meals := Meals + 1}};
        [_ | _] -> {ok, #{rules => [{pursue, 1.0, #{target => {group, birds}}}]}, State}
    end.

handle_call(meals, _From, _Boid, State = #{meals := Meals}) ->
    {reply, Meals, State}.
```

```erlang
{ok, Hawk} = gen_boid:start(hawk, {50, 50}, #{flock => Flock}),
0 = gen_boid:call(Hawk, meals).
```

The same in Elixir:

```elixir
defmodule Hawk do
  @behaviour :gen_boid

  def init(pos) do
    {:ok, %{pos: pos, group: :hawks, perception: 25, rules: [wander: 1.0]}, %{meals: 0}}
  end

  def handle_step(_boid, neighbors, %{meals: meals} = state) do
    case Enum.filter(neighbors, &(&1.group == :birds)) do
      [] -> {:ok, %{rules: [wander: 1.0]}, state}
      [%{dist: dist} | _] when dist < 1 -> {:ok, %{state | meals: meals + 1}}
      [_ | _] -> {:ok, %{rules: [{:pursue, 1.0, %{target: {:group, :birds}}}]}, state}
    end
  end

  def handle_call(:meals, _from, _boid, %{meals: meals} = state), do: {:reply, meals, state}
end

{:ok, hawk} = :gen_boid.start(Hawk, {50, 50}, flock: flock)
0 = :gen_boid.call(hawk, :meals)
```

| Callback | When it runs |
|---|---|
| `init(Args)` | The boid starts. It gives the options of the boid and the state of the module. Only this callback is necessary. |
| `handle_step(Boid, Neighbors, State)` | At each step, before the forces of the rules. It can change the options of the boid. |
| `handle_call(Request, From, Boid, State)` | `gen_boid:call/2` sent a request. |
| `handle_cast(Request, Boid, State)` | `gen_boid:cast/2` sent a request. |
| `handle_info(Info, Boid, State)` | Another message came. |
| `terminate(Reason, Boid, State)` | The process stops. |

- `gen_boid:start/3` starts a boid below the supervisor of its flock.
  `gen_boid:start_link/3` and `gen_boid:child_spec/1` are for a
  supervisor of yours (see "A boid that stops").
- The clock of the flock moves a `gen_boid` with the other boids, in the
  same step. The functions of `boids` with an id work for it too:
  `boids:update/3`, `boids:add_rule/3`, `boids:boid/2`.
- `handle_step/3` is for a decision: which rules the boid has now. A
  force of your own is a rule (see "A rule of your own").
- A process costs more than a value: the step of a `gen_boid` takes
  about two times that of a boid of `boids:add/2`. Use `boids:add/2`
  for the many boids that only follow their rules.

## The space of a flock

- `bounds => {Min, Max}` is the box of the flock. The rule `contain`
  keeps a boid in it.
- With `wrap => true`, each side of the box continues at the opposite
  side. A boid sees the boids across a side as its neighbors.
- An obstacle is a circle, or a sphere in three dimensions:
  `boids:set_obstacle/4`. Call it again to move the obstacle.
- All the boids of a flock have two dimensions, or all have three.
- The library has no unit of length. A speed is in units for each
  second.

## The time

- The clock of a flock makes a step each `tick` milliseconds (the
  default is 50): `boids:start_flock(#{tick => 20})`. The time of a step
  is the time that passed on the clock.
- In a step, first each boid calculates its movement from the same state
  of the flock, then they all move. Thus a read between two steps
  (`boids:snapshot/1`) gives one moment of the flock.
- `boids:subscribe/1` sends `{boids, Flock, {step, Count, Dt}}` to your
  process after each step: draw or read the flock then.
- `boids:set_time_scale/2` makes the time of a flock faster or slower.
  With 0, the boids stop.
- With `tick => manual`, the boids move only with `boids:step/2`. With a
  `seed` for each boid, such a run always gives the same result, with
  each number of workers. Use it for a test, or for a simulation that is
  faster than the clock.

## A process with another behavior as a boid

A process that has another behavior, for example a `gen_statem`, can be
a boid of a flock too. It calls `join/2` one time, and `advance/3` when
it wants a step: this boid has its own clock, and not that of the flock.

```erlang
init(Flock) ->
    {ok, Space, Boid} = boids:join(Flock, #{pos => {0, 0}, vel => {1, 0}}),
    erlang:send_after(50, self(), tick),
    {ok, #{space => Space, boid => Boid}}.

handle_info(tick, State = #{space := Space, boid := Boid0}) ->
    erlang:send_after(50, self(), tick),
    Boid = boids:advance(Space, Boid0, 0.05),
    {noreply, State#{boid := Boid}}.
```

The same in Elixir:

```elixir
def init(flock) do
  {:ok, space, boid} = :boids.join(flock, pos: {0, 0}, vel: {1, 0})
  Process.send_after(self(), :tick, 50)
  {:ok, %{space: space, boid: boid}}
end

def handle_info(:tick, %{space: space, boid: boid} = state) do
  Process.send_after(self(), :tick, 50)
  {:noreply, %{state | boid: :boids.advance(space, boid, 0.05)}}
end
```

The boid is a map: `maps:get(pos, Boid)` is its position.
`boids_boid:update/2` changes its rules, and `boids:commit/2` writes the
change to the flock. The other boids see it as they see each boid. The
flock removes it when the process stops.

The functions of the rules have no state and no process: `boids_boid`
(one step of one boid), `boids_steer` (each rule) and `boids_vec`
(vectors) work alone, with data of your own.

## A flock below a supervisor of yours

`boids:start_flock/1` starts a flock below the supervisor of the
application `boids`. For a flock in your supervision tree, use the child
specification, with a name:

```erlang
init([]) ->
    {ok, {#{}, [boids:child_spec(#{name => my_flock, bounds => {{0, 0}, {100, 100}}})]}}.
```

```elixir
children = [{:boids, name: :my_flock, bounds: {{0, 0}, {100, 100}}}]
```

## How it works

A flock has ETS tables with one row for each boid, and a grid of cells
as the index of the rows. A boid finds its neighbors in the cells around
it: it does not read all the flock.

The boids of `boids:add/2` are values in the workers of the flock: a
small number of processes, one for each scheduler of the node. The
clock of the flock asks for a step in two parts:

1. Each worker calculates the step of each of its boids. It reads each
   cell of the grid one time, and it writes nothing.
2. Each worker writes its boids to the tables.

A `gen_boid` does the same two parts for its one boid, at the request of
the same clock. Each row has one writer, so there is no lock in the
library. Each process reads the tables with no message: a read of the
flock does not wait for a step.

## The specifications

The flows where the order of the processes can change the result have a
specification in TLA+ (`specs/`): the members of a flock, a write
against a read of the space, and the step in two parts. The tests check
a small model of each one, and fault models that must fail, with the
native checker of [Accord](https://github.com/sntran/accord). They also
replay the messages of a real flock process as a behavior of
`specs/Flock.tla`. See [`docs/specs.md`](docs/specs.md).

## The speed

These numbers are from a computer with 4 virtual processors (x86_64,
Erlang/OTP 29 with the JIT). Each boid has the three rules of a flock,
and sees about 15 neighbors. `examples/speed.exs` measures the same on
your computer:

```sh
mix run examples/speed.exs 10000
```

| Workers | Boid steps in a second | Boids at 20 steps in a second | Boids at 60 steps in a second |
|---|---|---|---|
| 1 | 50,000 | 2,500 | 800 |
| 2 | 87,000 | 4,300 | 1,400 |
| 4 | 135,000 | 6,700 | 2,200 |

- One step of one boid takes about 20 µs on one processor: the search
  of the neighbors, the forces, the movement, and the write to the
  tables. With about 6 neighbors, it takes about 14 µs.
- With the clock at 50 ms, 4,000 boids make 20.0 steps in a second.
  With too many boids for the processors, the flock makes fewer steps in
  a second, and each step is longer (`max_dt` at most): 12,000 boids
  make 8.8 steps in a second. The node continues to answer:
  `boids:populate/3` of the 12,000 boids took 85 ms, and
  `boids:snapshot/1` 13 ms.
- A flock of 8,000 `gen_boid` makes 78,000 boid steps in a second: a
  boid that is a process costs about two times a boid that is a value.
- A boid of `boids:add/2` uses about 1 KB in the tables, and 5 KB to
  10 KB in its worker. Most of that is the garbage of the last step. A
  `gen_boid` process holds about 2.5 KB between two steps.
- Make `cell_size` near the `perception` of the boids. Keep the `data`
  of a boid small, because each neighbor gets a copy of it.
- The numbers change with the computer and with the density of the
  boids. On a computer that other programs use, they change from run to
  run by about 10 %.

## A boid that stops

- A boid of `boids:add/2` whose rule has an error goes from the flock,
  and the flock writes the error to the log. The other boids continue.
- A `gen_boid` of `gen_boid:start/3` stops with its flock. The flock
  does not start it again after an error: it removes the row of the
  boid, and the id is free. A boid with an error at each step would
  start again without end. `boids:whereis/2` gives the process of such a
  boid, for a monitor.
- For a `gen_boid` that starts again, put it below a supervisor of
  yours. Give an `id` in the options of `init/1`, so that the process
  that starts again is the same boid. The supervisor has the limit of
  the restarts that you give it:

  ```erlang
  {ok, {#{strategy => rest_for_one}, [
      boids:child_spec(#{name => my_flock}),
      gen_boid:child_spec({hawk, {50, 50}, #{flock => my_flock}})
  ]}}
  ```

- A process that starts again with the id of its last process gets its
  row again, also before the flock saw the end of the old process. That
  is true for a `gen_boid` and for a process with `boids:join/2`.
- Each process of a flock has a label (`proc_lib`), so the observer and
  a crash report show what a process is: the flock, its clock, a worker
  or a boid.
- When the process of a flock, its clock or a worker stops with an
  error, all the flock stops. A flock below a supervisor of yours starts
  again, with no boid.
- Each number of an option is 1.0e100 at most.

## The limits

- A flock is on one node: the tables are local.
- An obstacle is a circle or a sphere. There are no walls and no
  polygons. A rule of your own can add them.
- The rule `follow` does not use `wrap`.
- All the boids of a flock have the same clock. A boid of
  `boids:join/2` has the clock of its process.
- The size of the vectors of the first boid (two numbers, or three)
  stays for the life of the flock.

## Development

The tests use ExUnit and StreamData, with Mix:

```sh
mix deps.get
mix test --cover
mix format --check-formatted
```

The tests must cover all the lines of the code. A change of a flow that
has a specification changes the specification in the same commit
(`docs/specs.md`).

CI (`.github/workflows/ci.yml`) runs for each push:

- the tests on Erlang/OTP 27, 28 and 29;
- `rebar3 compile`, `rebar3 xref` and `rebar3 dialyzer`;
- the tests with [beam.com](https://github.com/sntran/BEAM.com) as the
  only tool.

## License

Apache License 2.0. See [`LICENSE`](LICENSE).
