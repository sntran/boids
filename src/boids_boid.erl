-module(boids_boid).
-moduledoc """
One boid, as a value: its position, its velocity, its limits and its
rules.

This module has no process and no table. A process holds a boid, and
calls `step/4` with the neighbors that it sees and the time that passed.
`gen_boid` does this. `boids:join/2` and `boids:advance/3` do the same
for a process with another behavior.

## The options of a boid

| Option | Default | Description |
|---|---|---|
| `pos` | (necessary) | The position: `{X, Y}` or `{X, Y, Z}`. |
| `vel` | zero | The velocity, in units for each second. |
| `id` | a reference | The name of the boid in its world. |
| `group` | `default` | The group of the boid: an atom, or another term. |
| `data` | `undefined` | A term of yours. The neighbors see it. |
| `max_speed` | `10.0` | The maximum speed. |
| `min_speed` | `0.0` | The minimum speed of a boid that moves. |
| `max_force` | `20.0` | The maximum of the sum of the forces. |
| `mass` | `1.0` | The acceleration is the force divided by the mass. |
| `perception` | `10.0` | The distance that the boid sees. |
| `fov` | `2 * pi` | The angle that the boid sees, around its direction. |
| `max_neighbors` | `infinity` | The boid sees only this number of the nearest boids. |
| `rules` | see below | The list of the rules. |
| `combine` | `sum` | How the forces of the rules become one force. |
| `walkable` | `all` | Where the boid can be: `all`, or `{named, Name}` for the open cells of the grid of the world with that name. See "The places where a boid can walk". |
| `state` | `undefined` | A term of yours. Only the boid sees it: the callbacks of a `gen_boid` keep their state here. |

The options are a map, or a list of `{Key, Value}`.

## The rules

A rule is `{Name, Weight}` or `{Name, Weight, Options}`. The default list
is the three rules of a flock:
`[{separation, 1.5}, {alignment, 1.0}, {cohesion, 1.0}]`.

| Rule | Options | Description |
|---|---|---|
| `separation` | `radius` (half of `perception`), `groups` (`all`) | Move away from the near neighbors. |
| `alignment` | `radius` (`infinity`), `groups` (`same`) | Move in the direction of the neighbors. |
| `cohesion` | `radius` (`infinity`), `groups` (`same`) | Move to the center of the neighbors. |
| `seek` | `target` | Move to the target. |
| `flee` | `target`, `radius` (`infinity`) | Move away from a target that is in the radius. |
| `arrive` | `target`, `slow_radius` (`perception`) | Move to the target, and stop there. |
| `pursue` | `target`, `max_time` (`infinity`) | Move to where the target will be. |
| `evade` | `target`, `radius` (`infinity`), `max_time` (`infinity`) | Move away from where the target will be. |
| `wander` | `distance` (`2.0`), `radius` (`1.0`), `jitter` (`2.0`) | Move in a direction that changes slowly. |
| `avoid` | `lookahead` (`1.0` second), `clearance` (a tenth of `perception`) | Move around the obstacles of the world. |
| `contain` | `margin` (`perception`), `bounds` (those of the world) | Stay in the box. |
| `follow` | `path`, `ahead` (`perception`), `predict` (`0.5` second), `loop` (`false`) | Move along a list of points. |
| `cruise` | `speed` (`max_speed`) | Keep a speed in the direction of the movement. |
| `leader` | `target`, `distance` (half of `perception`), `slow_radius` (`perception`) | Stay behind a leader, and move out of its way. |
| `dodge` | `radius` (a quarter of `perception`), `horizon` (`2.0` seconds), `groups` (`all`) | Move away from a neighbor that comes too near in the time of the horizon. |
| `flow` | `field`, `predict` (`0.5` second) | Move in the direction of a field: a vector, or a function of a position. |
| `walls` | `margin` (half of `perception`) | Move away from the walls of the grid of the boid (`walkable`) that are nearer than the margin. |

`groups` is `all`, `same` (the group of the boid) or a list of groups.

`target` is a point, `{boid, Id}` (a boid of the world), `{group,
Group}` (the nearest neighbor of that group) or `{related, Label}` (the
boid that this boid has the relation `Label` to, see `boids:relate/4`).
A target that does not exist gives no force.

A rule of your own is a function: `{Fun, Weight}`, where `Fun(Boid,
Neighbors, Seen)` gives the force. `Neighbors` are the boids that the
boid sees, the nearest first. `Seen` is what the boid perceives in this
step: `dt` (the seconds of the step), `obstacles`, `bounds`, `wrap` and
`grids`.
`obstacles` has only the obstacles to the distance `reach/1` from the
boid, in the order of their ids: a rule that needs obstacles farther
than that does not get them. `grids` is a map with the grids that the
boid uses, by their names (`named/1`).
Use `fun Module:Function/3` for a rule that stays when the code of the
module changes.

A boid can have a rule of the library two times, for example two
targets of `seek`. Give a name to each one: `{{seek, home}, 1.0,
#{target => {0, 0}}}`. The name of a rule is its first part: `seek`,
`{seek, home}` or the function. `add_rule/2` and `delete_rule/2` use it.

## The order of the rules

The rules of a boid are a list, and the list has an order.

- With `combine => sum` (the default), the order has no effect on the
  force. The force is the sum of the forces of all the rules, each
  multiplied by its weight, with the length `max_force` at most.
- With `combine => priority`, the order is the priority. Each rule, in
  the order of the list, takes a part of `max_force`, and the last rules
  get what stays. Put `avoid` first there.
- The order is also the order of `which_rules/1`, and `delete_rule/2`
  removes the first rule with a name.

`forces/3` gives the force of each rule, before the forces become one
force. Use it to see what each rule does, and to adjust the weights.

## The places where a boid can walk

The rules give forces, and the forces add: a force can push a boid into
a wall. The option `walkable` is a hard limit, which no force can pass.

The world owns the walls: a grid of cells with a name
(`boids:set_grid/3`, `boids_grid`). A boid with `walkable => {named,
Name}` can be only in the open cells of that grid. The option is data:
the option `defaults` of a world can give it to all the boids, and a
boid of another kind can have another name, or `all`. Thus walls can be
for people and not for birds. A name with no grid in the world is no
limit.

- **The slide.** The limit is in the movement of a step
  (`integrate/4`), after the forces and before `handle_act/1` of a
  `gen_boid`. If the line from the old position to the new position
  goes into a blocked cell, the boid slides along the edge: the library
  removes the part of the movement into the edge, and the same part of
  the velocity. A boid that goes into a wall at 45 degrees thus slides
  along it at 0.71 of its speed. A boid stops only in a corner. The
  contact is exact, for each speed and each length of step.
- **All the steps.** The steps of a `gen_boid`, of `boids:step/2`, and of
  `boids:plan/3` and `boids:advance/3` (a process of `boids:join/2`)
  obey the limit. `boids:populate/3` puts boids only in walkable places.
  With `step/4` of this module, give the grid in `Seen`: `#{grids =>
  #{Name => Grid}}`.
- **A door.** `boids:set_grid/3` with a new grid for the same name
  changes the walls for all the boids, from their next step. A boid
  that is then in a blocked cell goes to the nearest walkable place at
  the start of its next step (`boids_grid:nearest/2`), and makes its
  step from there. So does a boid that starts in a blocked cell. When
  the grid has no open cell, the boid has no limit.
- **Two dimensions.** A grid has two dimensions. A boid with three
  dimensions and `walkable` other than `all` is a bad option.
- **With `wrap`,** the cells are at their positions in the box: a boid
  that crosses a side of the box meets the walls of the opposite side.
- **The rule `walls`.** The limit only stops a movement into a wall. The
  rule `walls` moves a boid away from a wall before it touches it, so
  that the movement is smooth and the limit acts only a little. The
  force is larger when the wall is nearer, and it does not change with
  the thickness or the length of a wall (`boids_steer:walls/3`).
""".

-export([new/1, update/2, options/1, entry/1, to_map/1]).
-export([add_rule/2, delete_rule/2, which_rules/1]).
-export([perceive/2, reach/1, named/1, forces/3, force/3, integrate/4, step/4]).

-export_type([boid/0, rule/0, name/0, target/0, seen/0]).

-type vec() :: boids_vec:vec().
-type boid() :: #{
    id := term(),
    pos := vec(),
    vel := vec(),
    group := term(),
    data := term(),
    max_speed := number(),
    min_speed := number(),
    max_force := number(),
    mass := number(),
    perception := number(),
    fov := number(),
    max_neighbors := pos_integer() | infinity,
    rules := [{name(), number(), map()}],
    combine := sum | priority,
    walkable := all | {named, term()},
    memory := map(),
    state := term()
}.
-type rule_name() ::
    separation
    | alignment
    | cohesion
    | seek
    | flee
    | arrive
    | pursue
    | evade
    | wander
    | avoid
    | contain
    | follow
    | cruise
    | leader
    | dodge
    | flow
    | walls.
-type name() ::
    rule_name()
    | {rule_name(), Id :: term()}
    | fun((boid(), [boids_space:neighbor()], seen()) -> vec()).
-type rule() :: {name(), number()} | {name(), number(), map() | [{atom(), term()}]}.
-type target() :: vec() | {boid, term()} | {group, term()} | {related, term()}.
-type seen() :: #{
    neighbors => [boids_space:neighbor()],
    dt => number(),
    bounds => {vec(), vec()} | undefined,
    wrap => boolean(),
    obstacles => [boids_steer:obstacle()],
    grids => #{term() => boids_grid:grid()},
    lookup => fun((term()) -> {ok, #{pos := vec(), vel := vec(), _ => _}} | error),
    related => fun((term(), term()) -> [term()]),
    _ => _
}.

-define(FULL_CIRCLE, 6.283185307179586).

%% The most contacts with walls in the movement of one step. A boid that
%% goes into a corner has two. Three are possible when the line goes
%% exactly through a corner of cells.
-define(CONTACTS, 3).

-doc """
Make a boid from its options. A bad option gives the error
`{bad_option, {Key, Value}}`. Each number is 1.0e100 at most, and each
vector of a rule has the size of the position.
""".
-spec new(map() | [{atom(), term()}]) -> boid().
new(Opts0) ->
    Opts = to_map(Opts0),
    Pos = check(pos, maps:get(pos, Opts, undefined)),
    Base = #{
        id => make_ref(),
        vel => boids_vec:zero(boids_vec:dim(Pos)),
        group => default,
        data => undefined,
        max_speed => 10.0,
        min_speed => 0.0,
        max_force => 20.0,
        mass => 1.0,
        perception => 10.0,
        fov => ?FULL_CIRCLE,
        max_neighbors => infinity,
        rules => [{separation, 1.5}, {alignment, 1.0}, {cohesion, 1.0}],
        combine => sum,
        walkable => all,
        memory => #{},
        state => undefined
    },
    validate(maps:merge(Base, Opts)).

-doc """
Change options of a boid. The id and the size of the position do not
change. A bad option gives the error `{bad_option, {Key, Value}}`.
""".
-spec update(boid(), map() | [{atom(), term()}]) -> boid().
update(Boid = #{pos := Old}, Changes0) ->
    Changes = to_map(Changes0),
    [error({bad_option, {Key, maps:get(Key, Changes)}}) || Key <- [id, memory], is_map_key(Key, Changes)],
    case validate(maps:merge(Boid, Changes)) of
        #{pos := New} when tuple_size(New) =/= tuple_size(Old) -> error({bad_option, {pos, New}});
        %% A rule that the boid has no more has no memory.
        Changed = #{rules := Rules, memory := Memory} ->
            Changed#{memory := maps:with([Name || {Name, _, _} <- Rules], Memory)}
    end.

-doc """
Add a rule at the end of the rules of a boid: `{Name, Weight}` or
`{Name, Weight, Options}`. A bad rule gives the error `{bad_option,
{rules, Rule}}`.
""".
-spec add_rule(boid(), rule()) -> boid().
add_rule(Boid = #{rules := Rules}, Rule) ->
    update(Boid, #{rules => Rules ++ [Rule]}).

-doc "Remove the first rule with the name `Name` from a boid. A boid with no such rule does not change.".
-spec delete_rule(boid(), name()) -> boid().
delete_rule(Boid = #{rules := Rules}, Name) ->
    update(Boid, #{rules => lists:keydelete(Name, 1, Rules)}).

-doc "The names of the rules of a boid, in their order.".
-spec which_rules(boid()) -> [name()].
which_rules(#{rules := Rules}) ->
    [Name || {Name, _, _} <- Rules].

-doc """
Check options with no boid, and give them as a map: each value alone,
and not the values together. `boids:start_world/1` checks the
`defaults` of a world with this function.
""".
-spec options(map() | [{atom(), term()}]) -> map().
options(Opts) ->
    maps:map(fun check/2, to_map(Opts)).

-doc "The part of a boid that the other boids see: the row of `boids_space`.".
-spec entry(boid()) -> #{id := term(), pos := vec(), vel := vec(), group := term(), data := term()}.
entry(Boid) ->
    maps:with([id, pos, vel, group, data], Boid).

-doc false.
to_map(Opts) when is_map(Opts) -> Opts;
to_map(Opts) when is_list(Opts) ->
    try
        maps:from_list(Opts)
    catch
        error:badarg -> error({bad_option, Opts})
    end;
to_map(Opts) -> error({bad_option, Opts}).

validate(Boid0) ->
    Checked = #{pos := Pos, vel := Vel, rules := Rules} = maps:map(fun check/2, Boid0),
    Dim = tuple_size(Pos),
    %% The vectors of a rule have the size of the position.
    [error({bad_option, {rules, Rule}}) || Rule = {Name, _, Opts} <- Rules, not is_function(Name), not sized(Opts, Dim)],
    case {Dim =:= tuple_size(Vel), Checked} of
        {false, _} -> error({bad_option, {vel, Vel}});
        {true, #{min_speed := Min, max_speed := Max}} when Min > Max -> error({bad_option, {min_speed, Min}});
        %% A grid has two dimensions.
        {true, #{walkable := Walkable}} when Dim =:= 3, Walkable =/= all -> error({bad_option, {walkable, Walkable}});
        {true, _} -> Checked
    end.

sized(Opts, Dim) ->
    Vectors =
        [Point || #{target := Point} <- [Opts], is_tuple(Point), not is_atom(element(1, Point))] ++
            [Vector || #{field := Vector} <- [Opts], is_tuple(Vector)] ++
            [Corner || #{bounds := {Min, Max}} <- [Opts], Corner <- [Min, Max]] ++
            maps:get(path, Opts, []),
    lists:all(fun(Vector) -> tuple_size(Vector) =:= Dim end, Vectors).

check(Key, Value) ->
    case ok(Key, Value) of
        true -> Value;
        false -> error({bad_option, {Key, Value}});
        {ok, Other} -> Other
    end.

ok(id, _) -> true;
ok(group, _) -> true;
ok(data, _) -> true;
ok(memory, Memory) -> is_map(Memory);
ok(state, _) -> true;
ok(pos, Pos) -> boids_vec:is_vec(Pos);
ok(vel, Vel) -> boids_vec:is_vec(Vel);
ok(max_speed, N) -> boids_vec:is_size(N);
ok(min_speed, N) -> boids_vec:is_size(N);
ok(max_force, N) -> boids_vec:is_size(N);
ok(mass, N) -> boids_vec:is_size(N) andalso N > 0;
ok(perception, N) -> boids_vec:is_size(N);
ok(fov, N) -> boids_vec:is_size(N);
ok(max_neighbors, N) -> N =:= infinity orelse (is_integer(N) andalso N > 0);
ok(combine, Combine) -> Combine =:= sum orelse Combine =:= priority;
ok(walkable, all) -> true;
ok(walkable, {named, _Name}) -> true;
ok(rules, Rules) when is_list(Rules) -> {ok, [rule(Rule) || Rule <- Rules]};
ok(_, _) -> false.

%% --- The rules: the check --------------------------------------------

rule({Name, Weight}) ->
    rule({Name, Weight, #{}});
rule({Name, Weight, Opts}) when is_list(Opts) ->
    try maps:from_list(Opts) of
        Map -> rule({Name, Weight, Map})
    catch
        error:badarg -> error({bad_option, {rules, {Name, Weight, Opts}}})
    end;
rule(Rule = {Name, Weight, Opts}) when is_number(Weight), is_map(Opts) ->
    case keys(base(Name)) of
        {Necessary, Optional} ->
            Base = base(Name),
            Good =
                Necessary -- maps:keys(Opts) =:= [] andalso
                    maps:keys(Opts) -- (Necessary ++ Optional) =:= [] andalso
                    lists:all(fun({Key, Value}) -> opt(Base, Key, Value) end, maps:to_list(Opts)),
            Good orelse error({bad_option, {rules, Rule}}),
            Rule;
        custom when is_function(Name, 3), Opts =:= #{} ->
            Rule;
        custom ->
            error({bad_option, {rules, Rule}})
    end;
rule(Rule) ->
    error({bad_option, {rules, Rule}}).

%% The rule of the library of a name: seek for seek and for {seek, Id}.
base({Base, _Id}) -> Base;
base(Base) -> Base.

%% The necessary options and the other options of each rule of the library.
keys(separation) -> {[], [radius, groups]};
keys(alignment) -> {[], [radius, groups]};
keys(cohesion) -> {[], [radius, groups]};
keys(seek) -> {[target], []};
keys(flee) -> {[target], [radius]};
keys(arrive) -> {[target], [slow_radius]};
keys(pursue) -> {[target], [max_time]};
keys(evade) -> {[target], [radius, max_time]};
keys(wander) -> {[], [distance, radius, jitter]};
keys(avoid) -> {[], [lookahead, clearance]};
keys(contain) -> {[], [bounds, margin]};
keys(follow) -> {[path], [ahead, predict, loop]};
keys(cruise) -> {[], [speed]};
keys(leader) -> {[target], [distance, slow_radius]};
keys(dodge) -> {[], [radius, horizon, groups]};
keys(flow) -> {[field], [predict]};
keys(walls) -> {[], [margin]};
keys(_) -> custom.

opt(Name, radius, N) when Name =:= wander; Name =:= dodge -> boids_vec:is_size(N);
opt(_, radius, N) -> is_distance(N);
opt(_, max_time, N) -> is_distance(N);
opt(_, groups, Groups) -> Groups =:= all orelse Groups =:= same orelse is_list(Groups);
opt(_, target, {boid, _}) -> true;
opt(_, target, {group, _}) -> true;
opt(_, target, {related, _}) -> true;
opt(_, target, Point) -> boids_vec:is_vec(Point);
opt(_, bounds, {Min, Max}) -> boids_vec:is_box(Min, Max);
opt(_, path, Path) -> is_list(Path) andalso Path =/= [] andalso lists:all(fun boids_vec:is_vec/1, Path);
opt(_, loop, Loop) -> is_boolean(Loop);
opt(_, field, Field) -> is_function(Field, 1) orelse boids_vec:is_vec(Field);
opt(_, Key, N) when Key =/= bounds -> boids_vec:is_size(N);
opt(_, _, _) -> false.

is_distance(N) -> N =:= infinity orelse boids_vec:is_size(N).

%% --- One step --------------------------------------------------------

-doc """
The neighbors that a boid sees, from the boids near it (the result of
`boids_space:near/3`, in the order of the distance). The boid does not
see itself, and it sees only the boids in its angle `fov`. With
`max_neighbors`, it sees only the nearest of them.
""".
-spec perceive(boid(), [boids_space:neighbor()]) -> [boids_space:neighbor()].
perceive(#{id := Id, vel := Vel, fov := Fov, max_neighbors := Max}, Near) ->
    Heading = boids_vec:normalize(Vel),
    All = Fov >= ?FULL_CIRCLE orelse boids_vec:norm2(Heading) == 0,
    Cos = math:cos(Fov / 2),
    Seen = [N || N = #{id := Other} <- Near, Other =/= Id, All orelse in_view(N, Heading, Cos)],
    case Max of
        infinity -> Seen;
        _ -> lists:sublist(Seen, Max)
    end.

in_view(#{dist := Dist}, _Heading, _Cos) when Dist == 0 -> true;
in_view(#{offset := Offset, dist := Dist}, Heading, Cos) -> boids_vec:dot(Heading, Offset) / Dist >= Cos.

-doc """
The distance to which a boid gets the obstacles of its world, from its
position to the edge of an obstacle: the largest of `perception` and of
`Speed * lookahead + clearance`. `Speed` is the largest of `max_speed`
and of the speed of the boid. `lookahead` and `clearance` are the options
of the rule `avoid`, with their defaults when the boid has no such
rule. Thus the rule `avoid` gets each obstacle that it can touch.
""".
-spec reach(boid()) -> float().
reach(#{perception := Perception, max_speed := Max, vel := Vel, rules := Rules}) ->
    Speed = max(Max, boids_vec:norm(Vel)),
    Avoid = [Opts || {Name, _Weight, Opts} <- Rules, Name =:= avoid orelse is_tuple(Name) andalso element(1, Name) =:= avoid],
    Ahead = [
        Speed * maps:get(lookahead, Opts, 1.0) + maps:get(clearance, Opts, Perception / 10)
     || Opts <- case Avoid of
            [] -> [#{}];
            _ -> Avoid
        end
    ],
    float(lists:max([Perception | Ahead])).

-doc """
The force of each rule of a boid, in the order of its rules: a list of
`{Name, Force}`. Each force is multiplied by the weight of its rule. The
result also has the boid with the memory of its rules (the point of
`wander`).

`force/3` makes one force of these forces. Use this function to see what
each rule gives, for example to adjust the weights:

```erlang
{Forces, _Boid} = boids_boid:forces(Boid, Neighbors, #{dt => 0.05}),
[{separation, {1.2, 0.0}}, {alignment, {0.0, 0.4}}, {cohesion, {-0.3, 0.1}}] = Forces.
```
""".
-spec forces(boid(), [boids_space:neighbor()], seen()) -> {[{name(), vec()}], boid()}.
forces(Boid = #{rules := Rules, memory := Memory0}, Neighbors, Seen) ->
    {Forces, Memory} =
        lists:mapfoldl(
            fun({Name, Weight, Opts}, Memory1) ->
                case apply_rule(base(Name), Opts, Boid, Neighbors, Seen, Memory1, Name) of
                    %% A force is a tuple of numbers. Only a rule of the
                    %% library keeps a memory.
                    {Force, Kept} when is_tuple(Force), not is_function(Name) ->
                        {{Name, boids_vec:scale(Force, Weight)}, Memory1#{Name => Kept}};
                    Force ->
                        {{Name, boids_vec:scale(Force, Weight)}, Memory1}
                end
            end,
            Memory0,
            Rules
        ),
    %% Most boids have no rule with a memory: the boid does not change.
    case Memory =:= Memory0 of
        true -> {Forces, Boid};
        false -> {Forces, Boid#{memory := Memory}}
    end.

-doc """
The force of all the rules of a boid, and the boid with the memory of
its rules (the point of `wander`). See the module for `Seen`, and for
how the forces of the rules become one force (`combine`).
""".
-spec force(boid(), [boids_space:neighbor()], seen()) -> {vec(), boid()}.
force(Boid0 = #{combine := Combine, max_force := MaxForce, pos := Pos}, Neighbors, Seen) ->
    {Forces, Boid} = forces(Boid0, Neighbors, Seen),
    Zero = boids_vec:zero(boids_vec:dim(Pos)),
    {combine(Combine, [Force || {_Name, Force} <- Forces], MaxForce, Zero), Boid}.

combine(sum, Forces, MaxForce, Zero) ->
    boids_vec:limit(lists:foldl(fun boids_vec:add/2, Zero, Forces), MaxForce);
combine(priority, [Force | Rest], Left, Acc) when Left > 0 ->
    Part = boids_vec:limit(Force, Left),
    combine(priority, Rest, Left - boids_vec:norm(Part), boids_vec:add(Acc, Part));
combine(priority, _Forces, _Left, Acc) ->
    Acc.

-doc """
The facts with a name that a boid uses: the keys of the facts of its
world that the boid needs in `Seen`. A boid with `walkable => {named,
Name}` uses the grid `{grid, Name}`. `boids_space:named/3` reads them,
and `gen_boid` and `boids:plan/3` put them in the key `grids` of `Seen`.
""".
-spec named(boid()) -> [{grid, term()}].
named(#{walkable := {named, Name}}) -> [{grid, Name}];
named(_Boid) -> [].

-doc """
Move a boid for `Dt` seconds with a force. The speed stays in the limits
of the boid. With `wrap` in `Seen`, the position stays in the box.

A boid with the option `walkable` does not go into a blocked cell of
its grid (the key `grids` of `Seen`): it slides along the edge. See
"The places where a boid can walk".
""".
-spec integrate(boid(), vec(), seen(), number()) -> boid().
integrate(Boid, _Force, _Seen, Dt) when Dt =< 0 ->
    Boid;
integrate(Boid = #{pos := Pos, vel := Vel, mass := Mass}, Force, Seen, Dt) ->
    Vel1 = speed(boids_vec:add(Vel, boids_vec:scale(Force, Dt / Mass)), Boid),
    Move = boids_vec:scale(Vel1, Dt),
    case grid(Boid, Seen) of
        none ->
            Boid#{pos := place(Seen, boids_vec:add(Pos, Move)), vel := Vel1};
        Grid ->
            {Pos1, Vel2} = slide(Grid, box(Seen), Pos, Move, Vel1, ?CONTACTS),
            Boid#{pos := place(Seen, Pos1), vel := Vel2}
    end.

%% The grid that limits a boid: the grid of Seen with the name of its
%% option walkable, or none.
grid(#{walkable := {named, Name}}, #{grids := Grids}) -> maps:get(Name, Grids, none);
grid(_Boid, _Seen) -> none.

%% With wrap, the cells of a grid are at their positions in the box.
box(#{wrap := true, bounds := Bounds}) -> Bounds;
box(_Seen) -> none.

%% Move from From by Move in a grid. At a blocked cell, the boid slides
%% along the edge: the movement and the velocity lose their part into
%% the edge, and the rest of the movement continues from the contact.
%% In a corner, the movement has nothing left. After the last contact
%% that a step permits, the boid stays at that contact.
slide(Grid, Box, From, Move, Vel, Contacts) ->
    To = boids_vec:add(From, Move),
    case Contacts > 0 andalso boids_grid:hit(Grid, From, To, Box) of
        none ->
            {To, Vel};
        {At, Normal} ->
            slide(Grid, Box, At, without(boids_vec:sub(To, At), Normal), without(Vel, Normal), Contacts - 1);
        inside ->
            out(Grid, Box, From, Move, Vel, Contacts);
        false ->
            {From, Vel}
    end.

%% A boid in a blocked cell: a door closed on it, or it started there.
%% It goes to the nearest walkable place, and makes its step from there.
%% In a grid with no open cell, it has no limit.
out(Grid, Box, From, Move, Vel, Contacts) ->
    case boids_grid:nearest(Grid, From, Box) of
        none -> {boids_vec:add(From, Move), Vel};
        Place -> slide(Grid, Box, Place, Move, Vel, Contacts - 1)
    end.

%% A vector with no part into an edge (Normal has the length 1). A part
%% away from the edge stays.
without(Vec, Normal) ->
    boids_vec:sub(Vec, boids_vec:scale(Normal, max(0.0, boids_vec:dot(Vec, Normal)))).

speed(Vel, #{min_speed := Min, max_speed := Max}) ->
    case boids_vec:norm(Vel) of
        Speed when Speed > Max -> boids_vec:scale(Vel, Max / Speed);
        Speed when Speed < Min, Speed > 0 -> boids_vec:scale(Vel, Min / Speed);
        _ -> Vel
    end.

place(#{wrap := true, bounds := {Min, Max}}, Pos) -> boids_vec:wrap(Pos, Min, Max);
place(_Seen, Pos) -> Pos.

-doc """
One step of a boid: the force of its rules, then the movement for `Dt`
seconds. `Neighbors` is the result of `perceive/2`.
""".
-spec step(boid(), [boids_space:neighbor()], seen(), number()) -> boid().
step(Boid, _Neighbors, _Seen, Dt) when Dt =< 0 ->
    Boid;
step(Boid, Neighbors, Seen, Dt) ->
    {Force, Boid1} = force(Boid, Neighbors, Seen#{dt => Dt}),
    integrate(Boid1, Force, Seen, Dt).

%% --- The rules: the forces -------------------------------------------

%% The force of one rule, or {Force, Kept} for a rule that keeps a
%% memory: the boid has it for the name of the rule at the next step.
apply_rule(separation, Opts, B = #{perception := Perception}, Ns, _Seen, _Memory, _Name) ->
    boids_steer:separation(B, select(Ns, B, Opts, Perception / 2, all));
apply_rule(alignment, Opts, B, Ns, _Seen, _Memory, _Name) ->
    boids_steer:alignment(B, select(Ns, B, Opts, infinity, same));
apply_rule(cohesion, Opts, B, Ns, _Seen, _Memory, _Name) ->
    boids_steer:cohesion(B, select(Ns, B, Opts, infinity, same));
apply_rule(seek, Opts, B, Ns, Seen, _Memory, _Name) ->
    to_target(Opts, B, Ns, Seen, fun(Pos, _Vel) -> boids_steer:seek(B, Pos) end);
apply_rule(flee, Opts, B, Ns, Seen, _Memory, _Name) ->
    to_target(Opts, B, Ns, Seen, fun(Pos, _Vel) -> boids_steer:flee(B, Pos) end);
apply_rule(arrive, Opts, B = #{perception := Perception}, Ns, Seen, _Memory, _Name) ->
    Slow = maps:get(slow_radius, Opts, Perception),
    to_target(Opts, B, Ns, Seen, fun(Pos, _Vel) -> boids_steer:arrive(B, Pos, Slow) end);
apply_rule(pursue, Opts, B, Ns, Seen, _Memory, _Name) ->
    Time = maps:get(max_time, Opts, infinity),
    to_target(Opts, B, Ns, Seen, fun(Pos, Vel) -> boids_steer:pursue(B, Pos, Vel, Time) end);
apply_rule(evade, Opts, B, Ns, Seen, _Memory, _Name) ->
    Time = maps:get(max_time, Opts, infinity),
    to_target(Opts, B, Ns, Seen, fun(Pos, Vel) -> boids_steer:evade(B, Pos, Vel, Time) end);
apply_rule(wander, Opts, B = #{pos := Pos}, _Ns, Seen, Memory, Name) ->
    Dim = boids_vec:dim(Pos),
    Point0 =
        case Memory of
            #{Name := Known} -> Known;
            _ -> boids_vec:random_unit(Dim)
        end,
    %% The square root makes the change in a second the same for each
    %% length of step.
    Step = maps:get(jitter, Opts, 2.0) * math:sqrt(maps:get(dt, Seen, 0.0)),
    Point = wander_point(Point0, boids_vec:scale(boids_vec:random_unit(Dim), Step)),
    {boids_steer:wander(B, Point, maps:get(distance, Opts, 2.0), maps:get(radius, Opts, 1.0)), Point};
apply_rule(avoid, Opts, B = #{pos := Pos, vel := Vel, perception := Perception}, _Ns, Seen, _Memory, _Name) ->
    %% A boid does not see an obstacle with a center of another size.
    Obstacles = [
        O#{pos := seen_at(Seen, Pos, At)}
     || O = #{pos := At} <- maps:get(obstacles, Seen, []), tuple_size(At) =:= tuple_size(Pos)
    ],
    Ahead = boids_vec:norm(Vel) * maps:get(lookahead, Opts, 1.0),
    boids_steer:avoid(B, Obstacles, Ahead, maps:get(clearance, Opts, Perception / 10));
apply_rule(contain, Opts, B = #{pos := Pos, perception := Perception}, _Ns, Seen, _Memory, _Name) ->
    case maps:get(bounds, Opts, maps:get(bounds, Seen, undefined)) of
        undefined -> boids_vec:zero(boids_vec:dim(Pos));
        Bounds -> boids_steer:contain(B, Bounds, maps:get(margin, Opts, Perception))
    end;
apply_rule(follow, Opts = #{path := Path}, B = #{perception := Perception}, _Ns, _Seen, _Memory, _Name) ->
    Ahead = maps:get(ahead, Opts, Perception),
    Predict = maps:get(predict, Opts, 0.5),
    boids_steer:follow(B, Path, Ahead, Predict, maps:get(loop, Opts, false));
apply_rule(cruise, Opts, B = #{max_speed := Max}, _Ns, _Seen, _Memory, _Name) ->
    boids_steer:cruise(B, maps:get(speed, Opts, Max));
apply_rule(leader, Opts, B = #{perception := Perception}, Ns, Seen, _Memory, _Name) ->
    Distance = maps:get(distance, Opts, Perception / 2),
    Slow = maps:get(slow_radius, Opts, Perception),
    to_target(Opts, B, Ns, Seen, fun(Pos, Vel) -> boids_steer:leader(B, Pos, Vel, Distance, Slow) end);
apply_rule(dodge, Opts, B = #{perception := Perception}, Ns, _Seen, _Memory, _Name) ->
    Near = select(Ns, B, maps:remove(radius, Opts), infinity, all),
    boids_steer:dodge(B, Near, maps:get(radius, Opts, Perception / 4), maps:get(horizon, Opts, 2.0));
apply_rule(flow, Opts = #{field := Field}, B = #{pos := Pos, vel := Vel}, _Ns, _Seen, _Memory, _Name) ->
    Direction =
        case is_function(Field) of
            true -> Field(boids_vec:add(Pos, boids_vec:scale(Vel, maps:get(predict, Opts, 0.5))));
            false -> Field
        end,
    boids_steer:flow(B, Direction);
apply_rule(walls, Opts, B = #{pos := Pos, perception := Perception}, _Ns, Seen, _Memory, _Name) ->
    Margin = maps:get(margin, Opts, Perception / 2),
    case grid(B, Seen) of
        none -> boids_vec:zero(boids_vec:dim(Pos));
        Grid -> boids_steer:walls(B, boids_grid:walls(Grid, place(Seen, Pos), Margin, box(Seen)), Margin)
    end;
apply_rule(Fun, _Opts, B, Ns, Seen, _Memory, _Name) ->
    Fun(B, Ns, Seen).

%% Move the point of wander a step on its circle. A step that moves the
%% point to the center changes nothing.
wander_point(Point, Step) ->
    Moved = boids_vec:normalize(boids_vec:add(Point, Step)),
    case boids_vec:norm2(Step) == 0 orelse boids_vec:norm2(Moved) == 0 of
        true -> Point;
        false -> Moved
    end.

%% The neighbors of a rule: in its radius, and of its groups.
select(Ns, #{group := Own}, Opts, Radius0, Groups0) ->
    case {maps:get(radius, Opts, Radius0), maps:get(groups, Opts, Groups0)} of
        {infinity, all} -> Ns;
        {infinity, same} -> [N || N = #{group := Group} <- Ns, Group =:= Own];
        {Radius, all} -> [N || N = #{dist := Dist} <- Ns, Dist =< Radius];
        {Radius, Groups} -> [N || N = #{dist := Dist, group := Group} <- Ns, Dist =< Radius, in_groups(Group, Groups, Own)]
    end.

in_groups(Group, same, Own) -> Group =:= Own;
in_groups(Group, Groups, _Own) -> lists:member(Group, Groups).

%% The force of a rule with a target. No target, or a target out of the
%% radius of the rule, gives no force.
to_target(Opts = #{target := Target}, B = #{pos := Pos}, Ns, Seen, Force) ->
    Radius = maps:get(radius, Opts, infinity),
    case target(Target, B, Ns, Seen) of
        {At, Vel} ->
            case boids_vec:dist(Pos, At) =< Radius of
                true -> Force(At, Vel);
                false -> boids_vec:zero(boids_vec:dim(Pos))
            end;
        none ->
            boids_vec:zero(boids_vec:dim(Pos))
    end.

target({boid, Id}, #{id := Id}, _Ns, _Seen) ->
    none;
target({boid, Id}, #{pos := Pos}, Ns, Seen) ->
    case [N || N = #{id := Other} <- Ns, Other =:= Id] of
        [#{pos := At, vel := Vel} | _] ->
            {At, Vel};
        [] ->
            Lookup = maps:get(lookup, Seen, fun(_) -> error end),
            case Lookup(Id) of
                {ok, #{pos := At, vel := Vel}} -> {seen_at(Seen, Pos, At), Vel};
                error -> none
            end
    end;
target({related, Label}, B = #{id := Id}, Ns, Seen) ->
    Related = maps:get(related, Seen, fun(_, _) -> [] end),
    case Related(Id, Label) of
        [To | _] -> target({boid, To}, B, Ns, Seen);
        [] -> none
    end;
target({group, Group}, _B, Ns, _Seen) ->
    case [N || N = #{group := Other} <- Ns, Other =:= Group] of
        [#{pos := At, vel := Vel} | _] -> {At, Vel};
        [] -> none
    end;
target(Point, #{pos := Pos}, _Ns, Seen) ->
    {seen_at(Seen, Pos, Point), boids_vec:zero(boids_vec:dim(Pos))}.

%% With wrap, a boid sees a point at the nearest of its positions.
seen_at(#{wrap := true, bounds := {Min, Max}}, From, To) ->
    boids_vec:add(From, boids_vec:shortest(boids_vec:sub(To, From), Min, Max));
seen_at(_Seen, _From, To) ->
    To.
