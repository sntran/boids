-module(boids).
-moduledoc """
Flocks of boids, with one Erlang process for each boid.

An environment is where boids are, and where they see their neighbors: a
box, obstacles, a scale of the time, and the boids. A boid is a process
that senses, decides and acts: it finds its neighbors, calculates the
force of its rules, and moves. The rules are the three rules of a flock
(separation, alignment and cohesion), and the steering rules (seek,
flee, arrive, pursue, evade, wander, avoid, contain, follow and others).
See `boids_boid` for the options of a boid and of each rule.

```erlang
{ok, Environment} = boids:start_environment(#{bounds => {{0, 0}, {100, 100}}, wrap => true}),
{ok, _Ids} = boids:populate(Environment, 50, #{}),
timer:sleep(1000),
[#{id := _, pos := _, vel := _} | _] = boids:snapshot(Environment).
```

In Elixir, the module is `:boids`:

```elixir
{:ok, environment} = :boids.start_environment(bounds: {{0, 0}, {100, 100}}, wrap: true)
{:ok, _ids} = :boids.populate(environment, 50, max_speed: 12.0)
```

## The parts

- An environment (`start_environment/1`, or `child_spec/1` for your
  supervisor) has ETS tables with one row for each boid, and a grid of
  cells as the index.
- A boid is a process with the behavior `gen_boid`. At each tick of its
  own clock it reads its neighbors, calculates its force, moves and
  writes its row. It sends no message. A module of yours tells what the
  boid perceives, what it decides and what it does at each step, and how
  it answers messages.
- A boid of `add/2` or `populate/3` is a `gen_boid` with no module of
  yours, below the supervisor of the environment.
- A process with another behavior can be a boid too: `join/2` adds its
  row, and `advance/3` makes one step. The environment removes the row
  when the process stops.
- Each process reads the environment with `snapshot/1`, `lookup/2` and
  `near/3`, with no message to a boid.
- The boids of an environment can have relations (`relate/4`): a boid
  follows a leader, or fears an enemy.
- A flock is a group of boids that see each other. No process makes a
  flock: it comes from the rules of the boids. `flocks/2` gives the
  flocks of an environment, and `graph/2` gives the environment as a
  graph of the boids that see each other.

A function with an environment accepts the process of the environment,
its name, or its space: the map of `space/1`. With the map, a read sends
no message at all.

## The time

A boid moves in real time, each `tick` milliseconds of its own clock.
`set_time_scale/2` makes the time of the environment faster or slower,
or stops it. With `tick => manual`, the boids move only with `step/2`:
each boid calculates its step from the same state of the environment,
and then they all move. With a seed for each boid, such a run always
gives the same result.

## The units

The library has no unit of length. A speed is in units for each second,
and a force is in units for each second for each second.
""".

-export([start_environment/0, start_environment/1, stop_environment/1, child_spec/1, space/1]).
-export([add/2, populate/3, remove/2, update/3, boid/2, whereis/2]).
-export([add_rule/3, delete_rule/3, which_rules/2]).
-export([snapshot/1, lookup/2, near/3, count/1]).
-export([set_obstacle/4, remove_obstacle/2, obstacles/1, set_time_scale/2]).
-export([step/2]).
-export([graph/2, flocks/2, relate/4, unrelate/4, relations/1, related/3, related_to/3]).
-export([join/2, sense/2, plan/3, plan/4, commit/2, advance/3, leave/2]).

-export_type([environment/0, options/0]).

-type vec() :: boids_vec:vec().
-type environment() :: boids_environment:server() | boids_space:space().
-type options() :: map() | [{atom(), term()}].

%% --- The environments ------------------------------------------------

-doc #{equiv => start_environment(#{})}.
-spec start_environment() -> {ok, pid()} | {error, term()}.
start_environment() ->
    start_environment(#{}).

-doc """
Start an environment below the supervisor of the application `boids`.
The result has the process of the environment.

The options:

- `name`: a name for the process of the environment: an atom, `{global,
  Term}` or `{via, Module, Term}`.
- `bounds`: `{Min, Max}`, the box of the environment. The rule `contain`
  and `populate/3` use it.
- `wrap`: `true` when each side of the box continues at the opposite
  side (default: `false`). It needs `bounds`.
- `cell_size`: the side of a cell of the grid (default: `10.0`). The
  best value is near the `perception` of the boids.
- `defaults`: options for each boid of the environment, as a map.
- `relations`: `cyclic` (the default) or `acyclic`: with `acyclic`, the
  relations between the boids cannot make a cycle (`relate/4`).

A bad option gives `{error, {bad_option, {Key, Value}}}`.
""".
-spec start_environment(options()) -> {ok, pid()} | {error, term()}.
start_environment(Opts0) ->
    try boids_environment:options(Opts0) of
        Opts ->
            case supervisor:start_child(boids_sup, [Opts]) of
                {ok, Sup} -> {ok, server_of(Sup)};
                {error, {shutdown, {failed_to_start_child, boids_environment, Reason}}} -> {error, Reason}
            end
    catch
        error:{bad_option, _} = Reason -> {error, Reason}
    end.

server_of(Sup) ->
    [Server] = [Pid || {boids_environment, Pid, _, _} <- supervisor:which_children(Sup)],
    Server.

-doc """
Stop an environment of `start_environment/1`, with its boids. For an
environment that is stopped, the result is `{error, not_found}`. It is
the same for an environment below your supervisor: stop it there.
""".
-spec stop_environment(environment()) -> ok | {error, not_found}.
stop_environment(Environment) ->
    try boids_environment:sup(maps:get(owner, space(Environment))) of
        Sup ->
            case supervisor:terminate_child(boids_sup, Sup) of
                ok -> ok;
                {error, _} -> {error, not_found}
            end
    catch
        exit:{noproc, _} -> {error, not_found}
    end.

-doc """
The specification of an environment as a child of your supervisor. The
options are those of `start_environment/1`. Give a `name`, so that your
code can find the environment.

```erlang
{ok, {#{}, [boids:child_spec(#{name => my_environment})]}}
```

In Elixir, the child is `{:boids, name: :my_environment}`.
""".
-spec child_spec(options()) -> supervisor:child_spec().
child_spec(Opts0) ->
    Opts = boids_environment:options(Opts0),
    #{
        id => {boids, maps:get(name, Opts, undefined)},
        start => {boids_environment_sup, start_link, [Opts]},
        type => supervisor
    }.

-doc """
The space of an environment: the map with its tables (`boids_space`). A
process that reads the environment many times keeps the map, and gives
it to the functions of this module as the environment: a read then sends
no message.
""".
-spec space(environment()) -> boids_space:space().
space(Space) when is_map(Space) -> Space;
space(Server) -> boids_environment:space(Server).

%% --- The boids -------------------------------------------------------

-doc """
Add a boid to an environment: start its process. The result has the id
of the boid. The id is the option `id`, or the pid of the process.

The options are those of a boid (`boids_boid`) and of its process
(`gen_boid`), on top of the `defaults` of the environment. `pos` is
necessary.

All the boids of an environment have positions of the same size: two
numbers, or three. An id that is in the environment gives `{error,
{exists, Id}}`. A bad option gives `{error, {bad_option, {Key,
Value}}}`.

A boid that stops with an error does not start again: the environment
removes it, and the other boids continue. `whereis/2` gives its process,
for a monitor.
""".
-spec add(environment(), options()) -> {ok, term()} | {error, term()}.
add(Environment, Opts0) ->
    Space = space(Environment),
    try boids_boid:to_map(Opts0) of
        Opts -> start(Space, boids_environment:boid_sup(Space), Opts)
    catch
        error:{bad_option, _} = Reason -> {error, Reason}
    end.

%% A boid with no module of the user. Its process checks the options.
start(Space = #{defaults := Defaults}, Sup, Opts) ->
    case gen_boid:start_child(Sup, Space, undefined, Opts, #{}) of
        {ok, Pid} -> {ok, maps:get(id, maps:merge(Defaults, Opts), Pid)};
        {error, Reason} -> {error, Reason}
    end.

-doc """
Add `Count` boids at random positions. The result has their ids.

The options are those of `add/2`, and `area`: `{Min, Max}`, the box of
the positions (default: the `bounds` of the environment). Without `vel`,
each boid gets a random direction, and a random speed between its
`min_speed` and its `max_speed`. With `seed`, the boid number N gets the
seed `seed + N`.
""".
-spec populate(environment(), non_neg_integer(), options()) -> {ok, [term()]} | {error, term()}.
populate(Environment, Count, Opts0) when is_integer(Count), Count >= 0 ->
    Space = #{defaults := Defaults, bounds := Bounds} = space(Environment),
    try
        Opts = boids_boid:to_map(Opts0),
        Area = {Min, _} = area(maps:get(area, Opts, Bounds)),
        Template = maps:without([area, id], maps:merge(Defaults, Opts)),
        {_Server, BoidOpts} = gen_boid:options(Template),
        {Area, Template, boids_boid:new(BoidOpts#{pos => Min})}
    of
        {{Min1, Max1}, Template1, Sample} ->
            Random = fun() -> random(Min1, Max1, Template1, Sample) end,
            populate(Space, boids_environment:boid_sup(Space), 1, Count, Template1, Random, [])
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
Remove a boid from its environment: stop its process. This is for a boid
of `add/2`, `populate/3` and `gen_boid:start/3`. For another id, the
result is `{error, not_found}`: a process of yours with `join/2`, or a
boid below a supervisor of yours (`gen_boid:start_link/3`).
""".
-spec remove(environment(), term()) -> ok | {error, not_found}.
remove(Environment, Id) ->
    Space = space(Environment),
    case boids_space:owner(Space, Id) of
        {server, Pid} ->
            %% A boid below a supervisor of the user is not a child
            %% here.
            case supervisor:terminate_child(boids_environment:boid_sup(Space), Pid) of
                ok -> boids_environment:leave(Space, Id, Pid);
                {error, not_found} -> {error, not_found}
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
-spec update(environment(), term(), options()) -> ok | {error, term()}.
update(Environment, Id, Changes) ->
    change(Environment, Id, update, Changes).

-doc """
Add a rule at the end of the rules of a boid: `{Name, Weight}` or
`{Name, Weight, Options}`. The boid has the rule from its next step.

```erlang
ok = boids:add_rule(Environment, Id, {{seek, home}, 2.0, #{target => {0, 0}}}),
ok = boids:delete_rule(Environment, Id, {seek, home}).
```
""".
-spec add_rule(environment(), term(), boids_boid:rule()) -> ok | {error, term()}.
add_rule(Environment, Id, Rule) ->
    change(Environment, Id, add_rule, Rule).

-doc "Remove the first rule with the name `Name` from a boid. A boid with no such rule does not change.".
-spec delete_rule(environment(), term(), boids_boid:name()) -> ok | {error, not_found}.
delete_rule(Environment, Id, Name) ->
    change(Environment, Id, delete_rule, Name).

-doc "The names of the rules of a boid, in their order.".
-spec which_rules(environment(), term()) -> {ok, [boids_boid:name()]} | {error, not_found}.
which_rules(Environment, Id) ->
    case boid(Environment, Id) of
        {ok, Boid} -> {ok, boids_boid:which_rules(Boid)};
        {error, not_found} -> {error, not_found}
    end.

change(Environment, Id, Function, Arg) ->
    Space = space(Environment),
    case boids_space:owner(Space, Id) of
        {server, Pid} -> call(Pid, {change, Function, Arg});
        _ -> {error, not_found}
    end.

-doc """
All the state of a boid, from its process. See `t:boids_boid:boid/0`.
""".
-spec boid(environment(), term()) -> {ok, boids_boid:boid()} | {error, not_found}.
boid(Environment, Id) ->
    Space = space(Environment),
    case boids_space:owner(Space, Id) of
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
environment.
""".
-spec whereis(environment(), term()) -> pid() | undefined.
whereis(Environment, Id) ->
    case boids_space:lookup(space(Environment), Id) of
        {ok, #{pid := Pid}} -> Pid;
        error -> undefined
    end.

%% --- The view of an environment --------------------------------------

-doc """
All the boids of an environment: a list of maps with `id`, `pos`, `vel`,
`group`, `data` and `pid`. The order is not specified. The boids move
during the read, so the rows are not all of the same moment.
""".
-spec snapshot(environment()) -> [boids_space:entry()].
snapshot(Environment) ->
    boids_space:all(space(Environment)).

-doc "One boid of an environment: its row, as in `snapshot/1`.".
-spec lookup(environment(), term()) -> {ok, boids_space:entry()} | error.
lookup(Environment, Id) ->
    boids_space:lookup(space(Environment), Id).

-doc """
The boids at the distance `Radius` or less from a point, in the order of
their distance. Each is a map with `id`, `pos`, `vel`, `group`, `data`,
`offset` (the vector from the point to the boid) and `dist`.
""".
-spec near(environment(), vec(), number()) -> [boids_space:neighbor()].
near(Environment, Pos, Radius) ->
    boids_space:near(space(Environment), Pos, Radius).

-doc "The number of boids of an environment.".
-spec count(environment()) -> non_neg_integer().
count(Environment) ->
    boids_space:count(space(Environment)).

%% --- The obstacles and the time of an environment --------------------

-doc """
Add an obstacle to an environment, or change it: a circle (a sphere in
3D) with the center `Pos`. The boids with the rule `avoid` move around
it. Call this function again to move the obstacle.
""".
-spec set_obstacle(environment(), term(), vec(), number()) -> ok.
set_obstacle(Environment, Id, Pos, Radius) ->
    boids_space:set_obstacle(space(Environment), Id, Pos, Radius).

-doc "Remove an obstacle from an environment.".
-spec remove_obstacle(environment(), term()) -> ok.
remove_obstacle(Environment, Id) ->
    boids_space:remove_obstacle(space(Environment), Id).

-doc "The obstacles of an environment: a list of maps with `id`, `pos` and `radius`.".
-spec obstacles(environment()) -> [boids_space:obstacle()].
obstacles(Environment) ->
    boids_space:obstacles(space(Environment)).

-doc """
Set the scale of the time of an environment: the seconds of the boids
for each second of the clock. With 0, the boids stop. The default is
1.0.
""".
-spec set_time_scale(environment(), number()) -> ok.
set_time_scale(Environment, Scale) ->
    boids_space:set_time_scale(space(Environment), Scale).

%% --- The time --------------------------------------------------------

-doc """
Make one step of `Dt` seconds for all the boids that are a `gen_boid`:
those of `add/2` too. First each boid calculates its step, and the
environment does not change. Then each boid moves. The function returns
after the two parts.

The scale of the time of the environment applies to `Dt`. Use it with
boids that have `tick => manual`: for a test, or for a simulation that
is faster than the clock.
""".
-spec step(environment(), number()) -> ok.
step(Environment, Dt) when is_number(Dt), Dt >= 0 ->
    Pids = boids_space:servers(space(Environment)),
    request(Pids, {plan, Dt}),
    request(Pids, commit).

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

%% --- The flocks, and the environment as a graph ----------------------

-doc """
The flocks of an environment: the groups of boids that see each other.
Each flock is a list of ids. Two boids are in one flock when a chain of
boids goes from one to the other, each at the distance `Radius` or less
from the next. A boid with no boid near it is a flock of one.

```erlang
Flocks = boids:flocks(Environment, 10),
Largest = lists:max([length(Flock) || Flock <- Flocks]).
```

No process makes a flock: the flocks come from the rules of the boids.
This function reads all the environment, as `graph/2`.
""".
-spec flocks(environment(), number()) -> [[term()]].
flocks(Environment, Radius) ->
    graph:components(graph(Environment, Radius)).

-doc """
The environment as a graph (`graph`) of the boids that see each other.
Each boid is a vertex: its id, with its row as the label. An edge goes
from a boid to each boid at the distance `Radius` or less.

The functions of `graph` then answer questions about all the
environment:

```erlang
Graph = boids:graph(Environment, 10),
Alone = [Id || Id <- graph:vertices(Graph), graph:out_degree(Graph, Id) =:= 0],
Path = graph:get_path(Graph, BoidA, BoidB).
```

The build reads all the environment: it takes 50 to 200 microseconds for
each boid. Use it for a view of the environment, and not at each step of
a boid.
""".
-spec graph(environment(), number()) -> graph:graph().
graph(Environment, Radius) ->
    Space = space(Environment),
    Rows = snapshot(Space),
    Vertices = lists:foldl(fun(Row = #{id := Id}, Graph) -> graph:add_vertex(Graph, Id, Row) end, graph:new(), Rows),
    lists:foldl(
        fun(#{id := Id, pos := Pos}, Graph0) ->
            %% A boid that came after the read of the rows is not a
            %% vertex.
            Others = [Other || #{id := Other} <- near(Space, Pos, Radius), Other =/= Id, graph:has_vertex(Graph0, Other)],
            lists:foldl(fun(Other, Graph) -> graph:add_edge(Graph, Id, Other) end, Graph0, Others)
        end,
        Vertices,
        Rows
    ).

-doc """
Add a relation between two boids of an environment: the boid `From` has
the relation `Label` to the boid `To`. A label is a term of yours, for
example `follows`, `fears` or `mate`.

```erlang
ok = boids:relate(Environment, Bird, follows, Leader),
ok = boids:update(Environment, Bird, #{rules => [{leader, 1.0, #{target => {related, follows}}}]}).
```

A rule with the target `{related, Label}` uses the relation at each
step. The relation goes when one of the two boids goes from the
environment.

The result is `{error, {not_found, Id}}` for an id that is not in the
environment. In an environment with the option `relations => acyclic`, a
relation that makes a cycle gives `{error, cycle}`: use it for a
hierarchy.
""".
-spec relate(environment(), term(), term(), term()) -> ok | {error, {not_found, term()} | cycle}.
relate(Environment, From, Label, To) ->
    boids_environment:relate(space(Environment), From, Label, To).

-doc "Remove a relation of `relate/4`.".
-spec unrelate(environment(), term(), term(), term()) -> ok.
unrelate(Environment, From, Label, To) ->
    boids_environment:unrelate(space(Environment), From, Label, To).

-doc """
All the relations of an environment, as a graph (`graph`): each boid
with a relation is a vertex, and each relation is an edge `{From, To,
Label}`.

```erlang
Relations = boids:relations(Environment),
Chain = graph:get_path(Relations, Bird, TopLeader),
Order = graph:topsort(Relations).
```

Two boids can have relations with different labels. `graph` then gives
a neighbor one time for each label: for the boids of one label, use
`related/3` and `related_to/3`.
""".
-spec relations(environment()) -> graph:graph().
relations(Environment) ->
    boids_environment:relations(space(Environment)).

-doc """
The boids that the boid `From` has the relation `Label` to. The read
sends no message.
""".
-spec related(environment(), term(), term()) -> [term()].
related(Environment, From, Label) ->
    boids_space:related(space(Environment), From, Label).

-doc """
The boids that have the relation `Label` to the boid `To`: for example
the followers of a leader. The read sends no message.
""".
-spec related_to(environment(), term(), term()) -> [term()].
related_to(Environment, To, Label) ->
    boids_space:related_to(space(Environment), To, Label).

%% --- A process of your own as a boid ---------------------------------

-doc """
Make the process that calls this function a boid of an environment. The
result has the space of the environment (the map of `space/1`) and the
boid (`t:boids_boid:boid/0`). Keep the two in the state of the process,
and call `advance/3` at each step.

The options are those of a boid (`boids_boid`), on top of the `defaults`
of the environment. The default id is the pid of the process. The
environment removes the boid when the process stops. The options of the
process of a `gen_boid` (`tick`, `search` and the others) have no effect
here: the process has its own clock.

```erlang
init(Environment) ->
    {ok, Space, Boid} = boids:join(Environment, #{pos => {0, 0}, vel => {1, 0}}),
    erlang:send_after(50, self(), tick),
    {ok, {Space, Boid}}.

handle_info(tick, {Space, Boid}) ->
    erlang:send_after(50, self(), tick),
    {noreply, {Space, boids:advance(Space, Boid, 0.05)}}.
```
""".
-spec join(environment(), options()) -> {ok, boids_space:space(), boids_boid:boid()} | {error, term()}.
join(Environment, Opts0) ->
    Space = #{defaults := Defaults} = space(Environment),
    try
        {_Server, BoidOpts} = gen_boid:options(maps:merge(Defaults, boids_boid:to_map(Opts0))),
        boids_boid:new(maps:merge(#{id => self()}, BoidOpts))
    of
        Boid ->
            case boids_environment:join(Space, self(), boids_boid:entry(Boid)) of
                ok -> {ok, Space, Boid};
                {error, Reason} -> {error, Reason}
            end
    catch
        error:{bad_option, _} = Reason -> {error, Reason}
    end.

-doc """
Calculate one step of `Dt` seconds for a boid: read its neighbors,
calculate the force of its rules, and move. The result is the new boid.
The environment does not change before `commit/2`. The scale of the time
of the environment applies to `Dt`.
""".
-spec plan(boids_space:space(), boids_boid:boid(), number()) -> boids_boid:boid().
plan(Space, Boid, Dt) ->
    plan(Space, Boid, sense(Space, Boid), Dt).

-doc "The neighbors that a boid sees now in its environment, the nearest first.".
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
Write a boid to its environment, so that the other boids see its new
position. Call it after `plan/3`, or after a change of the boid with
`boids_boid:update/2`.
""".
-spec commit(boids_space:space(), boids_boid:boid()) -> ok.
commit(Space, Boid) ->
    _ = boids_space:put(Space, Boid),
    ok.

-doc "One step of a boid: `plan/3`, then `commit/2`. The result is the new boid.".
-spec advance(boids_space:space(), boids_boid:boid(), number()) -> boids_boid:boid().
advance(Space, Boid0, Dt) ->
    Boid = plan(Space, Boid0, Dt),
    commit(Space, Boid),
    Boid.

-doc "Remove a boid of `join/2` from its environment. The process of the boid calls this function.".
-spec leave(boids_space:space(), boids_boid:boid()) -> ok.
leave(Space, #{id := Id}) ->
    boids_environment:leave(Space, Id, self()).
