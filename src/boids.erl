-module(boids).
-moduledoc """
Flocks of boids, with one Erlang process for each boid.

A world is where boids are, and where they see their neighbors: a
box, obstacles, a scale of the time, and the boids. A boid is a process
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
-export([add/2, populate/3, remove/2, update/3, boid/2, whereis/2, nodes/1]).
-export([add_rule/3, delete_rule/3, which_rules/2]).
-export([snapshot/1, snapshot/2, lookup/2, near/3, count/1, count/2]).
-export([set_obstacle/4, remove_obstacle/2, obstacles/1, set_time_scale/2]).
-export([step/2, step/3, part/2]).
-export([graph/2, graph/3, flocks/2, flocks/3, relate/4, unrelate/4, relations/1, related/3, related_to/3]).
-export([join/2, sense/2, plan/3, plan/4, commit/2, advance/3, leave/2]).

-export_type([world/0, options/0]).

-type vec() :: boids_vec:vec().
-type world() :: boids_world:server() | boids_space:space().
-type options() :: map() | [{atom(), term()}].

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
            Random = fun() -> random(Min1, Max1, Template1, Sample) end,
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
    case start(Space, Sup, maps:merge(Opts, Random())) of
        {ok, Id} -> populate(Space, Sup, N + 1, Count, Template, Random, [Id | Ids]);
        {error, Reason} -> {error, Reason}
    end.

area({Min, Max}) when tuple_size(Min) =:= tuple_size(Max), tuple_size(Min) =:= 2 orelse tuple_size(Min) =:= 3 ->
    {Min, Max};
area(Area) ->
    error({bad_option, {area, Area}}).

random(Min, Max, Template, #{min_speed := Slow, max_speed := Fast}) ->
    Pos = boids_vec:random_in(Min, Max),
    case Template of
        #{vel := _} ->
            #{pos => Pos};
        _ ->
            Speed = Slow + rand:uniform() * (Fast - Slow),
            #{pos => Pos, vel => boids_vec:scale(boids_vec:random_unit(tuple_size(Min)), Speed)}
    end.

-doc """
Remove a boid from its world: stop its process. This is for a boid
of `add/2`, `populate/3` and `gen_boid:start/3`. For another id, the
result is `{error, not_found}`: a process of yours with `join/2`, or a
boid below a supervisor of yours (`gen_boid:start_link/3`). In a world
on several nodes, the node of the boid removes it.
""".
-spec remove(world(), term()) -> ok | {error, not_found}.
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
            try
                erpc:call(node(Pid), ?MODULE, remove, [maps:get(name, Space), Id], 5000)
            catch
                _:_ -> {error, not_found}
            end;
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
-spec delete_rule(world(), term(), boids_boid:name()) -> ok | {error, not_found}.
delete_rule(World, Id, Name) ->
    change(World, Id, delete_rule, Name).

-doc "The names of the rules of a boid, in their order.".
-spec which_rules(world(), term()) -> {ok, [boids_boid:name()]} | {error, not_found}.
which_rules(World, Id) ->
    case boid(World, Id) of
        {ok, Boid} -> {ok, boids_boid:which_rules(Boid)};
        {error, not_found} -> {error, not_found}
    end.

change(World, Id, Function, Arg) ->
    Space = space(World),
    case boids_world:find(Space, Id) of
        {server, Pid} -> call(Pid, {change, Function, Arg});
        _ -> {error, not_found}
    end.

-doc """
All the state of a boid, from its process. See `t:boids_boid:boid/0`.
""".
-spec boid(world(), term()) -> {ok, boids_boid:boid()} | {error, not_found}.
boid(World, Id) ->
    Space = space(World),
    case boids_world:find(Space, Id) of
        {server, Pid} ->
            case call(Pid, get) of
                {error, not_found} -> {error, not_found};
                Boid -> {ok, Boid}
            end;
        _ ->
            {error, not_found}
    end.

%% A request to a gen_boid, which can stop before its answer.
call(Pid, Request) ->
    try
        gen_server:call(Pid, Request)
    catch
        exit:{Reason, _} when Reason =:= noproc; Reason =:= normal; Reason =:= shutdown ->
            {error, not_found}
    end.

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
        error -> undefined
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
`group`, `data` and `pid`. The order is not specified. The boids move
during the read, so the rows are not all of the same moment.

For a world on several nodes, the result has the boids of all the nodes.
`snapshot(World, local)` gives the boids of this node only.
""".
-spec snapshot(world()) -> [boids_space:entry()].
snapshot(World) ->
    Space = space(World),
    lists:append([boids_space:all(Space) | everywhere(Space, snapshot, [])]).

-doc "The boids of a world that are on this node: see `snapshot/1`.".
-spec snapshot(world(), local) -> [boids_space:entry()].
snapshot(World, local) ->
    boids_space:all(space(World)).

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
""".
-spec set_obstacle(world(), term(), vec(), number()) -> ok.
set_obstacle(World, Id, Pos, Radius) ->
    boids_space:set_obstacle(space(World), Id, Pos, Radius).

-doc "Remove an obstacle from a world.".
-spec remove_obstacle(world(), term()) -> ok.
remove_obstacle(World, Id) ->
    boids_space:remove_obstacle(space(World), Id).

-doc "The obstacles of a world: a list of maps with `id`, `pos` and `radius`.".
-spec obstacles(world()) -> [boids_space:obstacle()].
obstacles(World) ->
    boids_space:obstacles(space(World)).

-doc """
Set the scale of the time of a world: the seconds of the boids
for each second of the clock. With 0, the boids stop. The default is
1.0.
""".
-spec set_time_scale(world(), number()) -> ok.
set_time_scale(World, Scale) ->
    boids_space:set_time_scale(space(World), Scale).

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
only.
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
    Sent = lists:foldl(
        fun(Pid, Acc) -> gen_server:send_request(Pid, Request, Pid, Acc) end,
        gen_server:reqids_new(),
        Pids
    ),
    collect(Sent).

collect(Sent) ->
    case gen_server:receive_response(Sent, infinity, true) of
        {_Response, _Pid, Rest} -> collect(Rest);
        no_request -> ok
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
-spec relate(world(), term(), term(), term()) -> ok | {error, {not_found, term()} | cycle}.
relate(World, From, Label, To) ->
    Space = space(World),
    case {boids_world:find(Space, From), boids_world:find(Space, To)} of
        {error, _} ->
            {error, {not_found, From}};
        {_, error} ->
            {error, {not_found, To}};
        {{_Kind, Pid}, {_, Other}} when node(Pid) =:= node() ->
            %% The world of this node checks a boid of this node again:
            %% that boid can go before the world gets this call.
            boids_world:relate(Space, From, Label, To, node(Other) =/= node());
        {{_Kind, Pid}, _} ->
            %% The relation is on the node of the boid that has it.
            erpc:call(node(Pid), ?MODULE, relate, [maps:get(name, Space), From, Label, To], 5000)
    end.

-doc "Remove a relation of `relate/4`, on the node of the boid `From`.".
-spec unrelate(world(), term(), term(), term()) -> ok.
unrelate(World, From, Label, To) ->
    Space = space(World),
    case boids_world:find(Space, From) of
        {_Kind, Pid} when node(Pid) =/= node() ->
            %% The relation is on the node of the boid that has it.
            erpc:call(node(Pid), ?MODULE, unrelate, [maps:get(name, Space), From, Label, To], 5000);
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
here: the process has its own clock.

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
plan(Space, Boid, Neighbors, Dt) ->
    Env = #{time_scale := Scale} = boids_space:env(Space),
    Lookup = fun(Id) -> boids_space:lookup(Space, Id) end,
    Related = fun(From, Label) -> boids_space:related(Space, From, Label) end,
    boids_boid:step(Boid, Neighbors, Env#{lookup => Lookup, related => Related}, Dt * Scale).

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
    boids_world:leave(Space, Id, self()).
