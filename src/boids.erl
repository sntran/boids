-module(boids).
-moduledoc """
Flocks of boids, with one Erlang process for each boid.

A world is where boids are, and where they see their neighbors: a
box, obstacles, walls, a scale of the time, and the boids. A boid is a process
that senses, decides and acts: it finds its neighbors, calculates the
force of its rules, and moves. The rules are the three rules of a flock
(separation, alignment and cohesion), and the steering rules (seek,
flee, arrive, pursue, evade, wander, avoid, contain, follow and others).
See `boids_boid` for the options of a boid and of each rule.

```erlang
{ok, World} = boids:start_world(#{bounds => {{0, 0}, {100, 100}}, wrap => true}),
{ok, _Ids} = boids:populate(World, 50, #{}),
timer:sleep(1000),
[#{id := _, pos := _, vel := _} | _] = boids:snapshot(World).
```

In Elixir, the module is `:boids`:

```elixir
{:ok, world} = :boids.start_world(bounds: {{0, 0}, {100, 100}}, wrap: true)
{:ok, _ids} = :boids.populate(world, 50, max_speed: 12.0)
```

## The parts

- A world (`start_world/1`, or `child_spec/1` for your
  supervisor) has ETS tables with one row for each boid, and a grid of
  cells as the index.
- A boid is a process with the behavior `gen_boid`. At each tick of its
  own clock it reads its neighbors, calculates its force, moves and
  writes its row. It sends no message. A module of yours tells what the
  boid perceives, what it decides and what it does at each step, and how
  it answers messages.
- A boid of `add/2` or `populate/3` is a `gen_boid` with no module of
  yours, below the supervisor of the world.
- A process with another behavior can be a boid too: `join/2` adds its
  row, and `advance/3` makes one step. The world removes the row
  when the process stops.
- Each process reads the world with `snapshot/1`, `lookup/2` and
  `near/3`, with no message to a boid.
- The boids of a world can have relations (`relate/4`): a boid
  follows a leader, or fears an enemy.
- A world with a name can be on several nodes (`nodes/1`). Each node
  has a part of the world, and a boid is a process on the node of its
  place: it moves to another node when it crosses a border. The
  functions of this module are about the boids of all the nodes.
- A flock is a group of boids that see each other. No process makes a
  flock: it comes from the rules of the boids. `flocks/2` gives the
  flocks of a world, and `graph/2` gives the world as a
  graph of the boids that see each other.
- `export/1` saves a world as one term: its boids with all their state,
  their relations, and the facts of the world. `import/2` loads that
  term into a world.

A function with a world accepts the process of the world,
its name, or its space: the map of `space/1`. With the map, a read sends
no message at all.

## The time

A boid moves in real time, each `tick` milliseconds of its own clock.
`set_time_scale/2` makes the time of the world faster or slower,
or stops it. With `tick => manual`, the boids move only with `step/2`:
each boid calculates its step from the same state of the world,
and then they all move. With a seed for each boid, such a run always
gives the same result.

## The units

The library has no unit of length. A speed is in units for each second,
and a force is in units for each second for each second.
""".

-export([start_world/0, start_world/1, stop_world/1, child_spec/1, space/1]).
-export([add/2, populate/3, remove/2, update/3, boid/2, whereis/2, nodes/1, timeout/0, mark_time/0]).
-export([add_rule/3, delete_rule/3, which_rules/2]).
-export([snapshot/1, snapshot/2, ordered/2, lookup/2, near/3, count/1, count/2]).
-export([set_obstacle/4, remove_obstacle/2, obstacles/1, set_time_scale/2]).
-export([set_grid/3, remove_grid/2, grid/2, set_field/3, remove_field/2, field/2]).
-export([step/2, step/3, part/2]).
-export([export/1, export/2, import/2, saved/2]).
-export([graph/2, graph/3, flocks/2, flocks/3, relate/4, unrelate/4, relations/1, related/3, related_to/3]).
-export([join/2, sense/2, plan/3, plan/4, commit/2, advance/3, leave/2]).

-export_type([world/0, options/0, export/0, saved/0]).

-type vec() :: boids_vec:vec().
-type world() :: boids_world:server() | boids_space:space().
-type options() :: map() | [{atom(), term()}].
-type export() :: #{
    format := pos_integer(),
    boids := [saved()],
    facts := [{term(), term(), {pos_integer(), node()}}],
    not_saved := [{Id :: term(), Reason :: term()}],
    can_fail := [{Id :: term(), {function, function()} | {live, pid() | port() | reference()}}]
}.
-type saved() :: #{
    boid := boids_boid:boid(),
    mod := module() | undefined,
    vsn := term(),
    server := map(),
    relations := [{Label :: term(), [Id :: term()]}],
    rand := term(),
    known := [Id :: term()],
    steps := non_neg_integer()
}.

%% The number of the format of an export.
-define(FORMAT, 1).

%% The random positions that populate/3 tries for one boid, to find a
%% place where the boid can walk.
-define(SPOTS, 1000).

%% --- The worlds ------------------------------------------------

-doc #{equiv => start_world(#{})}.
-spec start_world() -> {ok, pid()} | {error, term()}.
start_world() ->
    start_world(#{}).

-doc """
Start a world below the supervisor of the application `boids`.
The result has the process of the world.

The options:

- `name`: a name for the process of the world: an atom, `{global,
  Term}` or `{via, Module, Term}`. With an atom, the worlds with that
  name and the same options on the connected nodes are one world
  (`nodes/1`).
- `bounds`: `{Min, Max}`, the box of the world. The rule `contain`
  and `populate/3` use it.
- `wrap`: `true` when each side of the box continues at the opposite
  side (default: `false`). It needs `bounds`.
- `cell_size`: the side of a cell of the grid (default: `10.0`). The
  best value is near the `perception` of the boids.
- `defaults`: options for each boid of the world, as a map.
- `relations`: `cyclic` (the default) or `acyclic`: with `acyclic`, the
  relations between the boids of a node cannot make a cycle
  (`relate/4`).
- `tile`: the side of a tile of the world (default: 16 cells). In a
  world on several nodes, each tile is on one node. Make it much larger
  than the `perception` of the boids.

A bad option gives `{error, {bad_option, {Key, Value}}}`.
""".
-spec start_world(options()) -> {ok, pid()} | {error, term()}.
start_world(Opts0) ->
    try boids_world:options(Opts0) of
        Opts ->
            case supervisor:start_child(boids_worlds, [Opts]) of
                {ok, Sup} -> {ok, server_of(Sup)};
                {error, {shutdown, {failed_to_start_child, boids_world, Reason}}} -> {error, Reason}
            end
    catch
        error:{bad_option, _} = Reason -> {error, Reason}
    end.

server_of(Sup) ->
    [Server] = [Pid || {boids_world, Pid, _, _} <- supervisor:which_children(Sup)],
    Server.

-doc """
Stop a world of `start_world/1`, with its boids. For a
world that is stopped, the result is `{error, not_found}`. It is
the same for a world below your supervisor: stop it there.
""".
-spec stop_world(world()) -> ok | {error, not_found}.
stop_world(World) ->
    try boids_world:sup(maps:get(owner, space(World))) of
        Sup ->
            case supervisor:terminate_child(boids_worlds, Sup) of
                ok -> ok;
                {error, _} -> {error, not_found}
            end
    catch
        exit:{noproc, _} -> {error, not_found}
    end.

-doc """
The specification of a world as a child of your supervisor. The
options are those of `start_world/1`. Give a `name`, so that your
code can find the world.

```erlang
{ok, {#{}, [boids:child_spec(#{name => my_world})]}}
```

In Elixir, the child is `{:boids, name: :my_world}`.
""".
-spec child_spec(options()) -> supervisor:child_spec().
child_spec(Opts0) ->
    Opts = boids_world:options(Opts0),
    #{
        id => {boids, maps:get(name, Opts, undefined)},
        start => {boids_world_sup, start_link, [Opts]},
        type => supervisor
    }.

-doc """
The space of a world: the map with its tables (`boids_space`). A
process that reads the world many times keeps the map, and gives
it to the functions of this module as the world: a read then sends
no message.
""".
-spec space(world()) -> boids_space:space().
space(Space) when is_map(Space) -> Space;
space(Server) -> boids_world:space(Server).

%% --- The boids -------------------------------------------------------

-doc """
Add a boid to a world: start its process. The result has the id
of the boid. The id is the option `id`, or a new reference. It is not
the process of the boid, which changes when the boid moves to another
node: `whereis/2` gives the process.

The options are those of a boid (`boids_boid`) and of its process
(`gen_boid`), on top of the `defaults` of the world. `pos` is
necessary.

All the boids of a world have positions of the same size: two
numbers, or three. An id that is in the world gives `{error,
{exists, Id}}`. A bad option gives `{error, {bad_option, {Key,
Value}}}`.

A boid that stops with an error does not start again: the world
removes it, and the other boids continue. `whereis/2` gives its process,
for a monitor.
""".
-spec add(world(), options()) -> {ok, term()} | {error, term()}.
add(World, Opts0) ->
    Space = space(World),
    try boids_boid:to_map(Opts0) of
        Opts -> start(Space, boids_world:boid_sup(Space), Opts)
    catch
        error:{bad_option, _} = Reason -> {error, Reason}
    end.

%% A boid with no module of the user. Its process checks the options.
start(Space = #{defaults := Defaults}, Sup, Opts) ->
    %% The id is not the process: a boid can move to another node.
    Id = maps:get(id, maps:merge(Defaults, Opts), make_ref()),
    case gen_boid:start_child(Sup, Space, undefined, Opts#{id => Id}, #{}) of
        {ok, _Pid} -> {ok, Id};
        {error, Reason} -> {error, Reason}
    end.

-doc """
Add `Count` boids at random positions. The result has their ids.

The options are those of `add/2`, and `area`: `{Min, Max}`, the box of
the positions (default: the `bounds` of the world). Without `vel`,
each boid gets a random direction, and a random speed between its
`min_speed` and its `max_speed`. With `seed`, the boid number N gets the
seed `seed + N`.

With the option `walkable` (`boids_boid`), each position is a place
where the boid can walk: an open cell of its grid. When 1,000 random
positions of the area give no such place, the result is `{error,
{not_walkable, Area}}`.
""".
-spec populate(world(), non_neg_integer(), options()) -> {ok, [term()]} | {error, term()}.
populate(World, Count, Opts0) when is_integer(Count), Count >= 0 ->
    Space = #{defaults := Defaults, bounds := Bounds} = space(World),
    try
        Opts = boids_boid:to_map(Opts0),
        Area = {Min, _} = area(maps:get(area, Opts, Bounds)),
        Template = maps:without([area, id], maps:merge(Defaults, Opts)),
        {_Server, BoidOpts} = gen_boid:options(Template),
        {Area, Template, boids_boid:new(BoidOpts#{pos => Min})}
    of
        {{Min1, Max1}, Template1, Sample} ->
            Grid = limit(Space, Sample),
            Random = fun() -> random(Min1, Max1, Template1, Sample, Grid) end,
            populate(Space, boids_world:boid_sup(Space), 1, Count, Template1, Random, [])
    catch
        error:{bad_option, _} = Reason -> {error, Reason}
    end.

%% The check of the options is done one time, for all the boids.
populate(_Space, _Sup, N, Count, _Template, _Random, Ids) when N > Count ->
    {ok, lists:reverse(Ids)};
populate(Space, Sup, N, Count, Template, Random, Ids) ->
    Opts =
        case Template of
            #{seed := Seed} -> Template#{seed := Seed + N};
            _ -> Template
        end,
    maybe
        {ok, Place} ?= Random(),
        {ok, Id} ?= start(Space, Sup, maps:merge(Opts, Place)),
        populate(Space, Sup, N + 1, Count, Template, Random, [Id | Ids])
    end.

area({Min, Max}) when tuple_size(Min) =:= tuple_size(Max), tuple_size(Min) =:= 2 orelse tuple_size(Min) =:= 3 ->
    {Min, Max};
area(Area) ->
    error({bad_option, {area, Area}}).

%% The grid that limits a boid in a world, or none.
limit(Space, #{walkable := {named, Name}}) ->
    case boids_space:grid(Space, Name) of
        {ok, Grid} -> Grid;
        error -> none
    end;
limit(_Space, _Boid) ->
    none.

random(Min, Max, Template, #{min_speed := Slow, max_speed := Fast}, Grid) ->
    maybe
        {ok, Pos} ?= spot(Min, Max, Grid, ?SPOTS),
        case Template of
            #{vel := _} ->
                {ok, #{pos => Pos}};
            _ ->
                Speed = Slow + rand:uniform() * (Fast - Slow),
                {ok, #{pos => Pos, vel => boids_vec:scale(boids_vec:random_unit(tuple_size(Min)), Speed)}}
        end
    end.

%% A random position where the boid can walk, in Tries tries at most.
spot(Min, Max, Grid, Tries) ->
    Pos = boids_vec:random_in(Min, Max),
    case Grid =:= none orelse boids_grid:walkable(Grid, Pos) of
        true -> {ok, Pos};
        false when Tries > 1 -> spot(Min, Max, Grid, Tries - 1);
        false -> {error, {not_walkable, {Min, Max}}}
    end.

-doc """
Remove a boid from its world: stop its process. This is for a boid
of `add/2`, `populate/3` and `gen_boid:start/3`. For another id, the
result is `{error, not_found}`: a process of yours with `join/2`, or a
boid below a supervisor of yours (`gen_boid:start_link/3`). In a world
on several nodes, the node of the boid removes it.
""".
-spec remove(world(), term()) -> ok | {error, not_found | timeout}.
remove(World, Id) ->
    Space = space(World),
    case boids_world:find(Space, Id) of
        {server, Pid} when node(Pid) =:= node() ->
            %% A boid below a supervisor of the user is not a child
            %% here.
            case supervisor:terminate_child(boids_world:boid_sup(Space), Pid) of
                ok -> boids_world:leave(Space, Id, Pid);
                {error, not_found} -> {error, not_found}
            end;
        {server, Pid} ->
            %% The boid is on another node: that node removes it.
            remote(node(Pid), remove, [maps:get(name, Space), Id], {error, not_found});
        timeout ->
            {error, timeout};
        _ ->
            {error, not_found}
    end.

-doc """
Change options of a boid: for example its `rules`, its `max_speed` or
its `pos`. The id and the options of the process (`tick`, `max_dt`,
`seed`) do not change. For a process of yours with `join/2`, the result
is `{error, not_found}`.
""".
-spec update(world(), term(), options()) -> ok | {error, term()}.
update(World, Id, Changes) ->
    change(World, Id, update, Changes).

-doc """
Add a rule at the end of the rules of a boid: `{Name, Weight}` or
`{Name, Weight, Options}`. The boid has the rule from its next step.

```erlang
ok = boids:add_rule(World, Id, {{seek, home}, 2.0, #{target => {0, 0}}}),
ok = boids:delete_rule(World, Id, {seek, home}).
```
""".
-spec add_rule(world(), term(), boids_boid:rule()) -> ok | {error, term()}.
add_rule(World, Id, Rule) ->
    change(World, Id, add_rule, Rule).

-doc "Remove the first rule with the name `Name` from a boid. A boid with no such rule does not change.".
-spec delete_rule(world(), term(), boids_boid:name()) -> ok | {error, not_found | timeout}.
delete_rule(World, Id, Name) ->
    change(World, Id, delete_rule, Name).

-doc "The names of the rules of a boid, in their order.".
-spec which_rules(world(), term()) -> {ok, [boids_boid:name()]} | {error, not_found | timeout}.
which_rules(World, Id) ->
    case boid(World, Id) of
        {ok, Boid} -> {ok, boids_boid:which_rules(Boid)};
        {error, Reason} -> {error, Reason}
    end.

change(World, Id, Function, Arg) ->
    Space = space(World),
    case boids_world:find(Space, Id) of
        {server, Pid} -> call(Pid, {change, Function, Arg});
        timeout -> {error, timeout};
        _ -> {error, not_found}
    end.

-doc """
All the state of a boid, from its process. See `t:boids_boid:boid/0`.
""".
-spec boid(world(), term()) -> {ok, boids_boid:boid()} | {error, not_found | timeout}.
boid(World, Id) ->
    Space = space(World),
    case boids_world:find(Space, Id) of
        {server, Pid} ->
            case call(Pid, get) of
                {error, Reason} -> {error, Reason};
                Boid -> {ok, Boid}
            end;
        timeout ->
            {error, timeout};
        _ ->
            {error, not_found}
    end.

%% A request to a gen_boid, on this node or on another node. The boid
%% can stop before its answer: then it is not found. With no answer in
%% the time limit, the result is {error, timeout}.
call(Pid, Request) ->
    try
        gen_server:call(Pid, Request, timeout())
    catch
        exit:{timeout, _} -> {error, timeout};
        exit:_ -> {error, not_found}
    end.

%% A call of a function of this module on the node of a boid. With no
%% answer in the time limit, the result is {error, timeout}. With no
%% connection to the node, the result is `Missing`.
remote(Node, Function, Args, Missing) ->
    try
        erpc:call(Node, ?MODULE, Function, Args, timeout())
    catch
        error:{erpc, timeout} -> {error, timeout};
        _:_ -> Missing
    end.

-doc """
The time limit of a call to a boid, or to another node of a world, in
milliseconds: the value `timeout` of the application `boids`, or 5000.
A function that gets no answer in this time gives `{error, timeout}`,
and `whereis/2` gives `undefined`. The result `timeout` does not tell
that the call had no effect: a node that is slow can do the work later.

```erlang
ok = application:set_env(boids, timeout, 1000).
```
""".
-spec timeout() -> pos_integer().
timeout() ->
    application:get_env(boids, timeout, 5000).

-doc """
The time that a node of a world keeps the mark of a fact that was
removed (an obstacle, for example), in milliseconds: the value
`mark_time` of the application `boids`, or 600000 (10 minutes). The
value can be `infinity`.

The mark stops an older change of that fact, which a node with no
connection can have: with the mark, the fact stays removed when that
node has a connection again. The time has two limits:

- A node that has no connection for more than this time can bring back
  a fact that the other nodes removed in that time. Use a time longer
  than the longest split of your network.
- A node keeps one mark for each fact that was removed in this time. A
  longer time keeps more marks. A node gives all its marks to a node
  that comes to the world.

With `infinity`, a node never drops a mark: a removed fact stays
removed after a split of each length, and the marks have no limit. Use
it when the world removes few facts, or when it does not run for a long
time.

```erlang
ok = application:set_env(boids, mark_time, 3600000).
```
""".
-spec mark_time() -> pos_integer() | infinity.
mark_time() ->
    application:get_env(boids, mark_time, 600000).

-doc """
The process of a boid, or `undefined` for an id that is not in the
world. In a world on several nodes, the process can be on another
node. The process of a boid changes when the boid moves to another
node: ask again for it then.
""".
-spec whereis(world(), term()) -> pid() | undefined.
whereis(World, Id) ->
    case boids_world:find(space(World), Id) of
        {_Kind, Pid} -> Pid;
        _ -> undefined
    end.

-doc """
The nodes that have a part of a world. A world with a name (an atom) is
one world on all the connected nodes that started a world with that
name and the same options. Each node has a part of the tiles of the
world, and a boid is a process on the node of its tile: it moves to
another node when it crosses a border.
""".
-spec nodes(world()) -> [node()].
nodes(World) ->
    boids_space:nodes(space(World)).

%% --- The view of a world --------------------------------------

-doc """
All the boids of a world: a list of maps with `id`, `pos`, `vel`,
`group`, `data` and `pid`. The boids move during the read, so the rows
are not all of the same moment.

The boids are in the order in which they came to the world, and the
place of a boid in the order does not change: it is the same after each
step, and after a move of the boid to another node. Thus two runs that
add the same boids in the same sequence give them in the same order,
also when an id is a reference. The world gives a number to each boid
that comes, which adds no work to a step. This function sorts the rows
by that number: the sort takes less than 1 microsecond for each boid.

For a world on several nodes, the result has the boids of all the nodes.
Each node gives its numbers: the order is the number, then the name of
the node where the boid came to the world, then the id. Thus the order
is the order in which the boids came only for the boids of one node.
`snapshot(World, local)` gives the boids of this node only, in the same
order.
""".
-spec snapshot(world()) -> [boids_space:entry()].
snapshot(World) ->
    Space = space(World),
    case everywhere(Space, ordered, []) of
        [] ->
            boids_space:all(Space);
        Others ->
            %% A boid that moves to another node at this moment can be in
            %% the rows of the two nodes: keep one row for each id.
            Rows = lists:append([boids_space:ordered(Space) | Others]),
            [Entry || {_, _, _, _, Entry} <- lists:sort(maps:values(#{Id => Row || Row = {_, _, Id, _, _} <- Rows}))]
    end.

-doc "The boids of a world that are on this node: see `snapshot/1`.".
-spec snapshot(world(), local) -> [boids_space:entry()].
snapshot(World, local) ->
    boids_space:all(space(World)).

-doc false.
%% The boids of this node, each with its order: for snapshot/1 on another
%% node.
ordered(World, local) ->
    boids_space:ordered(space(World)).

%% The results of a function of this module with the last argument local,
%% on the other nodes of a world. A node that has no connection at that
%% moment gives no result. With one node, no message goes to a node.
everywhere(Space, Function, Args) ->
    case {Space, boids_space:nodes(Space) -- [node()]} of
        {#{name := Name}, Nodes = [_ | _]} ->
            [Result || {ok, Result} <- erpc:multicall(Nodes, ?MODULE, Function, [Name | Args] ++ [local], infinity)];
        _ ->
            []
    end.

-doc """
One boid of a world: its row, as in `snapshot/1`. The read is of this
node: it gives a boid of this node, and a boid of another node that is
near a border of this node. `whereis/2` and `boid/2` find a boid on each
node.
""".
-spec lookup(world(), term()) -> {ok, boids_space:entry()} | error.
lookup(World, Id) ->
    boids_space:lookup(space(World), Id).

-doc """
The boids at the distance `Radius` or less from a point, in the order of
their distance. Each is a map with `id`, `pos`, `vel`, `group`, `data`,
`offset` (the vector from the point to the boid) and `dist`.

The read is of this node, as the read of a boid that looks for its
neighbors: it gives the boids of this node, and the boids of another
node that are near a border of this node.
""".
-spec near(world(), vec(), number()) -> [boids_space:neighbor()].
near(World, Pos, Radius) ->
    boids_space:near(space(World), Pos, Radius).

-doc """
The number of boids of a world, on all its nodes. `count(World, local)`
gives the number of boids of this node.
""".
-spec count(world()) -> non_neg_integer().
count(World) ->
    Space = space(World),
    lists:sum([boids_space:count(Space) | everywhere(Space, count, [])]).

-doc "The number of boids of a world that are on this node.".
-spec count(world(), local) -> non_neg_integer().
count(World, local) ->
    boids_space:count(space(World)).

%% --- The obstacles and the time of a world --------------------

-doc """
Add an obstacle to a world, or change it: a circle (a sphere in
3D) with the center `Pos`. The boids with the rule `avoid` move around
it. Call this function again to move the obstacle.

The process of the world writes the obstacle: this function sends it
one message, and waits for its answer. A center or a radius that is not
good gives the error `badarg`.

The obstacles, the scale of the time, the grids and the fields are the
facts of a world. In a world on several nodes, a change of a fact is
for all the nodes (`set_obstacle/4`, `remove_obstacle/2`,
`set_time_scale/2`, `set_grid/3`, `remove_grid/2`, `set_field/3`,
`remove_field/2`):

- When the result is `ok`, each node that has a connection to this node
  has the change.
- A node that gives no answer in the time limit (`timeout/0`) makes the
  result `{error, timeout}`. This node has the change, and that node
  gets it later.
- A node with no connection, and a node that comes later, gets all the
  facts when it has a connection.
- When two nodes changed one fact (during a split of the network, for
  example), the last change wins on all the nodes: the last in time,
  when the clocks of the computers agree. When the clocks do not agree,
  all the nodes get one value too, which can be the change of the
  computer with the clock that is ahead. Each change has a counter (the
  time of the system in microseconds, or more: a counter of a node is
  always larger than each counter that the node knows). With the same
  counter, the change of the node with the larger name wins.
- A fact that was removed stays removed: an older change of another
  node does not bring it back (see `mark_time/0` for the limit).
""".
-spec set_obstacle(world(), term(), vec(), number()) -> ok | {error, timeout}.
set_obstacle(World, Id, Pos, Radius) ->
    set(World, {obstacle, Id}, {Pos, Radius}).

-doc "Remove an obstacle from a world, on all its nodes: see `set_obstacle/4`.".
-spec remove_obstacle(world(), term()) -> ok | {error, timeout}.
remove_obstacle(World, Id) ->
    set(World, {obstacle, Id}, none).

%% Change a fact of a world. A bad value is an error of the caller.
set(World, Key, Value) ->
    case boids_world:set(World, Key, Value) of
        {error, badarg} -> error(badarg);
        Result -> Result
    end.

-doc """
Give the name `Name` to a grid (`boids_grid`): the places of the world
where a boid can walk, and where it cannot. A boid with the option
`walkable => {named, Name}` does not go into a blocked cell of this
grid (`boids_boid`). A world can have many grids, each with its name:
walls for people, water for cars.

Call the function again to change the grid: a door that opens or closes
is a new grid for the same name (`boids_grid:set_cost/3`). All the
boids with that name use the new grid at their next step. A boid that
is then in a blocked cell goes to the nearest walkable place at its
next step.

The process of the world writes the grid, as for `set_obstacle/4`. A
value that is not a grid gives the error `badarg`.

A grid is a fact of the world: in a world on several nodes, the change
is for all the nodes, and the result can be `{error, timeout}` (see
`set_obstacle/4`). A boid that moves to another node finds the same
walls there. The function sends the grid to each node: a grid of 200 x
200 cells is 320 KB.
""".
-spec set_grid(world(), term(), boids_grid:grid()) -> ok | {error, timeout}.
set_grid(World, Name, Grid) ->
    set(World, {grid, Name}, Grid).

-doc """
Remove the grid with the name `Name` from a world, on all its nodes: see
`set_grid/3`. The boids with that name have no limit.
""".
-spec remove_grid(world(), term()) -> ok | {error, timeout}.
remove_grid(World, Name) ->
    set(World, {grid, Name}, none).

-doc """
The grid with the name `Name` of a world: `{ok, Grid}`, or `error`. The
function reads the tables of this node with no message: each node of a
world has all the grids.
""".
-spec grid(world(), term()) -> {ok, boids_grid:grid()} | error.
grid(World, Name) ->
    boids_space:grid(space(World), Name).

-doc """
Give the name `Name` to a field of directions (`boids_field`): for each
place, the direction of the shortest way to a goal. A boid with the
rule `{flow, Weight, #{field => {named, Name}}}` goes that way. A world
can have many fields, each with its name: one for each goal of its
boids.

```erlang
Grid = boids_grid:from_rows(["....#....", "....#....", "........."], #{}),
ok = boids:set_grid(World, land, Grid),
ok = boids:set_field(World, exit, boids_field:new(Grid, [{8, 0}])),
{ok, _} = boids:populate(World, 20, #{
    area => {{0, 0}, {4, 3}},
    walkable => {named, land},
    rules => [{flow, 1.0, #{field => {named, exit}}}, {separation, 1.5}]
}).
```

There is one copy of a field for all the boids of a node: a boid keeps
the field that it read, and reads it again only after a change. Call
the function again to change the field: after a change of the walls or
of the goals, make a new field (`boids_field:new/2`) and give it the
same name. All the boids with that name use the new field at their
next step. The calculation of a field is not in the process of the
world: `boids_field:new/2` runs in the process that calls it.

The process of the world writes the field, as for `set_obstacle/4`. A
value that is not a field gives the error `badarg`. A name with no
field gives no force.

A field is a fact of the world: in a world on several nodes, the change
is for all the nodes, and the result can be `{error, timeout}` (see
`set_obstacle/4`). A boid that moves to another node finds the same
field there, and goes on to its goal. The function sends the field to
each node: a field of 200 x 200 cells is 234 KB.
""".
-spec set_field(world(), term(), boids_field:field()) -> ok | {error, timeout}.
set_field(World, Name, Field) ->
    set(World, {field, Name}, Field).

-doc """
Remove the field with the name `Name` from a world, on all its nodes:
see `set_field/3`. The rule `flow` with that name gives no force.
""".
-spec remove_field(world(), term()) -> ok | {error, timeout}.
remove_field(World, Name) ->
    set(World, {field, Name}, none).

-doc """
The field with the name `Name` of a world: `{ok, Field}`, or `error`. The
function reads the tables of this node with no message: each node of a
world has all the fields.
""".
-spec field(world(), term()) -> {ok, boids_field:field()} | error.
field(World, Name) ->
    boids_space:field(space(World), Name).

-doc """
All the obstacles of a world, in the order of their ids: a list of maps
with `id`, `pos` and `radius`. A boid gets only the obstacles near it
(`boids_boid:reach/1`).

This function reads the tables of this node with no message. Each node
of a world has all the obstacles, so there is no function for the
obstacles of one node.
""".
-spec obstacles(world()) -> [boids_space:obstacle()].
obstacles(World) ->
    boids_space:obstacles(space(World)).

-doc """
Set the scale of the time of a world: the seconds of the boids
for each second of the clock. With 0, the boids stop. The default is
1.0. The process of the world writes it, on all the nodes of the world,
as for `set_obstacle/4`. A scale that is not a number from 0 to 1.0e100
gives the error `badarg`.
""".
-spec set_time_scale(world(), number()) -> ok | {error, timeout}.
set_time_scale(World, Scale) ->
    set(World, time_scale, Scale).

%% --- The time --------------------------------------------------------

-doc """
Make one step of `Dt` seconds for all the boids that are a `gen_boid`:
those of `add/2` too. First each boid calculates its step, and the
world does not change. Then each boid moves. The function returns
after the two parts.

The scale of the time of the world applies to `Dt`. Use it with
boids that have `tick => manual`: for a test, or for a simulation that
is faster than the clock.

For a world on several nodes, the step is for the boids of all the
nodes: each node makes the first part, then each node makes the second
part. `step(World, Dt, local)` makes a step for the boids of this node
only. The step does not wait for a node that has no connection: the
other nodes make the step.
""".
-spec step(world(), number()) -> ok.
step(World, Dt) when is_number(Dt), Dt >= 0 ->
    Space = space(World),
    case {Space, boids_space:nodes(Space)} of
        {#{name := Name}, Nodes = [_, _ | _]} ->
            _ = erpc:multicall(Nodes, ?MODULE, part, [Name, {plan, Dt}], infinity),
            _ = erpc:multicall(Nodes, ?MODULE, part, [Name, commit], infinity),
            ok;
        _ ->
            step(Space, Dt, local)
    end.

-doc "Make one step for the boids of a world that are on this node: see `step/2`.".
-spec step(world(), number(), local) -> ok.
step(World, Dt, local) when is_number(Dt), Dt >= 0 ->
    part(World, {plan, Dt}),
    part(World, commit).

-doc false.
%% One part of a step, for the boids of this node.
part(World, Request) ->
    request(boids_space:servers(space(World)), Request).

%% The two parts of a step are in specs/Step.tla. A boid that stops
%% during the step gives an error, which changes nothing for the other
%% boids. The answers come in each order: the caller takes them as they
%% come, with no search in its messages.
request(Pids, Request) ->
    collect(send(Pids, Request)).

%% Each process gets the request before the caller reads an answer.
send(Pids, Request) ->
    lists:foldl(
        fun(Pid, Acc) -> gen_server:send_request(Pid, Request, Pid, Acc) end,
        gen_server:reqids_new(),
        Pids
    ).

collect(Sent) ->
    case gen_server:receive_response(Sent, infinity, true) of
        {_Response, _Pid, Rest} -> collect(Rest);
        no_request -> ok
    end.

%% --- Save and load ---------------------------------------------------

-doc """
Save a world: all that a new world needs to continue as this world, as
one term. `import/2` gives the term to a world.

```erlang
ok = file:write_file("world.save", term_to_binary(boids:export(World))),
{ok, Binary} = file:read_file("world.save"),
{ok, #{not_started := []}} = boids:import(New, binary_to_term(Binary)).
```

The term is a map:

- `format`: the number of the format of the term: 1.
- `boids`: the boids, in the order of `snapshot/1`. Each has its module
  and the version of its module, its boid (the id, the position, the
  rules, the key `state` and all the other keys), its relations, the
  options of its process, the state of its random numbers and the
  neighbors that it knows. This is what a boid takes to another node.
- `facts`: the facts of the world with their versions, as
  `boids_world:facts/1` gives them: the obstacles, the grids, the
  fields and the scale of the time.
- `not_saved`: the boids that are not in the export, each with the
  reason: a list of `{Id, Reason}`.
- `can_fail`: the boids that are in the export and that can fail after a
  load, each with the reason: a list of `{Id, Reason}`.

The export does not have the options of the world (`start_world/1`):
start the new world with them. It has only terms: `term_to_binary/1`
makes a binary of it.

## What is not in the export

| Reason | The boid |
|---|---|
| `process` | A process of yours with `join/2`. The library cannot start your process. Start it again: it joins the new world. |
| `supervised` | A boid below a supervisor of yours (`gen_boid:start_link/3`). Your supervisor starts it, with `init/1`. |
| another term | The boid stopped during the export: the term is the reason of its end. |

The relations of these boids are not in the export. The name of the
process of a boid (the option `name` of `gen_boid:start/4`) is not in
the export.

## What can fail after a load

| Reason | The boid |
|---|---|
| `{function, Fun}` | The boid has an anonymous function: a rule, or a term in its state or its data. |
| `{live, Term}` | The boid has a pid, a port or a reference that is not the id of a boid, and its module has no `handle_load/2`. |

An anonymous function (`fun(...) -> ... end`) is a part of the code of
its module. After a load, Erlang can call it only when the node has the
code that made it: the same version of that module. With another
version of the module, the term is a function, and a call fails with
`badfun`. Thus `import/2` starts such a boid only on a node that has the
same code of the module. After one change of a module, a node keeps the
code before the change as the old code of the module, and Erlang can
call the function in it. `import/2` does not start the boid then: the
old code goes at the next change. A function with a name (`fun
Module:Function/Arity`) always loads: use it for a rule of a boid that
you save.

A pid, a port, a timer, a monitor and a table of ETS stop with their
process or their node: after a load, the state of the boid has only an
old name. `handle_load/2` of the module of the boid makes them again
(`gen_boid`).

## The moment of an export

All the boids get the request before the first answer. Each boid answers
between two of its steps: an export never has a boid in the middle of a
step.

- The export is exact (all the boids at one moment) when no boid makes
  a step during the export: the boids have `tick => manual`, and no
  process calls `step/2`.
- In a world with a clock, each boid answers at its own moment: one boid
  can be one step after another boid. With the scale of the time 0, no
  boid moves: the positions and the velocities are of one moment.
- A step that a boid calculated and did not make (the first part of
  `step/2`) is not in the export.

For a world on several nodes, the export has the boids of all the nodes
that have a connection, and the facts of this node. A boid that moves to
another node during the export can be absent, or in `not_saved`.
`export(World, local)` has the boids of this node only.
""".
-spec export(world()) -> export().
export(World) ->
    Space = space(World),
    pack(Space, lists:append([saved(Space, local) | everywhere(Space, saved, [])]), #{}).

-doc "Save the boids of a world that are on this node, and the facts of the world: see `export/1`.".
-spec export(world(), local) -> export().
export(World, local) ->
    Space = space(World),
    %% A reference in a boid of this node can be the id of a boid of
    %% another node.
    pack(Space, saved(Space, local), #{Id => [] || #{id := Id} <- snapshot(Space)}).

-doc false.
%% The boids of this node for an export, each with its order: what a new
%% process needs to continue as the boid, or the reason why an export
%% cannot have the boid.
saved(World, local) ->
    Space = space(World),
    Rows = boids_space:ordered(Space),
    Answers = answers(send([Pid || {_, _, _, server, #{pid := Pid}} <- Rows], save), #{}),
    [{Number, Node, Id, saved(Kind, Pid, Answers)} || {Number, Node, Id, Kind, #{pid := Pid}} <- Rows].

answers(Sent, Answers) ->
    case gen_server:receive_response(Sent, infinity, true) of
        {Answer, Pid, Rest} -> answers(Rest, Answers#{Pid => Answer});
        no_request -> Answers
    end.

%% The library cannot start a process of the user (join/2).
saved(process, _Pid, _Answers) -> {error, process};
saved(server, Pid, Answers) -> answer(map_get(Pid, Answers)).

%% The answer of a gen_boid to the request save. A boid that stopped
%% before its answer gives {error, {Reason, Pid}}, with the reason of
%% its end. A boid below a supervisor of the user answers with an error
%% of the same form.
answer({reply, Answer}) -> answer(Answer);
answer({ok, Saved}) -> {ok, Saved};
answer({error, {Reason, _Pid}}) -> {error, Reason}.

%% The export of the rows of saved/2. `Others` has the ids of the boids
%% of the world that are not in the rows.
pack(Space, Rows0, Others) ->
    %% A boid that moves to another node at this moment can be in the
    %% rows of the two nodes, and one of the two can be the row of a
    %% process that stopped. Keep one row for each id: the row that has
    %% the boid, when there is one.
    Failed = #{Id => Row || Row = {_, _, Id, {error, _}} <- Rows0},
    Rows = lists:sort(maps:values(maps:merge(Failed, #{Id => Row || Row = {_, _, Id, {ok, _}} <- Rows0}))),
    Boids = [Saved || {_, _, _, {ok, Saved}} <- Rows],
    Ids = maps:merge(Others, #{Id => [] || {_, _, Id, _} <- Rows}),
    #{
        format => ?FORMAT,
        boids => Boids,
        facts => boids_world:facts(Space),
        not_saved => [{Id, Reason} || {_, _, Id, {error, Reason}} <- Rows],
        can_fail => lists:append([doubts(Saved, Ids) || Saved <- Boids])
    }.

%% What can fail after a load of a saved boid. `Ids` has the ids of the
%% boids of the world: an id can be a reference or a pid.
doubts(#{boid := Boid = #{id := Id}, mod := Module}, Ids) ->
    Special = lists:usort(special(Boid, [])),
    %% handle_load/2 of the module makes again what the state needs.
    Remakes =
        Module =/= undefined andalso code:ensure_loaded(Module) =:= {module, Module} andalso
            erlang:function_exported(Module, handle_load, 2),
    [{Id, {function, Fun}} || Fun <- Special, is_function(Fun), erlang:fun_info(Fun, type) =:= {type, local}] ++
        [{Id, {live, Term}} || not Remakes, Term <- Special, not is_function(Term), not is_map_key(Term, Ids)].

%% The functions, the pids, the ports and the references in a term: what
%% needs code after a load, and what a save cannot keep alive.
special(Fun, Acc) when is_function(Fun) ->
    %% A function also has the terms that it keeps from the code that
    %% made it.
    {env, Kept} = erlang:fun_info(Fun, env),
    special(Kept, [Fun | Acc]);
special(Term, Acc) when is_pid(Term); is_port(Term); is_reference(Term) ->
    [Term | Acc];
special([Head | Tail], Acc) ->
    special(Tail, special(Head, Acc));
special(Tuple, Acc) when is_tuple(Tuple) ->
    special(tuple_to_list(Tuple), Acc);
special(Map, Acc) when is_map(Map) ->
    maps:fold(fun(Key, Value, Found) -> special(Value, special(Key, Found)) end, Acc, Map);
special(_Term, Acc) ->
    Acc.

-doc """
Load a save into a world: start again each boid of an export of
`export/1`, and give the facts of the export to the world.

1. The facts come first, with their versions, as the facts of a node
   that comes to the world (`boids_world:merge/2`). In a world on
   several nodes, all the nodes get them. A fact that the world changed
   after the save stays as the world has it.
2. Then each boid starts, below the supervisor of the world of this
   node, with its module, its id and all its state. `init/1` of its
   module does not run. `handle_load/2` runs when the module has it
   (`gen_boid`): it can change the state of an older save, and make
   again what the state needs.
3. The relations come last.

The boids start one after the other, in the order of the export:
`snapshot/1` gives them in that order, after the boids that the world
had. In a world on several nodes, a boid moves to the node of its place
at its first step, as a boid of `add/2`.

The result is `{ok, Result}`, with a map:

- `started`: the ids of the boids that started.
- `not_started`: `{Id, Reason}` for each boid that did not start.
- `not_related`: `{{From, Label, To}, Reason}` for each relation of a
  boid that started that the world refused (`relate/4`): for example
  `{not_found, To}` when the boid `To` is not in the world.
- `facts`: `ok`, or `{error, timeout}` when a node gave no answer in the
  time limit (`timeout/0`).

| Reason | The boid did not start |
|---|---|
| `{exists, Id}` | The world has a boid with this id, on this node or on another node. That boid stays as it is. |
| `{no_module, Module}` | The node cannot load the module of the boid. |
| `{function, Fun}` | The node cannot call a function of the boid: an anonymous function of another version of its module, or a function of a module that the node does not have. |
| `{bad_option, {pos, Pos}}` | The positions of the world have another size: two numbers, or three. |
| another term | `handle_load/2` gave `{stop, Reason}`. |

An export with another number of format gives `{error, {format,
Number}}`, and the world does not change.

In a world with a clock, each boid starts its clock when it starts: the
first boid moves before the last boid starts. For a start of all the
boids at one moment, set the scale of the time to 0 before the import
(`set_time_scale/2`), and to its value after it.

Read only a binary that you made: `binary_to_term/1` of a binary of
another person can make atoms without limit, and a function in it is
code that the boid calls.
""".
-spec import(world(), export()) ->
    {ok, #{
        started := [Id :: term()],
        not_started := [{Id :: term(), Reason :: term()}],
        not_related := [{{From :: term(), Label :: term(), To :: term()}, Reason :: term()}],
        facts := ok | {error, badarg | timeout}
    }}
    | {error, {format, term()}}.
import(World, #{format := ?FORMAT, boids := Boids, facts := Facts}) ->
    Space = space(World),
    %% The facts come first: a boid that starts finds its grid and its
    %% field.
    Learned = boids_world:merge(Space, Facts),
    %% The ids of the boids of the other nodes of the world: the world of
    %% this node knows only its own boids.
    Taken = #{Id => [] || {_, _, Id, _, _} <- lists:append(everywhere(Space, ordered, []))},
    Results = [
        {Id, Relations, load(Space, Saved, Taken)}
     || Saved = #{boid := #{id := Id}, relations := Relations} <- Boids
    ],
    %% The relations come after all the boids: a relation needs its two
    %% boids.
    NotRelated = [
        {{From, Label, To}, Reason}
     || {From, Relations, {ok, _Pid}} <- Results,
        {Label, Others} <- Relations,
        To <- Others,
        {error, Reason} <- [relate(Space, From, Label, To)]
    ],
    {ok, #{
        started => [Id || {Id, _Relations, {ok, _Pid}} <- Results],
        not_started => [{Id, Reason} || {Id, _Relations, {error, Reason}} <- Results],
        not_related => NotRelated,
        facts => Learned
    }};
import(_World, #{format := Format}) ->
    {error, {format, Format}}.

%% Start a saved boid, when no other node has a boid with its id, and
%% this node can call each function that the boid has.
load(_Space, #{boid := #{id := Id}}, Taken) when is_map_key(Id, Taken) ->
    {error, {exists, Id}};
load(Space, Saved = #{boid := Boid}, _Taken) ->
    case [Fun || Fun <- special(Boid, []), is_function(Fun), not callable(Fun)] of
        [] -> gen_boid:load(Space, Saved);
        [Fun | _] -> {error, {function, Fun}}
    end.

%% Erlang can call a function from a binary when the node has its code.
%% A function with a name needs its module and its function. An
%% anonymous function needs the code that made it: new_uniq is the MD5
%% of that code. The node can also have that code as the old code of the
%% module, after a change of the module: that does not last, so it is not
%% sufficient here.
callable(Fun) ->
    {module, Module} = erlang:fun_info(Fun, module),
    Loaded = code:ensure_loaded(Module) =:= {module, Module},
    case erlang:fun_info(Fun, type) of
        {type, external} ->
            {name, Name} = erlang:fun_info(Fun, name),
            {arity, Arity} = erlang:fun_info(Fun, arity),
            Loaded andalso erlang:function_exported(Module, Name, Arity);
        {type, local} ->
            {new_uniq, Md5} = erlang:fun_info(Fun, new_uniq),
            Loaded andalso Module:module_info(md5) =:= Md5
    end.

%% --- The flocks, and the world as a graph ----------------------

-doc """
The flocks of a world: the groups of boids that see each other.
Each flock is a list of ids. Two boids are in one flock when a chain of
boids goes from one to the other, each at the distance `Radius` or less
from the next. A boid with no boid near it is a flock of one.

```erlang
Flocks = boids:flocks(World, 10),
Largest = lists:max([length(Flock) || Flock <- Flocks]).
```

No process makes a flock: the flocks come from the rules of the boids.
This function reads all the world, as `graph/2`: for a world on several
nodes, the flocks are those of all the nodes, and a flock can be on
more than one node. `flocks(World, Radius, local)` gives the flocks of
the boids of this node.
""".
-spec flocks(world(), number()) -> [[term()]].
flocks(World, Radius) ->
    graph:components(graph(World, Radius)).

-doc "The flocks of the boids of a world that are on this node: see `flocks/2`.".
-spec flocks(world(), number(), local) -> [[term()]].
flocks(World, Radius, local) ->
    graph:components(graph(World, Radius, local)).

-doc """
The world as a graph (`graph`) of the boids that see each other.
Each boid is a vertex: its id, with its row as the label. An edge goes
from a boid to each boid at the distance `Radius` or less.

The functions of `graph` then answer questions about all the
world:

```erlang
Graph = boids:graph(World, 10),
Alone = [Id || Id <- graph:vertices(Graph), graph:out_degree(Graph, Id) =:= 0],
Path = graph:get_path(Graph, BoidA, BoidB).
```

The build reads all the world: it takes 50 to 200 microseconds for
each boid. Use it for a view of the world, and not at each step of
a boid.

For a world on several nodes, the graph has the boids of all the nodes:
this node gets their rows, and searches them in tables of its own.
`graph(World, Radius, local)` gives the graph of the boids of this
node.
""".
-spec graph(world(), number()) -> graph:graph().
graph(World, Radius) ->
    Space = space(World),
    case everywhere(Space, snapshot, []) of
        [] ->
            graph(Space, Radius, local);
        Others ->
            %% The rows of all the nodes, in tables of this process.
            Rows = lists:append([boids_space:all(Space) | Others]),
            All = boids_space:new(maps:with([cell_size, bounds, wrap, tile], Space)),
            lists:foreach(fun(Row) -> boids_space:insert_new(All, Row) end, Rows),
            Graph = edges(All, Rows, Radius),
            boids_space:delete(All),
            Graph
    end.

-doc "The graph of the boids of a world that are on this node: see `graph/2`.".
-spec graph(world(), number(), local) -> graph:graph().
graph(World, Radius, local) ->
    Space = space(World),
    edges(Space, boids_space:all(Space), Radius).

%% The graph of rows, with an edge from a boid to each boid near it in
%% the tables of a space.
edges(Space, Rows, Radius) ->
    Vertices = lists:foldl(fun(Row = #{id := Id}, Graph) -> graph:add_vertex(Graph, Id, Row) end, graph:new(), Rows),
    lists:foldl(
        fun(#{id := Id, pos := Pos}, Graph0) ->
            %% A boid that is not in the rows is not a vertex: it came
            %% after the read of the rows, or it is a boid of another
            %% node near a border.
            Near = boids_space:near(Space, Pos, Radius),
            Others = [Other || #{id := Other} <- Near, Other =/= Id, graph:has_vertex(Graph0, Other)],
            lists:foldl(fun(Other, Graph) -> graph:add_edge(Graph, Id, Other) end, Graph0, Others)
        end,
        Vertices,
        Rows
    ).

-doc """
Add a relation between two boids of a world: the boid `From` has
the relation `Label` to the boid `To`. A label is a term of yours, for
example `follows`, `fears` or `mate`.

```erlang
ok = boids:relate(World, Bird, follows, Leader),
ok = boids:update(World, Bird, #{rules => [{leader, 1.0, #{target => {related, follows}}}]}).
```

A rule with the target `{related, Label}` uses the relation at each
step. The relation goes when one of the two boids goes from the
world.

The result is `{error, {not_found, Id}}` for an id that is not in the
world. In a world with the option `relations => acyclic`, a
relation that makes a cycle gives `{error, cycle}`: use it for a
hierarchy.

In a world on several nodes, a relation is on the node of the boid
`From`, and it moves with that boid. The rule gives a force only while
the boid perceives the boid `To`: on its node, or near a border. The
option `acyclic` checks the relations of the node of the boid `From`.
""".
-spec relate(world(), term(), term(), term()) -> ok | {error, {not_found, term()} | cycle | timeout}.
relate(World, From, Label, To) ->
    Space = space(World),
    case {boids_world:find(Space, From), boids_world:find(Space, To)} of
        {error, _} ->
            {error, {not_found, From}};
        {timeout, _} ->
            {error, timeout};
        {_, error} ->
            {error, {not_found, To}};
        {_, timeout} ->
            {error, timeout};
        {{_Kind, Pid}, {_, Other}} when node(Pid) =:= node() ->
            %% The world of this node checks a boid of this node again:
            %% that boid can go before the world gets this call.
            boids_world:relate(Space, From, Label, To, node(Other) =/= node());
        {{_Kind, Pid}, _} ->
            %% The relation is on the node of the boid that has it.
            remote(node(Pid), relate, [maps:get(name, Space), From, Label, To], {error, {not_found, From}})
    end.

-doc "Remove a relation of `relate/4`, on the node of the boid `From`.".
-spec unrelate(world(), term(), term(), term()) -> ok | {error, not_found | timeout}.
unrelate(World, From, Label, To) ->
    Space = space(World),
    case boids_world:find(Space, From) of
        {_Kind, Pid} when node(Pid) =/= node() ->
            %% The relation is on the node of the boid that has it.
            remote(node(Pid), unrelate, [maps:get(name, Space), From, Label, To], {error, not_found});
        timeout ->
            {error, timeout};
        _ ->
            boids_world:unrelate(Space, From, Label, To)
    end.

-doc """
All the relations of a world, as a graph (`graph`): each boid
with a relation is a vertex, and each relation is an edge `{From, To,
Label}`.

```erlang
Relations = boids:relations(World),
Chain = graph:get_path(Relations, Bird, TopLeader),
Order = graph:topsort(Relations).
```

Two boids can have relations with different labels. `graph` then gives
a neighbor one time for each label: for the boids of one label, use
`related/3` and `related_to/3`.
""".
-spec relations(world()) -> graph:graph().
relations(World) ->
    boids_world:relations(space(World)).

-doc """
The boids that the boid `From` has the relation `Label` to. The read
sends no message.
""".
-spec related(world(), term(), term()) -> [term()].
related(World, From, Label) ->
    boids_space:related(space(World), From, Label).

-doc """
The boids that have the relation `Label` to the boid `To`: for example
the followers of a leader. The read sends no message.
""".
-spec related_to(world(), term(), term()) -> [term()].
related_to(World, To, Label) ->
    boids_space:related_to(space(World), To, Label).

%% --- A process of your own as a boid ---------------------------------

-doc """
Make the process that calls this function a boid of a world. The
result has the space of the world (the map of `space/1`) and the
boid (`t:boids_boid:boid/0`). Keep the two in the state of the process,
and call `advance/3` at each step.

The options are those of a boid (`boids_boid`), on top of the `defaults`
of the world. The default id is the pid of the process. The
world removes the boid when the process stops. The options of the
process of a `gen_boid` (`tick`, `search` and the others) have no effect
here: the process has its own clock. The steps of `plan/3` and
`advance/3` obey the option `walkable`, as the steps of a `gen_boid`.

```erlang
init(World) ->
    {ok, Space, Boid} = boids:join(World, #{pos => {0, 0}, vel => {1, 0}}),
    erlang:send_after(50, self(), tick),
    {ok, {Space, Boid}}.

handle_info(tick, {Space, Boid}) ->
    erlang:send_after(50, self(), tick),
    {noreply, {Space, boids:advance(Space, Boid, 0.05)}}.
```
""".
-spec join(world(), options()) -> {ok, boids_space:space(), boids_boid:boid()} | {error, term()}.
join(World, Opts0) ->
    Space = #{defaults := Defaults} = space(World),
    try
        {_Server, BoidOpts} = gen_boid:options(maps:merge(Defaults, boids_boid:to_map(Opts0))),
        boids_boid:new(maps:merge(#{id => self()}, BoidOpts))
    of
        Boid ->
            case boids_world:join(Space, self(), boids_boid:entry(Boid)) of
                ok -> {ok, Space, Boid};
                {error, Reason} -> {error, Reason}
            end
    catch
        error:{bad_option, _} = Reason -> {error, Reason}
    end.

-doc """
Calculate one step of `Dt` seconds for a boid: read its neighbors,
calculate the force of its rules, and move. The result is the new boid.
The world does not change before `commit/2`. The scale of the time
of the world applies to `Dt`.
""".
-spec plan(boids_space:space(), boids_boid:boid(), number()) -> boids_boid:boid().
plan(Space, Boid, Dt) ->
    plan(Space, Boid, sense(Space, Boid), Dt).

-doc "The neighbors that a boid sees now in its world, the nearest first.".
-spec sense(boids_space:space(), boids_boid:boid()) -> [boids_space:neighbor()].
sense(Space, Boid = #{pos := Pos, perception := Perception}) ->
    boids_boid:perceive(Boid, boids_space:near(Space, Pos, Perception)).

-doc """
As `plan/3`, with the neighbors of `sense/2`: for a process that looks
at its neighbors before the step.
""".
-spec plan(boids_space:space(), boids_boid:boid(), [boids_space:neighbor()], number()) -> boids_boid:boid().
plan(Space, Boid = #{pos := Pos}, Neighbors, Dt) ->
    Env = #{time_scale := Scale} = boids_space:env(Space, Pos, boids_boid:reach(Boid)),
    Lookup = fun(Id) -> boids_space:lookup(Space, Id) end,
    Related = fun(From, Label) -> boids_space:related(Space, From, Label) end,
    %% The grids and the fields that the boid uses. The process keeps
    %% them between two steps, in its process dictionary: this function
    %% has no argument for the state of the caller.
    Named = boids_space:named(Space, boids_boid:named(Boid)),
    boids_boid:step(Boid, Neighbors, maps:merge(Env#{lookup => Lookup, related => Related}, Named), Dt * Scale).

-doc """
Write a boid to its world, so that the other boids see its new
position. Call it after `plan/3`, or after a change of the boid with
`boids_boid:update/2`.
""".
-spec commit(boids_space:space(), boids_boid:boid()) -> ok.
commit(Space, Boid) ->
    _ = boids_space:put(Space, Boid),
    %% Near a border of this node, the boid shows itself to the other
    %% node.
    _ = boids_world:settle(Space, Boid),
    ok.

-doc "One step of a boid: `plan/3`, then `commit/2`. The result is the new boid.".
-spec advance(boids_space:space(), boids_boid:boid(), number()) -> boids_boid:boid().
advance(Space, Boid0, Dt) ->
    Boid = plan(Space, Boid0, Dt),
    commit(Space, Boid),
    Boid.

-doc "Remove a boid of `join/2` from its world. The process of the boid calls this function.".
-spec leave(boids_space:space(), boids_boid:boid()) -> ok.
leave(Space, #{id := Id}) ->
    boids_space:forget(Space),
    boids_world:leave(Space, Id, self()).
