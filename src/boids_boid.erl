-module(boids_boid).
-moduledoc """
One boid, as a value: its position, its velocity, its limits and its
rules.

This module has no process and no table. A process holds a boid, and
calls `step/4` with the neighbors that it sees and the time that passed.
`boids_server` is such a process. `boids:join/2` and `boids:advance/3`
do the same for a process of your own.

## The options of a boid

| Option | Default | Description |
|---|---|---|
| `pos` | (necessary) | The position: `{X, Y}` or `{X, Y, Z}`. |
| `vel` | zero | The velocity, in units for each second. |
| `id` | a reference | The name of the boid in its flock. |
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
| `avoid` | `lookahead` (`1.0` second), `clearance` (a tenth of `perception`) | Move around the obstacles of the flock. |
| `contain` | `margin` (`perception`), `bounds` (those of the flock) | Stay in the box. |
| `follow` | `path`, `ahead` (`perception`), `predict` (`0.5` second), `loop` (`false`) | Move along a list of points. |

`groups` is `all`, `same` (the group of the boid) or a list of groups.

`target` is a point, `{boid, Id}` (a boid of the flock) or `{group,
Group}` (the nearest neighbor of that group). A target that does not
exist gives no force.

A rule of your own is `{Fun, Weight}` or `{{Module, Function, Args},
Weight}`. `Fun(Boid, Neighbors, Env)` gives a force, and so does
`Module:Function(Boid, Neighbors, Env, Args...)`. `Env` has `dt` (the
seconds of the step), `obstacles`, `bounds` and `wrap`.

With `combine => sum`, the force is the sum of the forces, each
multiplied by its weight, with the length `max_force` at most. With
`combine => priority`, each rule in the order of the list uses a part of
`max_force`, and the last rules get what stays. Put `avoid` first there.
""".

-export([new/1, update/2, entry/1]).
-export([perceive/2, force/3, integrate/4, step/4]).

-export_type([boid/0, rule/0, target/0, env/0]).

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
    rules := [{rule_name() | custom(), number(), map()}],
    combine := sum | priority,
    memory := map()
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
    | follow.
-type custom() :: fun((boid(), [boids_space:neighbor()], env()) -> vec()) | {module(), atom(), [term()]}.
-type rule() ::
    {rule_name() | custom(), number()} | {rule_name() | custom(), number(), map() | [{atom(), term()}]}.
-type target() :: vec() | {boid, term()} | {group, term()}.
-type env() :: #{
    dt => number(),
    bounds => {vec(), vec()} | undefined,
    wrap => boolean(),
    obstacles => [boids_steer:obstacle()],
    lookup => fun((term()) -> {ok, #{pos := vec(), vel := vec(), _ => _}} | error),
    _ => _
}.

-define(FULL_CIRCLE, 6.283185307179586).

-doc """
Make a boid from its options. A bad option gives the error
`{bad_option, {Key, Value}}`.
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
        memory => #{}
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
        Changed -> Changed
    end.

-doc "The part of a boid that the other boids see: the row of `boids_space`.".
-spec entry(boid()) -> #{id := term(), pos := vec(), vel := vec(), group := term(), data := term()}.
entry(Boid) ->
    maps:with([id, pos, vel, group, data], Boid).

to_map(Opts) when is_map(Opts) -> Opts;
to_map(Opts) when is_list(Opts) ->
    try
        maps:from_list(Opts)
    catch
        error:badarg -> error({bad_option, Opts})
    end;
to_map(Opts) -> error({bad_option, Opts}).

validate(Boid) ->
    Checked = #{pos := Pos, vel := Vel} = maps:map(fun check/2, Boid),
    case {boids_vec:dim(Pos) =:= boids_vec:dim(Vel), Checked} of
        {false, _} -> error({bad_option, {vel, Vel}});
        {true, #{min_speed := Min, max_speed := Max}} when Min > Max -> error({bad_option, {min_speed, Min}});
        {true, _} -> Checked
    end.

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
ok(pos, Pos) -> is_vec(Pos);
ok(vel, Vel) -> is_vec(Vel);
ok(max_speed, N) -> is_number(N) andalso N >= 0;
ok(min_speed, N) -> is_number(N) andalso N >= 0;
ok(max_force, N) -> is_number(N) andalso N >= 0;
ok(mass, N) -> is_number(N) andalso N > 0;
ok(perception, N) -> is_number(N) andalso N >= 0;
ok(fov, N) -> is_number(N) andalso N >= 0;
ok(max_neighbors, N) -> N =:= infinity orelse (is_integer(N) andalso N > 0);
ok(combine, Combine) -> Combine =:= sum orelse Combine =:= priority;
ok(rules, Rules) when is_list(Rules) -> {ok, [rule(Rule) || Rule <- Rules]};
ok(_, _) -> false.

is_vec({X, Y}) -> is_number(X) andalso is_number(Y);
is_vec({X, Y, Z}) -> is_number(X) andalso is_number(Y) andalso is_number(Z);
is_vec(_) -> false.

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
    {Necessary, Optional} = keys(Rule),
    Good =
        Necessary -- maps:keys(Opts) =:= [] andalso
            maps:keys(Opts) -- (Necessary ++ Optional) =:= [] andalso
            lists:all(fun({Key, Value}) -> opt(Name, Key, Value) end, maps:to_list(Opts)),
    Good orelse error({bad_option, {rules, Rule}}),
    Rule;
rule(Rule) ->
    error({bad_option, {rules, Rule}}).

keys({separation, _, _}) -> {[], [radius, groups]};
keys({alignment, _, _}) -> {[], [radius, groups]};
keys({cohesion, _, _}) -> {[], [radius, groups]};
keys({seek, _, _}) -> {[target], []};
keys({flee, _, _}) -> {[target], [radius]};
keys({arrive, _, _}) -> {[target], [slow_radius]};
keys({pursue, _, _}) -> {[target], [max_time]};
keys({evade, _, _}) -> {[target], [radius, max_time]};
keys({wander, _, _}) -> {[], [distance, radius, jitter]};
keys({avoid, _, _}) -> {[], [lookahead, clearance]};
keys({contain, _, _}) -> {[], [bounds, margin]};
keys({follow, _, _}) -> {[path], [ahead, predict, loop]};
keys({Fun, _, _}) when is_function(Fun, 3) -> {[], []};
keys({{Module, Function, Args}, _, _}) when is_atom(Module), is_atom(Function), is_list(Args) -> {[], []};
keys(Rule) -> error({bad_option, {rules, Rule}}).

opt(wander, radius, N) -> is_number(N) andalso N >= 0;
opt(_, radius, N) -> is_distance(N);
opt(_, max_time, N) -> is_distance(N);
opt(_, groups, Groups) -> Groups =:= all orelse Groups =:= same orelse is_list(Groups);
opt(_, target, {boid, _}) -> true;
opt(_, target, {group, _}) -> true;
opt(_, target, Point) -> is_vec(Point);
opt(_, bounds, {Min, Max}) -> is_vec(Min) andalso is_vec(Max) andalso tuple_size(Min) =:= tuple_size(Max);
opt(_, path, Path) -> is_list(Path) andalso Path =/= [] andalso lists:all(fun is_vec/1, Path);
opt(_, loop, Loop) -> is_boolean(Loop);
opt(_, Key, N) when Key =/= bounds -> is_number(N) andalso N >= 0;
opt(_, _, _) -> false.

is_distance(N) -> N =:= infinity orelse (is_number(N) andalso N >= 0).

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
its rules. See the module for `Env`.
""".
-spec force(boid(), [boids_space:neighbor()], env()) -> {vec(), boid()}.
force(Boid = #{rules := Rules, combine := Combine, max_force := MaxForce, pos := Pos}, Neighbors, Env) ->
    {Forces, Boid1} =
        lists:mapfoldl(
            fun({Name, Weight, Opts}, B0) ->
                {Force, B1} = apply_rule(Name, Opts, B0, Neighbors, Env),
                {boids_vec:scale(Force, Weight), B1}
            end,
            Boid,
            Rules
        ),
    Zero = boids_vec:zero(boids_vec:dim(Pos)),
    {combine(Combine, Forces, MaxForce, Zero), Boid1}.

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

apply_rule(separation, Opts, B = #{perception := Perception}, Ns, _Env) ->
    {boids_steer:separation(B, select(Ns, B, Opts, Perception / 2, all)), B};
apply_rule(alignment, Opts, B, Ns, _Env) ->
    {boids_steer:alignment(B, select(Ns, B, Opts, infinity, same)), B};
apply_rule(cohesion, Opts, B, Ns, _Env) ->
    {boids_steer:cohesion(B, select(Ns, B, Opts, infinity, same)), B};
apply_rule(seek, Opts, B, Ns, Env) ->
    to_target(Opts, B, Ns, Env, fun(Pos, _Vel) -> boids_steer:seek(B, Pos) end);
apply_rule(flee, Opts, B, Ns, Env) ->
    to_target(Opts, B, Ns, Env, fun(Pos, _Vel) -> boids_steer:flee(B, Pos) end);
apply_rule(arrive, Opts, B = #{perception := Perception}, Ns, Env) ->
    Slow = maps:get(slow_radius, Opts, Perception),
    to_target(Opts, B, Ns, Env, fun(Pos, _Vel) -> boids_steer:arrive(B, Pos, Slow) end);
apply_rule(pursue, Opts, B, Ns, Env) ->
    Time = maps:get(max_time, Opts, infinity),
    to_target(Opts, B, Ns, Env, fun(Pos, Vel) -> boids_steer:pursue(B, Pos, Vel, Time) end);
apply_rule(evade, Opts, B, Ns, Env) ->
    Time = maps:get(max_time, Opts, infinity),
    to_target(Opts, B, Ns, Env, fun(Pos, Vel) -> boids_steer:evade(B, Pos, Vel, Time) end);
apply_rule(wander, Opts, B = #{pos := Pos, memory := Memory}, _Ns, Env) ->
    Dim = boids_vec:dim(Pos),
    Point0 =
        case Memory of
            #{wander := Known} -> Known;
            _ -> boids_vec:random_unit(Dim)
        end,
    %% The square root makes the change in a second the same for each
    %% length of step.
    Step = maps:get(jitter, Opts, 2.0) * math:sqrt(maps:get(dt, Env, 0.0)),
    Point = wander_point(Point0, boids_vec:scale(boids_vec:random_unit(Dim), Step)),
    Force = boids_steer:wander(B, Point, maps:get(distance, Opts, 2.0), maps:get(radius, Opts, 1.0)),
    {Force, B#{memory := Memory#{wander => Point}}};
apply_rule(avoid, Opts, B = #{pos := Pos, vel := Vel, perception := Perception}, _Ns, Env) ->
    Obstacles = [O#{pos := seen_at(Env, Pos, At)} || O = #{pos := At} <- maps:get(obstacles, Env, [])],
    Ahead = boids_vec:norm(Vel) * maps:get(lookahead, Opts, 1.0),
    {boids_steer:avoid(B, Obstacles, Ahead, maps:get(clearance, Opts, Perception / 10)), B};
apply_rule(contain, Opts, B = #{pos := Pos, perception := Perception}, _Ns, Env) ->
    case maps:get(bounds, Opts, maps:get(bounds, Env, undefined)) of
        undefined -> {boids_vec:zero(boids_vec:dim(Pos)), B};
        Bounds -> {boids_steer:contain(B, Bounds, maps:get(margin, Opts, Perception)), B}
    end;
apply_rule(follow, Opts = #{path := Path}, B = #{perception := Perception}, _Ns, _Env) ->
    Ahead = maps:get(ahead, Opts, Perception),
    Predict = maps:get(predict, Opts, 0.5),
    {boids_steer:follow(B, Path, Ahead, Predict, maps:get(loop, Opts, false)), B};
apply_rule(Fun, _Opts, B, Ns, Env) when is_function(Fun, 3) ->
    {Fun(B, Ns, Env), B};
apply_rule({Module, Function, Args}, _Opts, B, Ns, Env) ->
    {apply(Module, Function, [B, Ns, Env | Args]), B}.

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
    Radius = maps:get(radius, Opts, Radius0),
    Groups = maps:get(groups, Opts, Groups0),
    [N || N = #{dist := Dist, group := Group} <- Ns, Dist =< Radius, in_groups(Group, Groups, Own)].

in_groups(_Group, all, _Own) -> true;
in_groups(Group, same, Own) -> Group =:= Own;
in_groups(Group, Groups, _Own) -> lists:member(Group, Groups).

%% The force of a rule with a target. No target, or a target out of the
%% radius of the rule, gives no force.
to_target(Opts = #{target := Target}, B = #{pos := Pos}, Ns, Env, Force) ->
    Radius = maps:get(radius, Opts, infinity),
    case target(Target, B, Ns, Env) of
        {At, Vel} ->
            case boids_vec:dist(Pos, At) =< Radius of
                true -> {Force(At, Vel), B};
                false -> {boids_vec:zero(boids_vec:dim(Pos)), B}
            end;
        none ->
            {boids_vec:zero(boids_vec:dim(Pos)), B}
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
