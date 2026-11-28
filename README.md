# boids

Flocks of boids for Erlang and Elixir, with one process for each boid.

A boid is an object that moves by simple rules, and sees only the boids
near it. Many boids together move as a flock of birds, a school of fish
or a crowd of people. Craig Reynolds described the model in 1987, and
the steering rules in 1999.

In this library, each boid is an Erlang process: one agent that senses,
decides and acts.

- **A boid is alone.** It moves on its own clock. It reads its
  neighbors, calculates its force, moves, and writes its position. It
  sends no message to do this.
- **A boid is yours.** A module of yours with the behavior `gen_boid`
  tells what a boid perceives, what it decides and what it does at each
  step. It answers messages, and it has its own state. A person, a
  vehicle or an animal of your program is such a module.
- **A boid has relations.** A boid follows a leader, or fears an enemy.
  The world keeps the relations as a graph.
- **A boid that stops with an error goes from its world.** The other
  boids continue.
- **No dependency.** The library is Erlang code. It uses only `kernel`
  and `stdlib`, from Erlang/OTP 29.

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
| `flow` | moves in the direction of a field: to a goal around the walls (`boids_field`) |
| `walls` | moves away from the walls of its grid |
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
1> {ok, World} = boids:start_world(#{bounds => {{0, 0}, {100, 100}}, wrap => true}).
2> {ok, Ids} = boids:populate(World, 200, #{}).
3> boids:snapshot(World).
[#{id => #Ref<0.1.2.3>, pos => {61.2, 8.9}, vel => {-3.1, 7.4},
   group => default, data => undefined, pid => <0.153.0>} | _]
```

In Elixir, the module is `:boids`, and the options can be a keyword
list:

```elixir
{:ok, world} = :boids.start_world(bounds: {{0, 0}, {100, 100}}, wrap: true)
{:ok, ids} = :boids.populate(world, 200, max_speed: 12.0)
:boids.snapshot(world)
```

The 200 boids now move in real time: each is a process that makes a step
each 50 ms. `snapshot/1` reads their positions, for example to draw
them.

The id of a boid is the option `id`, or a new reference. It is not the
process of the boid, because that process changes when the boid moves
to another node (see "A world on several nodes"). `boids:whereis/2`
gives the process of an id.

## See a flock

The directory [`examples`](https://github.com/sntran/boids/tree/main/examples)
has games made with the library, and a site that shows them: a home page
with a flock, 14 games in `/showcases`, and a playground. The site runs
at <https://boids.mkfifo.workers.dev>.

```sh
cd examples
mix deps.get
mix run --no-halt
```

Then open `http://localhost:4000`.

Each game is a folder of `examples/` with its module, its page and its
tests. Each thing that moves in a game is a boid: a module with the
behavior `gen_boid`. The tests of the examples start each game with the
library of the same commit, so CI fails when a change of the library
breaks a game.

| Game | What you do | What it shows of the library |
|---|---|---|
| [Rock Patrol](https://github.com/sntran/boids/blob/main/examples/rock_patrol/rock_patrol.ex) | Fly a ship in a field of rocks. A queen makes drones, and the drones hunt you and shoot at you. | A boid that a person controls, a rule that is a function, messages between boids, boids that start other boids, and a relation from each drone to its queen. |
| [Long Flight](https://github.com/sntran/boids/blob/main/examples/long_flight/long_flight.ex) | Lead a flock to the exit of each land, past rocks and hawks. You never control a bird: after each land, you take a card and put the rules of the flock in an order. | Rules as data that change while the boids run, the priority order of the rules, and relations to elders. |
| [Last Seen](https://github.com/sntran/boids/blob/main/examples/last_seen/last_seen.ex) | Steal purses in a busy market, then leave through a gate. The police know only what the witnesses tell them: walk with the crowd, and change your coat. | Information that goes from boid to boid with delays (a witness, a call, officers that share), boids that act on old information, and a crowd as cover. |
| [Flock Lab](https://github.com/sntran/boids/blob/main/examples/flock_lab/flock_lab.ex) | Puzzles for young programmers. Snap rule blocks together to tell the sheep what to do, then press Run and see if they reach the pen. | A program as a list of rules, an order, numbers that change a behavior, "when" blocks, and the same program as Erlang and Elixir code. |
| [Quiet Herd](https://github.com/sntran/boids/blob/main/examples/quiet_herd/quiet_herd.ex) | Cross a field of grazing deer to reach the far side. A deer that sees you too near becomes afraid, and fear goes from deer to deer. Do not start a wave. | A state of each boid (its fear) that changes its rules, and a behavior of the herd that no boid has: the wave of fear. |
| [Living Land](https://github.com/sntran/boids/blob/main/examples/living_land/living_land.ex) | Grazers eat, have young, and die. Their young get the weights of their rules with small changes. Hunters do the same. Change the land, and see what evolves. | Processes that are born and die all the time, rule weights as genes, and a world that a person changes while it runs. |
| [Night Fold](https://github.com/sntran/boids/blob/main/examples/night_fold/night_fold.ex) | You are a sheepdog. Bring the scattered sheep into the fold before the night: they run from you, so come from the right side. At night, wolves take the sheep that are outside. | One boid that a person controls moves a whole flock, because each sheep flees from it, and the flock is something that no sheep is (flocks/2). |
| [Exit Plan](https://github.com/sntran/boids/blob/main/examples/exit_plan/exit_plan.ex) | Place pillars and signs in a full hall, then sound the alarm. Bring all the people out fast, with no one hurt in the crush at the doors. | A crowd as boids, rules that are functions, obstacles that a person places while the world runs, and a crush that no person makes alone. |
| [Hive Guard](https://github.com/sntran/boids/blob/main/examples/hive_guard/hive_guard.ex) | Waves of beetles walk along a path to your hive. Place guard bees with your nectar. Each bee guards its post, chases the beetles that it sees, and stings them. | The rule follow along a path, pursue of a group, messages that change the state of another boid, and boids that the person starts while the world runs. |
| [Deep Reef](https://github.com/sntran/boids/blob/main/examples/deep_reef/deep_reef.ex) | Be the predator of a reef, and catch small fish for 90 seconds. A fish in a school is hard to catch, because its neighbors confuse you. Split a school, and catch the fish that stay alone. | A school that protects each fish with no fish that knows it: the confusion comes from the neighbors of the target. Also the rule evade, and the schools from flocks/2. |
| [Duckling Line](https://github.com/sntran/boids/blob/main/examples/duckling_line/duckling_line.ex) | Swim as a mother duck, and collect the lost ducklings into a line behind you. Lead the line around the rocks and the pikes to the nest. Do not go too fast, or the line breaks. | Relations that the boids make and remove while the game runs, a chain of leaders, and the rule leader with the target {related, follows}. |
| [Ant Trail](https://github.com/sntran/boids/blob/main/examples/ant_trail/ant_trail.ex) | Ants search for food, and an ant with food leaves a scent on its way home. Place food and rocks, and see the ants make a trail. | The rule flow with a field that is a function, a grid of scent that the boids read and write, and a trail that no ant knows. |
| [Tag Yard](https://github.com/sntran/boids/blob/main/examples/tag_yard/tag_yard.ex) | Play tag in a school yard. Run from the child that is "it". When it touches you, you are it, and you must touch another child. | A state that goes from boid to boid by a message, rules that change with the state, and a role that moves through a crowd. |
| [Firefly Field](https://github.com/sntran/boids/blob/main/examples/firefly_field/firefly_field.ex) | Lead groups of fireflies with a lantern at night. The fireflies that see each other flash together. Make all of them flash at one moment before the dawn. | Data that the neighbors see as a signal (the time of a flash), a sync that no firefly makes: it comes from small changes of each clock. Also the groups from flocks/2. |

**The playground** (`/playground`) starts boids from a definition that
you write: kinds of boids with their animals, their rules, what they do
when they see another kind, and chains of boids that follow each other.

The site also runs on Cloudflare Workers, with the BEAM in WebAssembly
([beam.com](https://github.com/sntran/BEAM.com)): see
[`examples/README.md`](https://github.com/sntran/boids/blob/main/examples/README.md).

`examples/terminal.exs` draws a flock of birds and a hawk in the
terminal, and `examples/speed.exs` measures the speed of a flock on your
computer.

## A boid with a behavior

`gen_boid` is the behavior of a boid. At each step, a boid does three
things: it senses (it finds its neighbors), it decides (it calculates
the force of its rules), and it acts (it moves). The library does these
three things. Your module can add to each of them with a callback, and
it answers messages.

```erlang
-module(hawk).
-behavior(gen_boid).
-export([init/1, handle_sense/2, handle_decide/2, handle_act/1, handle_call/3]).

%% The boid starts: its options. The key state is for this module.
init(Pos) ->
    {ok, #{pos => Pos, group => hawks, perception => 25, rules => [{wander, 1.0}], state => #{energy => 10.0}}}.

%% After the library found the neighbors: add what this boid perceives.
handle_sense(Seen = #{neighbors := Neighbors}, Boid) ->
    {ok, Seen#{prey => [N || N = #{group := birds} <- Neighbors]}, Boid}.

%% Before the forces: the rules for this step.
handle_decide(#{prey := [_ | _]}, Boid = #{state := #{energy := Energy}}) when Energy > 2 ->
    {ok, boids_boid:update(Boid, #{rules => [{pursue, 1.0, #{target => {group, birds}}}]})};
handle_decide(_Seen, Boid) ->
    {ok, boids_boid:update(Boid, #{rules => [{wander, 1.0}]})}.

%% After the movement: the effects.
handle_act(Boid = #{vel := Vel, state := State = #{energy := Energy}}) ->
    {ok, Boid#{state := State#{energy := Energy - 0.01 * boids_vec:norm(Vel)}}}.

handle_call(energy, _From, Boid = #{state := #{energy := Energy}}) ->
    {reply, Energy, Boid}.
```

```erlang
{ok, Hawk} = gen_boid:start(World, hawk, {50, 50}),
10.0 = gen_boid:call(Hawk, energy).
```

The same in Elixir:

```elixir
defmodule Hawk do
  @behaviour :gen_boid

  def init(pos) do
    {:ok, %{pos: pos, group: :hawks, perception: 25, rules: [wander: 1.0], state: %{energy: 10.0}}}
  end

  def handle_sense(%{neighbors: neighbors} = seen, boid) do
    {:ok, Map.put(seen, :prey, Enum.filter(neighbors, &(&1.group == :birds))), boid}
  end

  def handle_decide(%{prey: [_ | _]}, %{state: %{energy: energy}} = boid) when energy > 2 do
    {:ok, :boids_boid.update(boid, %{rules: [{:pursue, 1.0, %{target: {:group, :birds}}}]})}
  end

  def handle_decide(_seen, boid), do: {:ok, :boids_boid.update(boid, %{rules: [wander: 1.0]})}

  def handle_act(%{vel: vel, state: %{energy: energy} = state} = boid) do
    {:ok, %{boid | state: %{state | energy: energy - 0.01 * :boids_vec.norm(vel)}}}
  end

  def handle_call(:energy, _from, %{state: %{energy: energy}} = boid), do: {:reply, energy, boid}
end

{:ok, hawk} = :gen_boid.start(world, Hawk, {50, 50})
10.0 = :gen_boid.call(hawk, :energy)
```

| Callback | When it runs |
|---|---|
| `init(Args)` | The boid starts. It gives the options of the boid. Only this callback is necessary. |
| `handle_sense(Seen, Boid)` | At each step, after the library found what the boid perceives. It can add to `Seen`, or change it. |
| `handle_decide(Seen, Boid)` | At each step, before the forces of the rules. It can change the rules. |
| `handle_act(Boid)` | At each step, after the movement. |
| `handle_call(Request, From, Boid)` | `gen_boid:call/2` sent a request. |
| `handle_cast(Request, Boid)` | `gen_boid:cast/2` sent a request. |
| `handle_info(Info, Boid)` | Another message came. |
| `terminate(Reason, Boid)` | The process stops. |

- **The boid is the state.** Each callback gets the boid, and gives the
  boid. The boid is a map: `maps:get(pos, Boid)` is its position. The
  key `state` is for your module, and only the boid sees it. The key
  `data` is what the neighbors see.
- `Seen` is a map with what the boid perceives in this step:
  `neighbors` (the nearest first), `obstacles` (those that the boid can
  reach, see "The world"), `grids` (the grids that the boid uses, see
  "The walls of a world"), `bounds`, `wrap` and `dt`. The rules get it
  too, so a rule of yours reads the keys that `handle_sense/2` added.
- Change the rules and the other options of the boid with the functions
  of `boids_boid` (`update/2`, `add_rule/2`, `delete_rule/2`), which
  check the new values.
- A module with only `init/1` is a boid that follows its rules. A boid
  of `boids:add/2` and `boids:populate/3` is a `gen_boid` with no module
  of yours.
- `gen_boid:start/3` starts a boid below the supervisor of its world.
  `gen_boid:start_link/3` and `gen_boid:child_spec/1` are for a
  supervisor of yours (see "A boid that stops").
- Two kinds of boid that share a part, for example a hawk and a wolf
  that get hungry, call the same module of yours from their callbacks.

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
{ok, _} = boids:populate(World, 70, #{group => birds, rules => Birds, combine => priority}),

Hawk = [{avoid, 4.0}, {pursue, 1.0, #{target => {group, birds}}}, {wander, 0.5}],
{ok, HawkId} = boids:add(World, #{pos => {50, 50}, group => hawks, rules => Hawk, perception => 25}),

ok = boids:set_obstacle(World, rock, {30, 30}, 5).
```

- `boids:update/3` changes the rules and the other options of a boid:
  `boids:update(World, HawkId, #{rules => [{arrive, 1.0, #{target =>
  {10, 10}}}]})`.
- `boids:add_rule/3` adds one rule to a boid, and `boids:delete_rule/3`
  removes one. `boids:which_rules/2` gives the names of its rules.
- A boid can have a rule two times, with a name for each one:
  `{{seek, home}, 1.0, #{target => {0, 0}}}` and `{{seek, food}, 2.0,
  #{target => {40, 10}}}`. `boids:delete_rule(World, Id, {seek, food})`
  removes the second one.
- `separation` sees all the groups. `alignment` and `cohesion` see only
  the group of the boid. The option `groups` of a rule changes this.

### The order of the rules

The rules of a boid are a list, and the list has an order.

- With `combine => sum` (the default), the order has no effect on the
  force. The force is the sum of the forces of all the rules, each
  multiplied by its weight, with the length `max_force` at most.
- With `combine => priority`, the order is the priority. Each rule, in
  the order of the list, takes a part of `max_force`, and the last rules
  get what stays. Put `avoid` first there.
- The order is also the order of `boids:which_rules/2`, and
  `boids:delete_rule/3` removes the first rule with a name.

`boids_boid:forces/3` gives the force of each rule, before the forces
become one force. Use it to see what each rule does, and to adjust the
weights:

```erlang
{ok, Boid} = boids:boid(World, Id),
Neighbors = boids:sense(boids:space(World), Boid),
{Forces, _} = boids_boid:forces(Boid, Neighbors, #{dt => 0.05}),
[{separation, _}, {alignment, _}, {cohesion, _}] = Forces.
```

## A rule of your own

A rule of your own is a function. It gets the boid, the neighbors that
the boid sees (the nearest first) and what the boid perceives of its
world, and it gives a force:

```erlang
%% A force down, and a force away from the nearest boid of the group cats.
Gravity = fun(_Boid, _Neighbors, _Seen) -> {0, -9.81} end,
Fear = fun(Boid, Neighbors, _Seen) ->
    case [Cat || Cat = #{group := cats} <- Neighbors] of
        [#{pos := Pos} | _] -> boids_steer:flee(Boid, Pos);
        [] -> {0, 0}
    end
end,
boids:add(World, #{pos => {0, 50}, rules => [{Gravity, 1.0}, {Fear, 3.0}, {wander, 0.5}]}).
```

```elixir
gravity = fn _boid, _neighbors, _seen -> {0, -9.81} end
:boids.add(world, pos: {0, 50}, rules: [{gravity, 1.0}, {:wander, 0.5}])
```

- The boid and each neighbor are maps: `maps:get(pos, Boid)`,
  `maps:get(dist, Neighbor)`. `Seen` is what the boid perceives in this
  step: `dt` (the seconds of the step), `obstacles` (those that the
  boid can reach), `grids`, `bounds` and `wrap`.
- The functions of `boids_steer` and `boids_vec` are the parts of a new
  rule: for example `boids_steer:seek/2` to a point that the rule
  calculates.
- Use `fun Module:Function/3` for a rule that stays when the code of
  its module changes.
- A function that has an error stops the process of its boid, and the
  world removes the boid.

## The relations between the boids

A boid can have a relation to another boid: it follows a leader, it
fears an enemy, it has a mate. A relation has a direction and a label,
which is a term of yours.

```erlang
ok = boids:relate(World, Bird, follows, Leader),
ok = boids:update(World, Bird, #{rules => [{leader, 1.0, #{target => {related, follows}}}]}),

[Leader] = boids:related(World, Bird, follows),
[Bird] = boids:related_to(World, Leader, follows).
```

- A rule with the target `{related, Label}` uses the relation at each
  step. The boid reads it from a table, with no message.
- The relations of a boid go when the boid goes from its world.
- The world keeps the relations as a graph, with the module `graph` of
  Erlang/OTP. `boids:relations/1` gives it, and the functions of `graph`
  answer questions about it:

  ```erlang
  Relations = boids:relations(World),
  Chain = graph:get_path(Relations, Bird, TopLeader),
  true = graph:is_acyclic(Relations).
  ```

- With `boids:start_world(#{relations => acyclic})`, a relation that
  makes a cycle gives `{error, cycle}`. Use it for a hierarchy: the
  order of a formation is then `graph:topsort/1`.

## The flocks of a world

A flock is a group of boids that see each other. No process makes a
flock: it comes from the rules of the boids. `boids:flocks/2` gives the
flocks of a world, as lists of ids:

```erlang
Flocks = boids:flocks(World, 10),
Largest = lists:max([length(Flock) || Flock <- Flocks]).
```

Two boids are in one flock when a chain of boids goes from one to the
other, each at the distance 10 or less from the next.

`boids:graph/2` gives all the world as a graph for the module `graph`:
each boid is a vertex with its row as the label, and an edge goes from a
boid to each boid at a distance or less.

```erlang
Graph = boids:graph(World, 10),
Alone = [Id || Id <- graph:vertices(Graph), graph:out_degree(Graph, Id) =:= 0],
true = graph:has_path(Graph, BoidA, BoidB).
```

Use it to find the boids that are alone, or if a signal can go from one
boid to another from neighbor to neighbor. The two functions read all
the world, and take 50 µs to 200 µs for each boid: they are for a
view, and not for each step of a boid.

## The world

- `bounds => {Min, Max}` is the box of the world. The rule `contain`
  keeps a boid in it.
- With `wrap => true`, each side of the box continues at the opposite
  side. A boid sees the boids across a side as its neighbors.
- An obstacle is a circle, or a sphere in three dimensions:
  `boids:set_obstacle/4`. Call it again to move the obstacle. The
  process of the world writes it, so the call is one message and its
  answer. `boids:obstacles/1` gives all the obstacles of the world.
- A boid gets only the obstacles that it can reach in this step: those
  to the distance `boids_boid:reach/1` from it, which is the largest of
  its `perception` and of `max_speed * lookahead + clearance` (the
  options of the rule `avoid`). The world keeps the obstacles in an
  index of cells, as it keeps the boids. Thus an obstacle far from the
  boids costs almost nothing, and a level can have hundreds of rocks,
  trees or posts. An obstacle that touches more than 1,024 cells is a
  large obstacle: each boid reads it at each step.
- All the boids of a world have two dimensions, or all have three.
- The library has no unit of length. A speed is in units for each
  second.

## The walls of a world

The rules give forces, and the forces add: no rule can stop a boid at a
wall. A grid tells where a boid can walk, and the option `walkable` of a
boid is a hard limit that no force can pass.

```erlang
%% A land of 100 x 30 with a wall in the middle: # is a blocked cell.
Land = boids_grid:from_rows([
    "..........",
    "....##....",
    ".........."
], #{cell_size => 10.0}),
{ok, World} = boids:start_world(#{bounds => {{0, 0}, {100, 30}}, defaults => #{walkable => {named, land}}}),
ok = boids:set_grid(World, land, Land),
{ok, _People} = boids:populate(World, 20, #{rules => [{wander, 1.0}, {walls, 2.0}]}),
{ok, _Bird} = boids:add(World, #{pos => {50, 15}, walkable => all}),
%% A door opens in the wall.
ok = boids:set_grid(World, land, boids_grid:set_cost(Land, [{4, 1}], 1)).
```

- **The world owns the walls.** A grid (`boids_grid`) is a fact of the
  world with a name, as an obstacle: `boids:set_grid/3`,
  `boids:remove_grid/2`, `boids:grid/2`. A grid comes from a list of
  blocked cells, from rows of text, or from a function that tells for
  the center of each cell if it is blocked. A cell also has a cost, for
  a search of ways.
- **A boid tells which walls limit it:** `walkable => {named, Name}`, or
  `all` (the default). The option `defaults` of the world gives it to
  all the boids, and a boid of another kind can have another value:
  walls for people, and not for birds. A name with no grid is no limit.
- **A boid slides along a wall.** When the movement of a step goes into
  a blocked cell, the library removes the part of the movement into the
  edge, and the same part of the velocity. A boid that goes into a wall
  at 45 degrees slides along it at 0.71 of its speed. A boid stops only
  in a corner. The contact is exact: a fast boid does not go through a
  thin wall.
- **A door is a new grid for the same name.** `boids:set_grid/3` again
  changes the walls for all the boids, from their next step. A boid
  that is then in a blocked cell goes to the nearest walkable place at
  its next step.
- **On several nodes, each node has all the grids.** A grid is a fact
  of the world, as an obstacle: a change is for all the nodes, a node
  that comes later gets the grids, and after a split of the network the
  last change of a grid wins on all the nodes (see "A world on several
  nodes").
- **The rule `walls`** moves a boid away from a wall before it touches
  it. With it, the movement is smooth, and the limit acts only a
  little. The force does not change with the thickness of a wall.
- The steps of `boids:step/2`, and of a process of yours with
  `boids:join/2` and `boids:advance/3`, obey the limit.
  `boids:populate/3` puts boids only in walkable places.
- **A grid has two dimensions.** A boid with three dimensions cannot
  have the option `walkable`.
- A grid of 200 x 200 cells is 320 KB, in one binary that all the boids
  share. A boid keeps the grid that it read, and reads it again only
  after a change. With 1,000 boids, the limit makes a step 2 % longer.

`examples/bridge.exs` measures boids that carry things across a river on
a narrow bridge: `mix run examples/bridge.exs walkable 1`. With
`separation` and no limit, 13 % of the steps of the boids end in the
water. With the option `walkable`, none does.

## The ways of a world

The rule `seek` goes straight to a target, through the walls. A field
of directions (`boids_field`) has, for each place of a grid, the
direction of the shortest way to a goal, around the walls. One field
leads all the boids that go to the same goal, so its cost does not
change with the number of the boids.

```erlang
%% A land of 40 x 30 with a wall, and a door of two cells in the wall.
Land = boids_grid:new(#{
    size => {40, 30},
    blocked => [{20, J} || J <- lists:seq(0, 29), J =/= 14, J =/= 15]
}),
{ok, World} = boids:start_world(#{bounds => {{0, 0}, {40, 30}}, defaults => #{walkable => {named, land}}}),
ok = boids:set_grid(World, land, Land),
%% The ways to the cell {35, 5}, at the other side of the wall.
ok = boids:set_field(World, exit, boids_field:new(Land, [{35, 5}])),
{ok, _People} = boids:populate(World, 30, #{
    area => {{2, 2}, {15, 28}},
    rules => [{flow, 1.0, #{field => {named, exit}}}, {separation, 1.5, #{radius => 0.7}}]
}),
%% The door closes, and another door opens: new walls, and new ways.
Closed = boids_grid:set_cost(Land, [{20, 14}, {20, 15}], blocked),
Land2 = boids_grid:set_cost(Closed, [{20, 3}, {20, 4}], 1),
ok = boids:set_grid(World, land, Land2),
ok = boids:set_field(World, exit, boids_field:new(Land2, [{35, 5}])).
```

- **A field comes from a grid and its goals:** `boids_field:new(Grid,
  Goals)`, with one goal cell or more. With more than one goal, each
  place has the way to the goal that costs the least: all the exits of
  a house, or all the cells of a region.
- **The world keeps fields by name,** as it keeps grids:
  `boids:set_field/3`, `boids:remove_field/2`, `boids:field/2`. The rule
  `{flow, Weight, #{field => {named, Name}}}` reads the field. There is
  one copy of a field for all the boids of a node. A boid keeps the
  field that it read, and reads it again only after a change.
- **A new field for the same name changes the ways** for all the boids,
  from their next step: after a door opens, or when the goal moves. The
  calculation is not in the process of the world: `boids_field:new/2`
  runs in the process that calls it, so a large field does not stop the
  world.
- **The directions are at each angle.** A search from cell to cell gives
  only 8 directions, and all the boids then go on the same 8 lines. The
  library solves the eikonal equation on the grid. In the measurements,
  the ways of a field are 1 to 2 % longer than the shortest ways, and
  the ways of a search of 8 directions are 5 to 6 % longer
  ([`docs/fields.md`](https://github.com/sntran/boids/blob/main/docs/fields.md)).
- **Near a wall, the direction goes to the center of the next cell.**
  A boid keeps half a cell from a wall where it can, it goes around a
  corner and not across it, and it stays in the middle of a narrow way.
- **A cell has a cost** (`boids_grid`): a way goes around a swamp when
  that costs less. To keep the ways away from the walls, give a higher
  cost to the cells near them: `examples/bridge.exs` does this for the
  cells near its water.
- **`boids_field:distance/2`** gives the cost of the way from a place to
  its goal, or `infinity` for a place with no way. A way across one
  cell with the cost 1 costs 1. It is not exactly the cost of the
  shortest way: in the measurements it is 0 to 8 % more.
- **`boids_field:path/2`** gives the points of the way from a place to
  its goal: for one boid with the rule `follow`, for a picture, or for
  the length of a way.
- **A field does not limit a boid.** A boid that another force pushes
  into a wall, or out of the grid, has no direction there. Use the
  option `walkable` with the same grid, as in the example.
- A grid of 200 x 200 cells gives a field in about 40 milliseconds, and
  a field is 6 bytes for each cell. A read of a direction takes 0.3
  microsecond.

## The time

- A boid makes a step each `tick` milliseconds of its own clock (the
  default is 50). The time of a step is the time that passed on the
  clock.
- `boids:set_time_scale/2` makes the time of a world faster or
  slower. With 0, the boids stop.
- With `search => 4`, a boid searches the world for its neighbors at
  one step of 4. In the other steps, it reads only the neighbors that it
  knows, where they are now. The search is the largest part of a step,
  so such boids make more steps in a second (see "The speed"). A boid
  does not see a boid that came near after its last search.
- With `tick => manual`, the boids move only with `boids:step/2`. First
  each boid calculates its step from the same state of the world, then
  they all move. With a `seed` for each boid, such a run always gives
  the same result. Use it for a test, or for a simulation that is faster
  than the clock.

## A process with another behavior as a boid

Use `gen_boid` for a new boid. A process that has another behavior, for
example a `gen_statem`, can be a boid of a world too. It calls
`join/2` one time, and `advance/3` at each step:

```erlang
init(World) ->
    {ok, Space, Boid} = boids:join(World, #{pos => {0, 0}, vel => {1, 0}}),
    erlang:send_after(50, self(), tick),
    {ok, #{space => Space, boid => Boid}}.

handle_info(tick, State = #{space := Space, boid := Boid0}) ->
    erlang:send_after(50, self(), tick),
    Boid = boids:advance(Space, Boid0, 0.05),
    {noreply, State#{boid := Boid}}.
```

The same in Elixir:

```elixir
def init(world) do
  {:ok, space, boid} = :boids.join(world, pos: {0, 0}, vel: {1, 0})
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
change to the world. The other boids see it as they see each
boid. The world removes it when the process stops.

The functions of the rules have no state and no process: `boids_boid`
(one step of one boid), `boids_steer` (each rule) and `boids_vec`
(vectors) work alone, with data of your own.

## A world below a supervisor of yours

`boids:start_world/1` starts a world below the supervisor
of the application `boids`. For a world in your supervision tree,
use the child specification, with a name:

```erlang
init([]) ->
    {ok, {#{}, [boids:child_spec(#{name => my_world, bounds => {{0, 0}, {100, 100}}})]}}.
```

```elixir
children = [{:boids, name: :my_world, bounds: {{0, 0}, {100, 100}}}]
```

## A world on several nodes

A world can be on several nodes, so that a large world uses the
processors of several computers. Give the world a name (an atom), and
start it on each node with the same options:

```erlang
%% On each node of the cluster.
{ok, _} = boids:start_world(#{name => sky, bounds => {{0, 0}, {4000, 4000}}, wrap => true}).
```

The worlds with that name on the connected nodes are one world.
`boids:nodes(sky)` gives its nodes. With one node, nothing changes: a
world on one node has no border and sends no message.

- **Each node has a part of the world.** The world is cut into tiles
  (the option `tile`, 16 cells by default: 160 units). The names of the
  nodes give the node of each tile, with no configuration. A new node
  takes its part of the tiles, and the tiles of a node that stops go to
  the other nodes.
- **A boid is a process on the node of its tile.** It reads the tables
  of its node, as on one node. No process tells a boid what is near it.
- **Near a border, a boid shows itself.** A boid that sees a tile of
  another node sends its row to that node at each step. The boids of
  that node then see it as a neighbor. A row that gets no update for
  half a second goes.
- **Across a border, a boid moves.** Its process starts on the other
  node, and the first process stops with the reason `{shutdown, {moved,
  Node}}`. The boid keeps its id, its state (the key `state`), its
  rules, its relations, the options of its process and its random
  numbers: a boid with a `seed` continues its sequence. `terminate/2`
  of its module runs on the first node, and `init/1` does not run on
  the new node.
- **The functions of `boids` are about all the world.** `snapshot/1`,
  `count/1`, `flocks/2`, `graph/2` and `step/2` give the result for
  the boids of all the nodes, from each node. With a last argument
  `local`, they are about the boids of this node only.
- **The obstacles, the scale of the time and the grids are on all the
  nodes.** `set_obstacle/4`, `remove_obstacle/2`, `set_time_scale/2`,
  `set_grid/3` and `remove_grid/2` change the world on each node: a
  rock is a rock for each boid, a wall is a wall on each node, and the
  scale 0 stops all the world. A node that comes later gets them.

```erlang
%% From each node, for a boid on each node.
Pid = boids:whereis(sky, Id),
ok = boids:update(sky, Id, #{max_speed => 5}),
{ok, Boid} = boids:boid(sky, Id).
```

What changes for your code:

- The functions with an id find a boid on each node: `whereis/2`,
  `boid/2`, `update/3`, `remove/2`, `add_rule/3`, `relate/4`.
- A call to a boid of another node has a time limit: 5 seconds, or the
  value `timeout` of the application `boids`, in milliseconds. With no
  answer in that time, the result is `{error, timeout}`, and
  `whereis/2` gives `undefined`. The other node can do the work of the
  call later. With no connection to the node, the boid is not found.
- `step/2` does not wait for a node that has no connection: it makes
  the step on the other nodes.
- `set_obstacle/4`, `remove_obstacle/2`, `set_time_scale/2`,
  `set_grid/3` and `remove_grid/2` change the world on all its nodes.
  When the result is `ok`, each node that has a connection to this node
  has the change. With no answer of a node in the time limit, the
  result is `{error, timeout}`: this node has the change, and that node
  gets it later. These functions have no form for one node only: all
  the nodes must have the same obstacles, the same scale of the time
  and the same grids.
- `obstacles/1` and `grid/2` read the tables of this node, with no
  message. Each node has all the obstacles and all the grids, so there
  is no `obstacles(World, local)`.
- A boid with the option `walkable` that moves to another node finds
  the same walls there: the option goes with the boid, and the grid is
  on each node. `set_grid/3` sends the grid to each node (320 KB for
  200 x 200 cells), and a node that comes later gets all the grids.
- The id of a boid is not its process. In a callback, the function
  `lookup` of `Seen` gives the row of a neighbor, with its process:
  `{ok, #{pid := Pid}} = (maps:get(lookup, Seen))(Id)`.
- `near/3` and `lookup/2` are of this node, as the read of a boid that
  looks for its neighbors: they give the boids of this node, and the
  boids of other nodes that show themselves near a border.
- Only a boid that the world supervises moves to another node: a boid
  of `add/2`, `populate/3` and `gen_boid:start/3`. A boid below a
  supervisor of yours (`gen_boid:start_link/3`) and a process of yours
  with `boids:join/2` stay on their node. They show themselves to the
  node of the tile where they are.
- Make a tile much larger than the distance that a boid sees. Then few
  boids are near a border.
- Make the world many tiles large. With few tiles, one node can get
  most of them: in a test with 9 tiles and two nodes, one node had two
  thirds of the boids.
- Several nodes help when they have their own processors. On one
  computer, a world of 6,000 boids on two nodes made 15 % to 25 % fewer
  steps than on one node: that is the cost of the borders and of the
  moves.
- A read of all the nodes (`boids:snapshot/1`, `boids:count/1`) is not
  of one moment: a boid that moves at that moment can be absent, or
  counted two times by `count/1`.
- The ids of a world are for one boid each, on all the nodes. The world
  cannot tell two boids with one id from two processes of one boid: it
  stops one of them. A boid below a supervisor of yours always stays,
  and a boid with its id that comes from another node stops.

The move is safe when the network has faults:

- A move waits for its answer with no time limit. The connection
  between two nodes loses no message, so a slow node does not make two
  processes of one boid.
- When the connection ends during a move, the boid can have a process
  on each of the two nodes. While the nodes have no connection, each
  node continues alone with all the tiles.
- When the nodes have a connection again, each world tells the other
  its boids. For a boid with two processes, one world decides which
  process stays: the one that made more moves, then the one of the node
  with the larger name. The other process stops with the reason
  `{shutdown, replaced}`.
- A node that starts a process for a boid that comes tells all the
  other nodes. Thus two processes of one boid are found also on two
  nodes that always had their connection: for example after a move to
  a third node.
- The specifications `specs/Move.tla` (two nodes) and
  `specs/MoveMany.tla` (three nodes) have this flow. Their models check
  that no move, no split and no decision loses a boid, and that a boid
  has one process when all the nodes have a connection again.

The obstacles, the scale of the time and the grids (the facts of a
world) are safe when the network has faults too:

- **The last change wins: by the clocks of the computers when they
  agree, and in each case all the nodes get the same value.** Each
  change has a version: a counter and the node. The counter is the time
  of the system in microseconds, or the largest counter that the node
  knows plus 1 when that is more. A node takes a change only when its
  version is larger than the version that it has: the counter first,
  then the name of the node. That compare gives one value on all the
  nodes for each clock of each computer. The time makes that value the
  last change.
- **During a split, each side can change the facts.** When the nodes
  have a connection again, each world gives all its facts to the other
  worlds. Then all the nodes have one value for each fact. An obstacle
  that only one side made is on all the nodes. For an obstacle that the
  two sides changed, the change that was made later in time wins, also
  when the other side made more changes: one change takes more than a
  microsecond, so the changes of a node do not put its counter ahead of
  its clock. With the same counter, the change of the node with the
  larger name wins.
- **A world that starts again makes changes that count.** It starts
  with no fact, and it gets the facts of the other nodes a short time
  later. A change that it makes before that has the time of the system
  as its counter, so it is after the older facts of the other nodes.
- **A fact that was removed stays removed.** A node keeps a mark for an
  obstacle that was removed, so that an older change of another node
  does not bring it back. A node drops a mark after 10 minutes
  (`boids:mark_time/0`, the value `mark_time` of the application
  `boids`). The value `infinity` keeps each mark.
- The process of the world of a node tells the other nodes, and it does
  not wait for them: a caller that stops in the middle changes nothing.
  No world waits for another world.
- The specification `specs/Facts.tla` has this flow. Its models check
  that all the nodes come to the same facts, and that an older change
  never brings back a fact that was removed.

The limits of a world on several nodes:

- The time of a mark (`boids:mark_time/0`) has two limits. A node that
  has no connection for longer than that time can bring back an
  obstacle that the other nodes removed in that time: use a time longer
  than the longest split of your network. And each node keeps one mark
  for each obstacle that was removed in that time: a longer time needs
  more memory. With `infinity`, a removed obstacle stays removed after
  a split of each length, and the marks have no limit.
- "The last change" needs clocks that agree. When the clock of a
  computer is ahead, its change can win against a later change of
  another computer, when the two nodes did not see each other (during a
  split, or for a world that starts again). All the nodes get the same
  value in each case.
- The boids of a node that stops are gone. The world keeps no copy of
  a boid on another node.
- During a split of the network, a boid of the border can be two times
  in the world, until the nodes have a connection again.
- The option `relations => acyclic` checks the relations of the node
  of the boid that has the relation.
- A relation is on the node of the boid that has it, and it moves with
  that boid. A rule with the target `{related, Label}` gives a force
  only while the boid perceives the other boid: on its node, or near
  the border.
- Each node needs the code of the modules of the boids, and the same
  options of the world. Worlds with one name and other options are not
  one world: each of the two nodes writes an error to its log.

## How it works

A world has ETS tables with one row for each boid, and a grid of
cells as the index of the rows. A boid reads the cells around it: it
sends no message, and it does not read all the world. Only the
process of a boid writes its row, so there is no lock in the library.
The process of the world only adds a row when a boid starts, and
removes it when the process of the boid stops. It also keeps the graph
of the relations, and writes the relations of each boid to a table that
the boids read.

The process of the world is also the only process that writes the
facts of the world: the obstacles, the scale of the time and the grids.
`boids:set_obstacle/4`, `boids:remove_obstacle/2`,
`boids:set_time_scale/2`, `boids:set_grid/3` and `boids:remove_grid/2`
send it one message, and it makes one change after the other. The boids
read these facts from its tables, with no message. A grid is large, so
a boid keeps the grid that it read: the world counts the changes of its
grids, and a boid reads a grid again only when that number changed.

A boid reads the rows while the other boids write them. Thus the
neighbors that it sees are not all of the same moment, as for a bird.
`boids:step/2` gives one moment for all the boids.

## The specifications

The flows where the order of the processes can change the result have a
specification in TLA+ (`specs/`): the members of a world, a write
against a read of the world, the step in two parts, the move of a
boid to another node, the obstacles, the scale of the time and the
grids on several nodes, and the grid that a boid keeps. The tests
check a small model of each one, and fault models that must fail, with
the native checker of [Accord](https://github.com/sntran/accord). They
also replay the messages of the process of a real world as a
behavior of `specs/Members.tla`. See [`docs/specs.md`](docs/specs.md).

## The speed

These numbers are from a computer with 4 virtual processors (x86_64,
Erlang/OTP 29 with the JIT). Each boid has the three rules of a flock,
a tick of 50 ms, and sees about 15 neighbors. `examples/speed.exs`
measures the same on your computer:

```sh
mix run examples/speed.exs 6000
```

| Boids | Steps of each boid in a second | The same, with `search => 4` |
|---|---|---|
| 4,000 | 19.3 | 19.6 |
| 4,000, with 400 obstacles and the rule `avoid` | 15.3 | 16.2 |
| 6,000 | 15.6 | 17.8 |
| 12,000 | 7.5 | 8.7 |

The row with obstacles is `mix run examples/speed.exs 4000 15 400`:
obstacles of radius 1 at random places, and each boid also has the rule
`avoid`. A boid reads only the obstacles near it, so an obstacle far
from the boids costs almost nothing. With 1,000 boids and 400 obstacles
away from them, a step of all the boids takes the same time as with no
obstacle.

- The boids make about 90,000 steps in a second, and about 105,000
  with `search => 4`. That is about 4,500 boids, or 5,000 boids, at 20
  steps in a second.
- One step of one boid takes about 20 µs of calculation. A real step
  also has the cost of a timer and of a process that starts to run.
- A boid process holds about 3 KB between two steps, and its row in the
  tables is about 1 KB.
- With too many boids for the processors, the boids make fewer steps in
  a second, and each step is longer. The node continues to answer:
  `boids:populate/3` of the 12,000 boids took 1.0 second, and
  `boids:snapshot/1` 22 ms.
- Make `cell_size` near the `perception` of the boids. Keep the `data`
  of a boid small, because each neighbor gets a copy of it.
- The numbers change with the computer and with the density of the
  boids. On a computer that other programs use, they change from run to
  run by about 10 %.

## A boid that stops

- The world is the supervisor of the boids of `boids:add/2`: they stop
  with it. It does not start a boid again after an error: the world
  removes the row of the boid, and its id is free. A boid with an error
  at each step would start again without end. `boids:whereis/2` gives
  the process of a boid, for a monitor.
- For a boid that starts again, put it below a supervisor of yours. Give
  an `id` in the options of `init/1`, so that the process that starts
  again is the same boid. The supervisor has the limit of the restarts
  that you give it:

  ```erlang
  {ok, {#{strategy => rest_for_one}, [
      boids:child_spec(#{name => my_world}),
      gen_boid:child_spec({my_world, hawk, {50, 50}})
  ]}}
  ```

- A process that starts again with the id of its last process gets its
  row again, also before the world saw the end of the old process.
  That is true for a `gen_boid` and for a process with `boids:join/2`.
- A boid that moves to another node stops on the first node with the
  reason `{shutdown, {moved, Node}}`. That is not an error.
- Each process of a world and of a boid has a label (`proc_lib`), so
  the observer and a crash report show which boid a process is.
- When the process of a world stops with an error, all the
  world stops. A world below a supervisor of yours starts
  again, with no boid.
- Each number of an option is 1.0e100 at most.

## The limits

- The tables of a world are local to a node. A world on several nodes
  has a part on each node (see "A world on several nodes").
- An obstacle is a circle or a sphere, and a force keeps the boids
  away from it (the rule `avoid`): it is not a hard limit. A wall is a
  blocked cell of a grid, which is a hard limit (see "The walls of a
  world"). There are no polygons: a shape that is not made of cells
  becomes cells when the grid is made (`boids_grid:new/1` with a
  function).
- A grid has two dimensions: a world of three dimensions has no walls,
  and no fields of directions.
- A field of directions (see "The ways of a world") is for a grid of
  some hundred cells on each side: a field of 1,000 x 1,000 cells takes
  more than one second. There are no tiles for very large maps, and no
  repair of a field after a small change of the grid: a new field is a
  new calculation.
- A field does not know where the boids are. The boids of two
  directions go on the same shortest way, and they are in the way of
  each other in a narrow place.
- The world does not move a boid when a grid changes. A boid in a cell
  that became blocked goes to the nearest walkable place at its next
  step: with `tick => manual`, at the next `boids:step/2`.
- The rule `follow` does not use `wrap`.
- The steps of the boids are not at the same moment, except with
  `boids:step/2`.
- The size of the vectors of the first boid (two numbers, or three)
  stays for the life of the world.

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

- the tests on Erlang/OTP 29;
- `rebar3 compile`, `rebar3 xref` and `rebar3 dialyzer`;
- the tests with [beam.com](https://github.com/sntran/BEAM.com) as the
  only tool;
- the tests of the site, and the build of its file for Cloudflare
  Workers.

## License

Apache License 2.0. See [`LICENSE`](LICENSE).
