# boids

Flocks of boids for Erlang and Elixir, with one process for each boid.

A boid is an object that moves by simple rules, and sees only the boids
near it. Many boids together move as a flock of birds, a school of fish
or a crowd of people. Craig Reynolds described the model in 1987, and
the steering rules in 1999.

In this library, each boid is an Erlang process:

- A boid moves on its own clock. It reads its neighbors, calculates its
  force, moves, and writes its position. It sends no message to do this.
- A process of your own can be a boid: a person, a vehicle or an animal
  of your program gets the rules of a boid with two function calls.
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
| a module or a function of yours | gets the force that it gives |

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
- A rule of your own is a module with the behavior `boids_rule`, or a
  function. See "A rule of your own".

## A rule of your own

A rule is a module with the behavior `boids_rule`. The module checks its
options, and gives the force of the rule for one boid at one step:

```erlang
-module(my_gravity).
-behavior(boids_rule).
-export([options/1, force/4]).

options(Options) ->
    #{g := G} = maps:merge(#{g => 9.81}, Options),
    true = is_number(G),
    #{g => G}.

force(_Boid, _Neighbors, _Env, #{g := G}) ->
    {0, -G}.
```

```erlang
boids:add(Flock, #{pos => {0, 50}, rules => [{my_gravity, 1.0, #{g => 3.7}}, {wander, 0.5}]}).
```

In Elixir, the module has `@behaviour :boids_rule`.

- A bad option gives an error when the boid gets its rules, and not at
  each step of the boid.
- A rule can keep a memory between the steps of a boid: `force/4` gives
  `{Force, Memory}`, and gets the memory in `Env` at the next step.
- For a rule with no option, a function is sufficient:
  `{fun(Boid, Neighbors, Env) -> Force end, Weight}`.
- The functions of `boids_steer` and `boids_vec` are the parts of a new
  rule: for example `boids_steer:seek/2` to a point that the rule
  calculates.

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

- A boid of `boids:add/2` makes a step each `tick` milliseconds (the
  default is 50). The time of a step is the time that passed on the
  clock.
- `boids:set_time_scale/2` makes the time of a flock faster or slower.
  With 0, the boids stop.
- With `tick => manual`, the boids move only with `boids:step/2`. First
  each boid calculates its step from the same state of the flock, then
  they all move. With a `seed` for each boid, such a run always gives
  the same result. Use it for a test, or for a simulation that is faster
  than the clock.

## A process of yours as a boid

A process of your program can be a boid of a flock. It calls `join/2`
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

- A boid of `boids:add/2` that stops with an error does not start again:
  the flock removes its row, and its id is free. A boid with an error at
  each step would start again without end. `boids:whereis/2` gives the
  process of a boid, for a monitor.
- A process of yours that is a boid has the supervisor that you gave it.
  When it starts again and calls `boids:join/2` with the same id, it
  gets its row again, also before the flock saw the end of the old
  process.
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
(`docs/specs.md`). rebar3 builds the library too (`rebar3 compile`).

## License

Apache License 2.0. See [`LICENSE`](LICENSE).
