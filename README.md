# boids

Flocks of boids for Erlang and Elixir, with one process for each boid.

A boid is an object that moves by simple rules, and sees only the boids
near it. Many boids together move as a flock of birds, a school of fish
or a crowd of people. Craig Reynolds described the model in 1987, and
the steering rules in 1999.

In this library, each boid is an Erlang process (`gen_boid`):

- A boid moves on its own clock. It reads its neighbors, calculates its
  force, moves, and writes its position. It sends no message to do this.
- The rules of a boid are callback modules, as the handlers of an event
  manager of `gen_event`. A boid gets rules and loses them while it
  runs. A rule of yours is a module with the behavior `gen_boid`: it has
  its own state, gives a force at each step, and answers requests.
- A boid that stops with an error goes from its flock. The other boids
  continue.
- The library is Erlang code with no dependency. It uses only `kernel`
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
| a module of yours (`gen_boid`), or a function | gets the force that it gives |

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
[#{id => <0.153.0>, pos => {61.2, 8.9}, vel => {-3.1, 7.4},
   group => default, data => undefined, pid => <0.153.0>} | _]
```

In Elixir, the module is `:boids`, and the options can be a keyword
list:

```elixir
{:ok, flock} = :boids.start_flock(bounds: {{0, 0}, {100, 100}}, wrap: true)
{:ok, ids} = :boids.populate(flock, 200, max_speed: 12.0)
:boids.snapshot(flock)
```

The 200 boids now move in real time: each is a process that makes a step
each 50 ms. `snapshot/1` reads their positions, for example to draw
them. `examples/terminal.exs` draws a flock, a hawk and two obstacles in
the terminal:

```sh
mix run examples/terminal.exs
```

## The rules of a boid that runs

A boid is a `gen_boid` process. You add rules to it and remove them
while it runs, as handlers of `gen_event`:

```erlang
{ok, Hawk} = gen_boid:start(Flock, #{pos => {50, 50}, group => hawks, rules => [{wander, 1.0}]}),
ok = gen_boid:add_rule(Hawk, {avoid, 4.0}),
ok = gen_boid:add_rule(Hawk, {hunger, 1.0, #{prey => birds}}),
[wander, avoid, hunger] = gen_boid:which_rules(Hawk),
0 = gen_boid:call(Hawk, hunger, meals),
ok = gen_boid:delete_rule(Hawk, wander, []).
```

`avoid` and `wander` are rules of the library. `hunger` is a module of
yours.

## A rule of your own

A rule is a module with the behavior `gen_boid`. It starts with its
arguments, has its own state, and gives a force at each step of the
boid:

```erlang
-module(hunger).
-behavior(gen_boid).
-export([init/1, handle_step/4, handle_call/3]).

%% The rule starts: its state.
init(#{prey := Prey}) ->
    {ok, #{prey => Prey, meals => 0}}.

%% At each step: the force of the rule. The boid goes to the nearest
%% prey that it sees, and eats a prey that it touches.
handle_step(Boid, Neighbors, _Env, State = #{prey := Prey, meals := Meals}) ->
    case [N || N = #{group := Group} <- Neighbors, Group =:= Prey] of
        [] -> {ok, State};
        [#{dist := Dist} | _] when Dist < 1 -> {ok, State#{meals := Meals + 1}};
        [#{pos := Pos} | _] -> {force, boids_steer:seek(Boid, Pos), State}
    end.

handle_call(meals, _Boid, State = #{meals := Meals}) ->
    {ok, Meals, State}.
```

The same in Elixir:

```elixir
defmodule Hunger do
  @behaviour :gen_boid

  def init(%{prey: prey}), do: {:ok, %{prey: prey, meals: 0}}

  def handle_step(boid, neighbors, _env, %{prey: prey, meals: meals} = state) do
    case Enum.filter(neighbors, &(&1.group == prey)) do
      [] -> {:ok, state}
      [%{dist: dist} | _] when dist < 1 -> {:ok, %{state | meals: meals + 1}}
      [%{pos: pos} | _] -> {:force, :boids_steer.seek(boid, pos), state}
    end
  end

  def handle_call(:meals, _boid, %{meals: meals} = state), do: {:ok, meals, state}
end

{:ok, hawk} = :gen_boid.start(flock, pos: {50, 50}, group: :hawks, rules: [{Hunger, 1.0, %{prey: :birds}}])
0 = :gen_boid.call(hawk, Hunger, :meals)
```

| Callback | When it runs |
|---|---|
| `init(Args)` | The boid gets the rule. It gives the state of the rule. |
| `handle_step(Boid, Neighbors, Env, State)` | At each step of the boid. It gives the force of the rule, or no force. |
| `handle_call(Request, Boid, State)` | `gen_boid:call/3` sent a request to the rule. |
| `handle_info(Info, Boid, State)` | Another message came to the process. |
| `terminate(Arg, State)` | The boid loses the rule, or its process stops. |

`init/1` and `handle_step/4` are necessary.

- **A rule can be the mind of a boid.** A result can have actions:
  `{ok, State, [{add_rule, Rule}, {delete_rule, Name}, {set, Options},
  stop]}`. Such a rule gives no force. It adds and removes the other
  rules when what the boid sees changes, changes options of the boid,
  or stops the boid.
- **A rule that fails does not stop its boid.** As a handler of
  `gen_event`, the boid loses that rule, the log gets an error, and the
  boid continues with its other rules.
- **A boid can have a rule two times**, with a name for each:
  `{{seek, home}, 1.0, #{target => {0, 0}}}`.
- **A function is a rule too**, for a force with no state:
  `{fun(Boid, Neighbors, Env) -> Force end, Weight}`.
- The functions of `boids_steer` and `boids_vec` are the parts of a new
  rule: for example `boids_steer:seek/2` to a point that the rule
  calculates.

See `gen_boid` for all the results of the callbacks.

## The rules of a boid
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

- `boids:update/3` changes the rules and the other options of a boid
  that runs: `boids:update(Flock, HawkId, #{rules => [{arrive, 1.0,
  #{target => {10, 10}}}]})`.
- With `combine => sum` (the default), the force of a boid is the sum of
  the forces of its rules. With `combine => priority`, the first rules
  of the list use the force first.
- `separation` sees all the groups. `alignment` and `cohesion` see only
  the group of the boid. The option `groups` of a rule changes this.
- A rule of your own is a module with the behavior `gen_boid`, or a
  function. See "A rule of your own".

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

- A boid makes a step each `tick` milliseconds (the default is 50). The time of a step is the time that passed on the
  clock.
- `boids:set_time_scale/2` makes the time of a flock faster or slower.
  With 0, the boids stop.
- With `tick => manual`, the boids move only with `boids:step/2`. First
  each boid calculates its step from the same state of the flock, then
  they all move. With a `seed` for each boid, such a run always gives
  the same result. Use it for a test, or for a simulation that is faster
  than the clock.

## A process with another behavior as a boid

A process that has another behavior, for example a `gen_statem`, can be
a boid of a flock too. It calls `join/2`
one time, and `advance/3` at each step:

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
`boids_boid:add_rule/2` and `boids_boid:delete_rule/3` change its rules,
`boids_boid:update/2` changes its options, and `boids:commit/2` writes
the change to the flock. The other boids see it as they see each boid. The
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
as the index of the rows. A boid reads the cells around it: it sends no
message, and it does not read all the flock. Only the process of a boid
writes its row, so there is no lock in the library. The process of the
flock only adds a row when a boid starts, and removes it when the
process of the boid stops.

A boid reads the rows while the other boids write them. Thus the
neighbors that it sees are not all of the same moment, as for a bird.
`boids:step/2` gives one moment for all the boids.

## The specifications

The flows where the order of the processes can change the result have a
specification in TLA+ (`specs/`): the members of a flock, a write
against a read of the space, and the step in two parts. The tests check
a small model of each one, and fault models that must fail, with the
native checker of [Accord](https://github.com/sntran/accord). They also
replay the messages of a real flock process as a behavior of
`specs/Flock.tla`. See [`docs/specs.md`](docs/specs.md).

## The speed

These numbers are from a computer with 4 processors (x86_64, Erlang/OTP
29 with the JIT). Each boid has the three rules of a flock, and sees
about 15 neighbors.

| Boids | Tick | Steps of each boid in a second | Processors in use |
|---|---|---|---|
| 1,000 | 50 ms | 19.6 | 22 % |
| 6,000 | 50 ms | 15.1 | 85 % |
| 12,000 | 50 ms | 7.7 | 93 % |

- One step of one boid takes about 13 µs of calculation. A real step
  also has the cost of a timer and of a process that starts to run.
- A boid process holds about 5 KB to 7 KB.
- With too many boids for the processors, the boids make fewer steps in
  a second, and each step is longer. The node continues to answer:
  `boids:populate/3` of the 12,000 boids took 1.1 seconds, and
  `boids:snapshot/1` 10 ms.
- Make `cell_size` near the `perception` of the boids. Keep the `data`
  of a boid small, because each neighbor gets a copy of it.

## A boid that stops

- The flock is the supervisor of the boids of `boids:add/2` and
  `gen_boid:start/2`: they stop with it. It does not start a boid again
  after an error: the flock removes the row of the boid, and its id is
  free. `boids:whereis/2` gives the process of a boid, for a monitor.
- A rule that fails does not stop its boid: the boid loses that rule.
- For a boid that starts again, put it below a supervisor of yours. Give
  an `id` to the boid, so that the process that starts again is the same
  boid. The supervisor has the limit of the restarts that you give it:

  ```erlang
  {ok, {#{strategy => rest_for_one}, [
      boids:child_spec(#{name => my_flock}),
      gen_boid:child_spec({my_flock, #{id => hawk, pos => {50, 50}}})
  ]}}
  ```

- A process that starts again with the id of its last process gets its
  row again, also before the flock saw the end of the old process. That
  is true for a `gen_boid` and for a process with `boids:join/2`.
- Each process of a flock and of a boid has a label (`proc_lib`), so
  the observer and a crash report show which boid a process is.
- When the process of a flock stops with an error, all the flock stops.
  A flock below a supervisor of yours starts again, with no boid.
- Each number of an option is 1.0e100 at most.

## The limits

- A flock is on one node: the tables are local.
- An obstacle is a circle or a sphere. There are no walls and no
  polygons. A rule of your own can add them.
- The rule `follow` does not use `wrap`.
- The steps of the boids are not at the same moment, except with
  `boids:step/2`.

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
