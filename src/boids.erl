-module(boids).
-moduledoc """
Flocks of boids, with one Erlang process for each boid.

A flock is a space where boids see their neighbors. A boid is a process
that senses, decides and acts: it finds its neighbors, calculates the
force of its rules, and moves. The rules are the three rules of a flock
(separation, alignment and cohesion), and the steering rules (seek,
flee, arrive, pursue, evade, wander, avoid, contain, follow and others).
See `boids_boid` for the options of a boid and of each rule.

```erlang
{ok, Flock} = boids:start_flock(#{bounds => {{0, 0}, {100, 100}}, wrap => true}),
{ok, _Ids} = boids:populate(Flock, 50, #{}),
timer:sleep(1000),
[#{id := _, pos := _, vel := _} | _] = boids:snapshot(Flock).
```

In Elixir, the module is `:boids`:

```elixir
{:ok, flock} = :boids.start_flock(bounds: {{0, 0}, {100, 100}}, wrap: true)
{:ok, _ids} = :boids.populate(flock, 50, max_speed: 12.0)
```

## The parts

- A flock (`start_flock/1`, or `child_spec/1` for your supervisor) owns
  the space: ETS tables with one row for each boid, and a grid of cells
  as the index.
- A boid is a process with the behavior `gen_boid`. At each tick of its
  own clock it reads its neighbors, calculates its force, moves and
  writes its row. It sends no message. A module of yours tells what the
  boid perceives, what it decides and what it does at each step, and how
  it answers messages.
- A boid of `add/2` or `populate/3` is a `gen_boid` with no module of
  yours, below the supervisor of the flock.
- A process with another behavior can be a boid too: `join/2` adds its
  row, and `advance/3` makes one step. The flock removes the row when
  the process stops.
- Each process reads the flock with `snapshot/1`, `lookup/2` and
  `near/3`, with no message to a boid.
- The boids of a flock can have relations (`relate/4`): a boid follows a
  leader, or fears an enemy. `graph/2` gives the flock as a graph of the
  boids that see each other.

Each function with a flock also accepts the space of the flock
(`space/1`). With the space, a read sends no message at all.

## The time

A boid moves in real time, each `tick` milliseconds of its own clock.
`set_time_scale/2` makes the time of the flock faster or slower, or
stops it. With `tick => manual`, the boids move only with `step/2`:
each boid calculates its step from the same state of the flock, and
then they all move. With a seed for each boid, such a run always gives
the same result.

## The units

The library has no unit of length. A speed is in units for each second,
and a force is in units for each second for each second.
""".

-export([start_flock/0, start_flock/1, stop_flock/1, child_spec/1, space/1]).
-export([add/2, populate/3, remove/2, update/3, boid/2, whereis/2]).
-export([add_rule/3, delete_rule/3, which_rules/2]).
-export([snapshot/1, lookup/2, near/3, count/1]).
-export([set_obstacle/4, remove_obstacle/2, obstacles/1, set_time_scale/2]).
-export([step/2]).
-export([graph/2, relate/4, unrelate/4, relations/1, related/3, related_to/3]).
-export([join/2, sense/2, plan/3, plan/4, commit/2, advance/3, leave/2]).

-export_type([flock/0, options/0]).

-type vec() :: boids_vec:vec().
-type flock() :: boids_flock:flock() | boids_space:space().
-type options() :: map() | [{atom(), term()}].

%% --- The flocks -------------------------------------------------------

-doc #{equiv => start_flock(#{})}.
-spec start_flock() -> {ok, pid()} | {error, term()}.
start_flock() ->
    start_flock(#{}).

-doc """
Start a flock below the supervisor of the application `boids`. The
result has the process of the flock.

The options:

- `name`: a name for the process of the flock: an atom, `{global,
  Term}` or `{via, Module, Term}`.
- `bounds`: `{Min, Max}`, the box of the flock. The rule `contain` and
  `populate/3` use it.
- `wrap`: `true` when each side of the box continues at the opposite
  side (default: `false`). It needs `bounds`.
- `cell_size`: the side of a cell of the grid (default: `10.0`). The
  best value is near the `perception` of the boids.
- `defaults`: options for each boid of the flock, as a map.
- `relations`: `cyclic` (the default) or `acyclic`: with `acyclic`, the
  relations between the boids cannot make a cycle (`relate/4`).

A bad option gives `{error, {bad_option, {Key, Value}}}`.
""".
-spec start_flock(options()) -> {ok, pid()} | {error, term()}.
start_flock(Opts0) ->
    try boids_flock:options(Opts0) of
        Opts ->
            case supervisor:start_child(boids_sup, [Opts]) of
                {ok, Sup} -> {ok, flock_of(Sup)};
                {error, {shutdown, {failed_to_start_child, boids_flock, Reason}}} -> {error, Reason}
            end
    catch
        error:{bad_option, _} = Reason -> {error, Reason}
    end.

flock_of(Sup) ->
    [Flock] = [Pid || {boids_flock, Pid, _, _} <- supervisor:which_children(Sup)],
    Flock.

-doc """
Stop a flock of `start_flock/1`, with its boids. For a flock that is
stopped, the result is `{error, not_found}`. It is the same for a flock
below your supervisor: stop it there.
""".
-spec stop_flock(flock()) -> ok | {error, not_found}.
stop_flock(Flock) ->
    try boids_flock:sup(maps:get(owner, space(Flock))) of
        Sup ->
            case supervisor:terminate_child(boids_sup, Sup) of
                ok -> ok;
                {error, _} -> {error, not_found}
            end
    catch
        exit:{noproc, _} -> {error, not_found}
    end.

-doc """
The specification of a flock as a child of your supervisor. The options
are those of `start_flock/1`. Give a `name`, so that your code can find
the flock.

```erlang
{ok, {#{}, [boids:child_spec(#{name => my_flock})]}}
```

In Elixir, the child is `{:boids, name: :my_flock}`.
""".
-spec child_spec(options()) -> supervisor:child_spec().
child_spec(Opts0) ->
    Opts = boids_flock:options(Opts0),
    #{
        id => {boids, maps:get(name, Opts, undefined)},
        start => {boids_flock_sup, start_link, [Opts]},
        type => supervisor
    }.

-doc """
The space of a flock: a map with the tables of the flock. A process
that reads the flock many times keeps it, and gives it to the functions
of this module as the flock.
""".
-spec space(flock()) -> boids_space:space().
space(Space) when is_map(Space) -> Space;
space(Flock) -> boids_flock:space(Flock).

%% --- The boids --------------------------------------------------------

-doc """
Add a boid to a flock: start its process. The result has the id of the
boid. The id is the option `id`, or the pid of the process.

The options are those of a boid (`boids_boid`) and of its process
(`gen_boid`), on top of the `defaults` of the flock. `pos` is
necessary.

All the boids of a flock have positions of the same size: two numbers,
or three. An id that is in the flock gives `{error, {exists, Id}}`. A
bad option gives `{error, {bad_option, {Key, Value}}}`.

A boid that stops with an error does not start again: the flock removes
it, and the other boids continue. `whereis/2` gives its process, for a
monitor.
""".
-spec add(flock(), options()) -> {ok, term()} | {error, term()}.
add(Flock, Opts0) ->
    Space = space(Flock),
    try boids_boid:to_map(Opts0) of
        Opts -> start(Space, boids_flock:boid_sup(Space), Opts)
    catch
        error:{bad_option, _} = Reason -> {error, Reason}
    end.

%% A boid with no module of the user. Its process checks the options.
start(Space = #{defaults := Defaults}, Sup, Opts) ->
    case gen_boid:start_child(Sup, undefined, Opts, #{flock => Space}) of
        {ok, Pid} -> {ok, maps:get(id, maps:merge(Defaults, Opts), Pid)};
        {error, Reason} -> {error, Reason}
    end.

-doc """
Add `Count` boids at random positions. The result has their ids.

The options are those of `add/2`, and `area`: `{Min, Max}`, the box of
the positions (default: the `bounds` of the flock). Without `vel`, each
boid gets a random direction, and a random speed between its `min_speed`
and its `max_speed`. With `seed`, the boid number N gets the seed
`seed + N`.
""".
-spec populate(flock(), non_neg_integer(), options()) -> {ok, [term()]} | {error, term()}.
populate(Flock, Count, Opts0) when is_integer(Count), Count >= 0 ->
    Space = #{defaults := Defaults, bounds := Bounds} = space(Flock),
    try
        Opts = boids_boid:to_map(Opts0),
        Area = {Min, _} = area(maps:get(area, Opts, Bounds)),
        Template = maps:without([area, id], maps:merge(Defaults, Opts)),
        {_Server, BoidOpts} = gen_boid:options(Template),
        {Area, Template, boids_boid:new(BoidOpts#{pos => Min})}
    of
        {{Min1, Max1}, Template1, Sample} ->
            Random = fun() -> random(Min1, Max1, Template1, Sample) end,
            populate(Space, boids_flock:boid_sup(Space), 1, Count, Template1, Random, [])
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
Remove a boid from its flock: stop its process. This is for a boid of
`add/2`, `populate/3` and `gen_boid:start/3`. For another id, the result
is `{error, not_found}`: a process of yours with `join/2`, or a boid
below a supervisor of yours (`gen_boid:start_link/3`).
""".
-spec remove(flock(), term()) -> ok | {error, not_found}.
remove(Flock, Id) ->
    Space = space(Flock),
    case boids_space:owner(Space, Id) of
        {server, Pid} ->
            %% A boid below a supervisor of the user is not a child here.
            case supervisor:terminate_child(boids_flock:boid_sup(Space), Pid) of
                ok -> boids_flock:leave(Space, Id, Pid);
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
-spec update(flock(), term(), options()) -> ok | {error, term()}.
update(Flock, Id, Changes) ->
    change(Flock, Id, update, Changes).

-doc """
Add a rule at the end of the rules of a boid: `{Name, Weight}` or
`{Name, Weight, Options}`. The boid has the rule from its next step.

```erlang
ok = boids:add_rule(Flock, Id, {{seek, home}, 2.0, #{target => {0, 0}}}),
ok = boids:delete_rule(Flock, Id, {seek, home}).
```
""".
-spec add_rule(flock(), term(), boids_boid:rule()) -> ok | {error, term()}.
add_rule(Flock, Id, Rule) ->
    change(Flock, Id, add_rule, Rule).

-doc "Remove the first rule with the name `Name` from a boid. A boid with no such rule does not change.".
-spec delete_rule(flock(), term(), boids_boid:name()) -> ok | {error, not_found}.
delete_rule(Flock, Id, Name) ->
    change(Flock, Id, delete_rule, Name).

-doc "The names of the rules of a boid, in their order.".
-spec which_rules(flock(), term()) -> {ok, [boids_boid:name()]} | {error, not_found}.
which_rules(Flock, Id) ->
    case boid(Flock, Id) of
        {ok, Boid} -> {ok, boids_boid:which_rules(Boid)};
        {error, not_found} -> {error, not_found}
    end.

change(Flock, Id, Function, Arg) ->
    Space = space(Flock),
    case boids_space:owner(Space, Id) of
        {server, Pid} -> call(Pid, {change, Function, Arg});
        _ -> {error, not_found}
    end.

-doc """
All the state of a boid, from its process. See `t:boids_boid:boid/0`.
""".
-spec boid(flock(), term()) -> {ok, boids_boid:boid()} | {error, not_found}.
boid(Flock, Id) ->
    Space = space(Flock),
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
flock.
""".
-spec whereis(flock(), term()) -> pid() | undefined.
whereis(Flock, Id) ->
    case boids_space:lookup(space(Flock), Id) of
        {ok, #{pid := Pid}} -> Pid;
        error -> undefined
    end.

%% --- The view of a flock ----------------------------------------------

-doc """
All the boids of a flock: a list of maps with `id`, `pos`, `vel`,
`group`, `data` and `pid`. The order is not specified. The boids move
during the read, so the rows are not all of the same moment.
""".
-spec snapshot(flock()) -> [boids_space:entry()].
snapshot(Flock) ->
    boids_space:all(space(Flock)).

-doc "One boid of a flock: its row, as in `snapshot/1`.".
-spec lookup(flock(), term()) -> {ok, boids_space:entry()} | error.
lookup(Flock, Id) ->
    boids_space:lookup(space(Flock), Id).

-doc """
The boids at the distance `Radius` or less from a point, in the order of
their distance. Each is a map with `id`, `pos`, `vel`, `group`, `data`,
`offset` (the vector from the point to the boid) and `dist`.
""".
-spec near(flock(), vec(), number()) -> [boids_space:neighbor()].
near(Flock, Pos, Radius) ->
    boids_space:near(space(Flock), Pos, Radius).

-doc "The number of boids of a flock.".
-spec count(flock()) -> non_neg_integer().
count(Flock) ->
    boids_space:count(space(Flock)).

%% --- The world of a flock ---------------------------------------------

-doc """
Add an obstacle to a flock, or change it: a circle (a sphere in 3D) with
the center `Pos`. The boids with the rule `avoid` move around it. Call
this function again to move the obstacle.
""".
-spec set_obstacle(flock(), term(), vec(), number()) -> ok.
set_obstacle(Flock, Id, Pos, Radius) ->
    boids_space:set_obstacle(space(Flock), Id, Pos, Radius).

-doc "Remove an obstacle from a flock.".
-spec remove_obstacle(flock(), term()) -> ok.
remove_obstacle(Flock, Id) ->
    boids_space:remove_obstacle(space(Flock), Id).

-doc "The obstacles of a flock: a list of maps with `id`, `pos` and `radius`.".
-spec obstacles(flock()) -> [boids_space:obstacle()].
obstacles(Flock) ->
    boids_space:obstacles(space(Flock)).

-doc """
Set the scale of the time of a flock: the seconds of the boids for each
second of the clock. With 0, the boids stop. The default is 1.0.
""".
-spec set_time_scale(flock(), number()) -> ok.
set_time_scale(Flock, Scale) ->
    boids_space:set_time_scale(space(Flock), Scale).

%% --- The time ---------------------------------------------------------

-doc """
Make one step of `Dt` seconds for all the boids that are a `gen_boid`:
those of `add/2` too. First each boid calculates its step, and the flock
does not change. Then each boid moves. The function returns after the
two parts.

The scale of the time of the flock applies to `Dt`. Use it with boids
that have `tick => manual`: for a test, or for a simulation that is
faster than the clock.
""".
-spec step(flock(), number()) -> ok.
step(Flock, Dt) when is_number(Dt), Dt >= 0 ->
    Pids = boids_space:servers(space(Flock)),
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

%% --- The flock as a graph ---------------------------------------------

-doc """
The flock as a graph (`graph`) of the boids that see each other. Each
boid is a vertex: its id, with its row as the label. An edge goes from a
boid to each boid at the distance `Radius` or less.

The functions of `graph` then answer questions about all the flock:

```erlang
Graph = boids:graph(Flock, 10),
Groups = graph:components(Graph),
Alone = [Id || Id <- graph:vertices(Graph), graph:out_degree(Graph, Id) =:= 0].
```

The build reads all the flock: it takes 50 to 200 microseconds for each
boid. Use it for a view of the flock, and not at each step of a boid.
""".
-spec graph(flock(), number()) -> graph:graph().
graph(Flock, Radius) ->
    Space = space(Flock),
    Rows = snapshot(Space),
    Vertices = lists:foldl(fun(Row = #{id := Id}, Graph) -> graph:add_vertex(Graph, Id, Row) end, graph:new(), Rows),
    lists:foldl(
        fun(#{id := Id, pos := Pos}, Graph0) ->
            %% A boid that came after the read of the rows is not a vertex.
            Others = [Other || #{id := Other} <- near(Space, Pos, Radius), Other =/= Id, graph:has_vertex(Graph0, Other)],
            lists:foldl(fun(Other, Graph) -> graph:add_edge(Graph, Id, Other) end, Graph0, Others)
        end,
        Vertices,
        Rows
    ).

-doc """
Add a relation between two boids of a flock: the boid `From` has the
relation `Label` to the boid `To`. A label is a term of yours, for
example `follows`, `fears` or `mate`.

```erlang
ok = boids:relate(Flock, Bird, follows, Leader),
ok = boids:update(Flock, Bird, #{rules => [{leader, 1.0, #{target => {related, follows}}}]}).
```

A rule with the target `{related, Label}` uses the relation at each
step. The relation goes when one of the two boids goes from the flock.

The result is `{error, {not_found, Id}}` for an id that is not in the
flock. In a flock with the option `relations => acyclic`, a relation
that makes a cycle gives `{error, cycle}`: use it for a hierarchy.
""".
-spec relate(flock(), term(), term(), term()) -> ok | {error, {not_found, term()} | cycle}.
relate(Flock, From, Label, To) ->
    boids_flock:relate(space(Flock), From, Label, To).

-doc "Remove a relation of `relate/4`.".
-spec unrelate(flock(), term(), term(), term()) -> ok.
unrelate(Flock, From, Label, To) ->
    boids_flock:unrelate(space(Flock), From, Label, To).

-doc """
All the relations of a flock, as a graph (`graph`): each boid with a
relation is a vertex, and each relation is an edge `{From, To, Label}`.

```erlang
Relations = boids:relations(Flock),
Chain = graph:get_path(Relations, Bird, TopLeader),
Order = graph:topsort(Relations).
```

Two boids can have relations with different labels. `graph` then gives
a neighbor one time for each label: for the boids of one label, use
`related/3` and `related_to/3`.
""".
-spec relations(flock()) -> graph:graph().
relations(Flock) ->
    boids_flock:relations(space(Flock)).

-doc """
The boids that the boid `From` has the relation `Label` to. The read
sends no message.
""".
-spec related(flock(), term(), term()) -> [term()].
related(Flock, From, Label) ->
    boids_space:related(space(Flock), From, Label).

-doc """
The boids that have the relation `Label` to the boid `To`: for example
the followers of a leader. The read sends no message.
""".
-spec related_to(flock(), term(), term()) -> [term()].
related_to(Flock, To, Label) ->
    boids_space:related_to(space(Flock), To, Label).

%% --- A process of your own as a boid ----------------------------------

-doc """
Make the process that calls this function a boid of a flock. The result
has the space of the flock and the boid (`t:boids_boid:boid/0`). Keep the
two in the state of the process, and call `advance/3` at each step.

The options are those of a boid (`boids_boid`), on top of the `defaults`
of the flock. The default id is the pid of the process. The flock
removes the boid when the process stops. The options of the process of
a `gen_boid` (`tick`, `search` and the others) have no effect here: the
process has its own clock.

```erlang
init(Flock) ->
    {ok, Space, Boid} = boids:join(Flock, #{pos => {0, 0}, vel => {1, 0}}),
    erlang:send_after(50, self(), tick),
    {ok, {Space, Boid}}.

handle_info(tick, {Space, Boid}) ->
    erlang:send_after(50, self(), tick),
    {noreply, {Space, boids:advance(Space, Boid, 0.05)}}.
```
""".
-spec join(flock(), options()) -> {ok, boids_space:space(), boids_boid:boid()} | {error, term()}.
join(Flock, Opts0) ->
    Space = #{defaults := Defaults} = space(Flock),
    try
        {_Server, BoidOpts} = gen_boid:options(maps:merge(Defaults, boids_boid:to_map(Opts0))),
        boids_boid:new(maps:merge(#{id => self()}, BoidOpts))
    of
        Boid ->
            case boids_flock:join(Space, self(), boids_boid:entry(Boid)) of
                ok -> {ok, Space, Boid};
                {error, Reason} -> {error, Reason}
            end
    catch
        error:{bad_option, _} = Reason -> {error, Reason}
    end.

-doc """
Calculate one step of `Dt` seconds for a boid: read its neighbors,
calculate the force of its rules, and move. The result is the new boid.
The flock does not change before `commit/2`. The scale of the time of
the flock applies to `Dt`.
""".
-spec plan(boids_space:space(), boids_boid:boid(), number()) -> boids_boid:boid().
plan(Space, Boid, Dt) ->
    plan(Space, Boid, sense(Space, Boid), Dt).

-doc "The neighbors that a boid sees now in its flock, the nearest first.".
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
Write a boid to its flock, so that the other boids see its new position.
Call it after `plan/3`, or after a change of the boid with
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

-doc "Remove a boid of `join/2` from its flock. The process of the boid calls this function.".
-spec leave(boids_space:space(), boids_boid:boid()) -> ok.
leave(Space, #{id := Id}) ->
    boids_flock:leave(Space, Id, self()).
