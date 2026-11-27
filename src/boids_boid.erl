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
| `id` | a reference | The name of the boid in its space. |
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
| `avoid` | `lookahead` (`1.0` second), `clearance` (a tenth of `perception`) | Move around the obstacles of the space. |
| `contain` | `margin` (`perception`), `bounds` (those of the space) | Stay in the box. |
| `follow` | `path`, `ahead` (`perception`), `predict` (`0.5` second), `loop` (`false`) | Move along a list of points. |
| `cruise` | `speed` (`max_speed`) | Keep a speed in the direction of the movement. |
| `leader` | `target`, `distance` (half of `perception`), `slow_radius` (`perception`) | Stay behind a leader, and move out of its way. |
| `dodge` | `radius` (a quarter of `perception`), `horizon` (`2.0` seconds), `groups` (`all`) | Move away from a neighbor that comes too near in the time of the horizon. |
| `flow` | `field`, `predict` (`0.5` second) | Move in the direction of a field: a vector, or a function of a position. |

`groups` is `all`, `same` (the group of the boid) or a list of groups.

`target` is a point, `{boid, Id}` (a boid of the space), `{group,
Group}` (the nearest neighbor of that group) or `{related, Label}` (the
boid that this boid has the relation `Label` to, see `boids:relate/4`).
A target that does not exist gives no force.

A rule of your own is a function: `{Fun, Weight}`, where `Fun(Boid,
Neighbors, Env)` gives the force. `Neighbors` are the boids that the
boid sees, the nearest first. `Env` has `dt` (the seconds of the step),
`obstacles`, `bounds` and `wrap`. Use `fun Module:Function/3` for a rule
that stays when the code of the module changes.

A boid can have a rule of the library two times, for example two
targets of `seek`. Give a name to each one: `{{seek, home}, 1.0,
#{target => {0, 0}}}`. The name of a rule is its first part: `seek`,
`{seek, home}` or the function. `add_rule/2` and `delete_rule/2` use it.

With `combine => sum`, the force is the sum of the forces, each
multiplied by its weight, with the length `max_force` at most. With
`combine => priority`, each rule in the order of the list uses a part of
`max_force`, and the last rules get what stays. Put `avoid` first there.
""".

-export([new/1, update/2, options/1, entry/1, to_map/1]).
-export([add_rule/2, delete_rule/2, which_rules/1]).
-export([perceive/2, force/3, integrate/4, step/4]).

-export_type([boid/0, rule/0, name/0, target/0, env/0]).

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
    | flow.
-type name() ::
    rule_name()
    | {rule_name(), Id :: term()}
    | fun((boid(), [boids_space:neighbor()], env()) -> vec()).
-type rule() :: {name(), number()} | {name(), number(), map() | [{atom(), term()}]}.
-type target() :: vec() | {boid, term()} | {group, term()} | {related, term()}.
-type env() :: #{
    dt => number(),
    bounds => {vec(), vec()} | undefined,
    wrap => boolean(),
    obstacles => [boids_steer:obstacle()],
    lookup => fun((term()) -> {ok, #{pos := vec(), vel := vec(), _ => _}} | error),
    related => fun((term(), term()) -> [term()]),
    _ => _
}.

-define(FULL_CIRCLE, 6.283185307179586).

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
and not the values together. `boids:start_space/1` checks the `defaults`
of a space with this function.
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
ok(rules, Rules) when is_list(Rules) -> {ok, [rule(Rule) || Rule <- Rules]};
ok(_, _) -> false.

%% --- The rules: the check ---------------------------------------------

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

%% --- One step ---------------------------------------------------------

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
The force of all the rules of a boid, and the boid with the memory of
its rules (the point of `wander`). See the module for `Env`.
""".
-spec force(boid(), [boids_space:neighbor()], env()) -> {vec(), boid()}.
force(Boid = #{rules := Rules, memory := Memory0, combine := Combine, max_force := MaxForce, pos := Pos}, Neighbors, Env) ->
    {Forces, Memory} =
        lists:mapfoldl(
            fun({Name, Weight, Opts}, Memory1) ->
                case apply_rule(base(Name), Opts, Boid, Neighbors, Env, Memory1, Name) of
                    %% A force is a tuple of numbers. Only a rule of the
                    %% library keeps a memory.
                    {Force, Kept} when is_tuple(Force), not is_function(Name) ->
                        {boids_vec:scale(Force, Weight), Memory1#{Name => Kept}};
                    Force ->
                        {boids_vec:scale(Force, Weight), Memory1}
                end
            end,
            Memory0,
            Rules
        ),
    Zero = boids_vec:zero(boids_vec:dim(Pos)),
    Force = combine(Combine, Forces, MaxForce, Zero),
    %% Most boids have no rule with a memory: the boid does not change.
    case Memory =:= Memory0 of
        true -> {Force, Boid};
        false -> {Force, Boid#{memory := Memory}}
    end.

combine(sum, Forces, MaxForce, Zero) ->
    boids_vec:limit(lists:foldl(fun boids_vec:add/2, Zero, Forces), MaxForce);
combine(priority, [Force | Rest], Left, Acc) when Left > 0 ->
    Part = boids_vec:limit(Force, Left),
    combine(priority, Rest, Left - boids_vec:norm(Part), boids_vec:add(Acc, Part));
combine(priority, _Forces, _Left, Acc) ->
    Acc.

-doc """
Move a boid for `Dt` seconds with a force. The speed stays in the limits
of the boid. With `wrap` in `Env`, the position stays in the box.
""".
-spec integrate(boid(), vec(), env(), number()) -> boid().
integrate(Boid, _Force, _Env, Dt) when Dt =< 0 ->
    Boid;
integrate(Boid = #{pos := Pos, vel := Vel, mass := Mass}, Force, Env, Dt) ->
    Vel1 = speed(boids_vec:add(Vel, boids_vec:scale(Force, Dt / Mass)), Boid),
    Pos1 = boids_vec:add(Pos, boids_vec:scale(Vel1, Dt)),
    Boid#{pos := place(Env, Pos1), vel := Vel1}.

speed(Vel, #{min_speed := Min, max_speed := Max}) ->
    case boids_vec:norm(Vel) of
        Speed when Speed > Max -> boids_vec:scale(Vel, Max / Speed);
        Speed when Speed < Min, Speed > 0 -> boids_vec:scale(Vel, Min / Speed);
        _ -> Vel
    end.

place(#{wrap := true, bounds := {Min, Max}}, Pos) -> boids_vec:wrap(Pos, Min, Max);
place(_Env, Pos) -> Pos.

-doc """
One step of a boid: the force of its rules, then the movement for `Dt`
seconds. `Neighbors` is the result of `perceive/2`.
""".
-spec step(boid(), [boids_space:neighbor()], env(), number()) -> boid().
step(Boid, _Neighbors, _Env, Dt) when Dt =< 0 ->
    Boid;
step(Boid, Neighbors, Env, Dt) ->
    {Force, Boid1} = force(Boid, Neighbors, Env#{dt => Dt}),
    integrate(Boid1, Force, Env, Dt).

%% --- The rules: the forces --------------------------------------------

%% The force of one rule, or {Force, Kept} for a rule that keeps a
%% memory: the boid has it for the name of the rule at the next step.
apply_rule(separation, Opts, B = #{perception := Perception}, Ns, _Env, _Memory, _Name) ->
    boids_steer:separation(B, select(Ns, B, Opts, Perception / 2, all));
apply_rule(alignment, Opts, B, Ns, _Env, _Memory, _Name) ->
    boids_steer:alignment(B, select(Ns, B, Opts, infinity, same));
apply_rule(cohesion, Opts, B, Ns, _Env, _Memory, _Name) ->
    boids_steer:cohesion(B, select(Ns, B, Opts, infinity, same));
apply_rule(seek, Opts, B, Ns, Env, _Memory, _Name) ->
    to_target(Opts, B, Ns, Env, fun(Pos, _Vel) -> boids_steer:seek(B, Pos) end);
apply_rule(flee, Opts, B, Ns, Env, _Memory, _Name) ->
    to_target(Opts, B, Ns, Env, fun(Pos, _Vel) -> boids_steer:flee(B, Pos) end);
apply_rule(arrive, Opts, B = #{perception := Perception}, Ns, Env, _Memory, _Name) ->
    Slow = maps:get(slow_radius, Opts, Perception),
    to_target(Opts, B, Ns, Env, fun(Pos, _Vel) -> boids_steer:arrive(B, Pos, Slow) end);
apply_rule(pursue, Opts, B, Ns, Env, _Memory, _Name) ->
    Time = maps:get(max_time, Opts, infinity),
    to_target(Opts, B, Ns, Env, fun(Pos, Vel) -> boids_steer:pursue(B, Pos, Vel, Time) end);
apply_rule(evade, Opts, B, Ns, Env, _Memory, _Name) ->
    Time = maps:get(max_time, Opts, infinity),
    to_target(Opts, B, Ns, Env, fun(Pos, Vel) -> boids_steer:evade(B, Pos, Vel, Time) end);
apply_rule(wander, Opts, B = #{pos := Pos}, _Ns, Env, Memory, Name) ->
    Dim = boids_vec:dim(Pos),
    Point0 =
        case Memory of
            #{Name := Known} -> Known;
            _ -> boids_vec:random_unit(Dim)
        end,
    %% The square root makes the change in a second the same for each
    %% length of step.
    Step = maps:get(jitter, Opts, 2.0) * math:sqrt(maps:get(dt, Env, 0.0)),
    Point = wander_point(Point0, boids_vec:scale(boids_vec:random_unit(Dim), Step)),
    {boids_steer:wander(B, Point, maps:get(distance, Opts, 2.0), maps:get(radius, Opts, 1.0)), Point};
apply_rule(avoid, Opts, B = #{pos := Pos, vel := Vel, perception := Perception}, _Ns, Env, _Memory, _Name) ->
    %% A boid does not see an obstacle with a center of another size.
    Obstacles = [
        O#{pos := seen_at(Env, Pos, At)}
     || O = #{pos := At} <- maps:get(obstacles, Env, []), tuple_size(At) =:= tuple_size(Pos)
    ],
    Ahead = boids_vec:norm(Vel) * maps:get(lookahead, Opts, 1.0),
    boids_steer:avoid(B, Obstacles, Ahead, maps:get(clearance, Opts, Perception / 10));
apply_rule(contain, Opts, B = #{pos := Pos, perception := Perception}, _Ns, Env, _Memory, _Name) ->
    case maps:get(bounds, Opts, maps:get(bounds, Env, undefined)) of
        undefined -> boids_vec:zero(boids_vec:dim(Pos));
        Bounds -> boids_steer:contain(B, Bounds, maps:get(margin, Opts, Perception))
    end;
apply_rule(follow, Opts = #{path := Path}, B = #{perception := Perception}, _Ns, _Env, _Memory, _Name) ->
    Ahead = maps:get(ahead, Opts, Perception),
    Predict = maps:get(predict, Opts, 0.5),
    boids_steer:follow(B, Path, Ahead, Predict, maps:get(loop, Opts, false));
apply_rule(cruise, Opts, B = #{max_speed := Max}, _Ns, _Env, _Memory, _Name) ->
    boids_steer:cruise(B, maps:get(speed, Opts, Max));
apply_rule(leader, Opts, B = #{perception := Perception}, Ns, Env, _Memory, _Name) ->
    Distance = maps:get(distance, Opts, Perception / 2),
    Slow = maps:get(slow_radius, Opts, Perception),
    to_target(Opts, B, Ns, Env, fun(Pos, Vel) -> boids_steer:leader(B, Pos, Vel, Distance, Slow) end);
apply_rule(dodge, Opts, B = #{perception := Perception}, Ns, _Env, _Memory, _Name) ->
    Near = select(Ns, B, maps:remove(radius, Opts), infinity, all),
    boids_steer:dodge(B, Near, maps:get(radius, Opts, Perception / 4), maps:get(horizon, Opts, 2.0));
apply_rule(flow, Opts = #{field := Field}, B = #{pos := Pos, vel := Vel}, _Ns, _Env, _Memory, _Name) ->
    Direction =
        case is_function(Field) of
            true -> Field(boids_vec:add(Pos, boids_vec:scale(Vel, maps:get(predict, Opts, 0.5))));
            false -> Field
        end,
    boids_steer:flow(B, Direction);
apply_rule(Fun, _Opts, B, Ns, Env, _Memory, _Name) ->
    Fun(B, Ns, Env).

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
to_target(Opts = #{target := Target}, B = #{pos := Pos}, Ns, Env, Force) ->
    Radius = maps:get(radius, Opts, infinity),
    case target(Target, B, Ns, Env) of
        {At, Vel} ->
            case boids_vec:dist(Pos, At) =< Radius of
                true -> Force(At, Vel);
                false -> boids_vec:zero(boids_vec:dim(Pos))
            end;
        none ->
            boids_vec:zero(boids_vec:dim(Pos))
    end.

target({boid, Id}, #{id := Id}, _Ns, _Env) ->
    none;
target({boid, Id}, #{pos := Pos}, Ns, Env) ->
    case [N || N = #{id := Other} <- Ns, Other =:= Id] of
        [#{pos := At, vel := Vel} | _] ->
            {At, Vel};
        [] ->
            Lookup = maps:get(lookup, Env, fun(_) -> error end),
            case Lookup(Id) of
                {ok, #{pos := At, vel := Vel}} -> {seen_at(Env, Pos, At), Vel};
                error -> none
            end
    end;
target({related, Label}, B = #{id := Id}, Ns, Env) ->
    Related = maps:get(related, Env, fun(_, _) -> [] end),
    case Related(Id, Label) of
        [To | _] -> target({boid, To}, B, Ns, Env);
        [] -> none
    end;
target({group, Group}, _B, Ns, _Env) ->
    case [N || N = #{group := Other} <- Ns, Other =:= Group] of
        [#{pos := At, vel := Vel} | _] -> {At, Vel};
        [] -> none
    end;
target(Point, #{pos := Pos}, _Ns, Env) ->
    {seen_at(Env, Pos, Point), boids_vec:zero(boids_vec:dim(Pos))}.

%% With wrap, a boid sees a point at the nearest of its positions.
seen_at(#{wrap := true, bounds := {Min, Max}}, From, To) ->
    boids_vec:add(From, boids_vec:shortest(boids_vec:sub(To, From), Min, Max));
seen_at(_Env, _From, To) ->
    To.
