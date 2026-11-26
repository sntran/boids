-module(boids_boid).
-moduledoc """
One boid, as a value: its position, its velocity, its limits and its
rules.

This module has no process and no table. A process holds a boid, and
calls `step/4` with the neighbors that it sees and the time that passed.
`gen_boid` is such a process. `boids:join/2` and `boids:advance/3` do
the same for a process that has another behavior.

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
| `cruise` | `speed` (`max_speed`) | Keep a speed in the direction of the movement. |
| `leader` | `target`, `distance` (half of `perception`), `slow_radius` (`perception`) | Stay behind a leader, and move out of its way. |
| `dodge` | `radius` (a quarter of `perception`), `horizon` (`2.0` seconds), `groups` (`all`) | Move away from a neighbor that comes too near in the time of the horizon. |
| `flow` | `field`, `predict` (`0.5` second) | Move in the direction of a field: a vector, or a function of a position. |

`groups` is `all`, `same` (the group of the boid) or a list of groups.

`target` is a point, `{boid, Id}` (a boid of the flock) or `{group,
Group}` (the nearest neighbor of that group). A target that does not
exist gives no force.

A rule of your own is a module with the behavior `gen_boid`, as
`{Module, Weight}` or `{Module, Weight, Args}`: see `gen_boid`. A
function is a rule too: `{Fun, Weight}`, where `Fun(Boid, Neighbors,
Env)` gives the force. `Env` has `dt` (the seconds of the step),
`obstacles`, `bounds` and `wrap`.

A boid can have a rule two times, for example two targets of `seek`.
Give a name to each one: `{{seek, home}, 1.0, #{target => {0, 0}}}`. The
name of a rule is its first part: `seek`, `{seek, home}`, `my_module` or
`{my_module, 1}`. `add_rule/2`, `delete_rule/3` and `call_rule/3` use it.

In the boid, each rule is `{Name, Weight, Options, State}`. `State` is
the state of a module of yours, or the memory of a rule of the library.

With `combine => sum`, the force is the sum of the forces, each
multiplied by its weight, with the length `max_force` at most. With
`combine => priority`, each rule in the order of the list uses a part of
`max_force`, and the last rules get what stays. Put `avoid` first there.
""".

-export([new/1, update/2, options/1, entry/1, to_map/1]).
-export([add_rule/2, delete_rule/3, which_rules/1, call_rule/3, info/2, terminate/2]).
-export([perceive/2, force/3, integrate/4, step/4]).

-export_type([boid/0, rule/0, name/0, target/0, env/0, action/0]).

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
    rules := [{name(), number(), term(), term()}],
    combine := sum | priority,
    %% A rule asked to stop the boid, with this reason.
    stop => term()
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
    | module()
    | {rule_name() | module(), Id :: term()}
    | fun((boid(), [boids_space:neighbor()], env()) -> vec()).
-type rule() :: {name(), number()} | {name(), number(), term()}.
-type target() :: vec() | {boid, term()} | {group, term()}.
-type env() :: #{
    dt => number(),
    bounds => {vec(), vec()} | undefined,
    wrap => boolean(),
    obstacles => [boids_steer:obstacle()],
    lookup => fun((term()) -> {ok, #{pos := vec(), vel := vec(), _ => _}} | error),
    _ => _
}.
-type action() ::
    {set, map() | [{atom(), term()}]}
    | {add_rule, rule()}
    | {delete_rule, name()}
    | {delete_rule, name(), term()}
    | stop
    | {stop, term()}.

-define(FULL_CIRCLE, 6.283185307179586).

-doc """
Make a boid from its options. A bad option gives the error
`{bad_option, {Key, Value}}`. Each number is 1.0e100 at most, and each
vector of a rule has the size of the position.

Each rule that is a module of yours starts here: `Module:init(Args)`
runs in the process that calls this function.
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
        combine => sum
    },
    start(validate(maps:merge(Base, Opts))).

-doc """
Change options of a boid. The id and the size of the position do not
change. A bad option gives the error `{bad_option, {Key, Value}}`.

The option `rules` gives all the rules of the boid again. A rule of the
boid that is not in the new list stops (`terminate(replaced, State)` for
a module), and a new rule starts. To keep a rule with its state, put it
in the list as it is in the boid. To change one rule, use `add_rule/2`
and `delete_rule/3`.
""".
-spec update(boid(), map() | [{atom(), term()}]) -> boid().
update(Boid = #{pos := Old, rules := Rules0}, Changes0) ->
    Changes = to_map(Changes0),
    [error({bad_option, {Key, maps:get(Key, Changes)}}) || Key <- [id, stop], is_map_key(Key, Changes)],
    case validate(maps:merge(Boid, Changes)) of
        #{pos := New} when tuple_size(New) =/= tuple_size(Old) ->
            error({bad_option, {pos, New}});
        Checked ->
            Changed = #{rules := Rules} = start(Checked),
            _ = [stop_rule(Rule, replaced) || Rule <- Rules0 -- Rules],
            Changed
    end.

-doc """
Check options with no boid, and give them as a map: each value alone,
and not the values together. No rule starts. `boids:start_flock/1`
checks the `defaults` of a flock with this function.
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

%% The check of the options together. The rules do not start here.
validate(Boid) ->
    Checked = #{pos := Pos, vel := Vel, rules := Rules} = maps:map(fun check/2, Boid),
    Dim = tuple_size(Pos),
    [error({bad_option, {rules, Rule}}) || Rule <- Rules, not sized(Rule, Dim)],
    case {Dim =:= tuple_size(Vel), Checked} of
        {false, _} -> error({bad_option, {vel, Vel}});
        {true, #{min_speed := Min, max_speed := Max}} when Min > Max -> error({bad_option, {min_speed, Min}});
        {true, _} -> Checked
    end.

%% The vectors of a rule of the library have the size of the position.
sized(Rule, Dim) ->
    Opts = element(3, Rule),
    case kind(element(1, Rule)) of
        {builtin, _} ->
            Vectors =
                [Point || #{target := Point} <- [Opts], is_tuple(Point), not is_atom(element(1, Point))] ++
                    [Vector || #{field := Vector} <- [Opts], is_tuple(Vector)] ++
                    [Corner || #{bounds := {Min, Max}} <- [Opts], Corner <- [Min, Max]] ++
                    maps:get(path, Opts, []),
            lists:all(fun(Vector) -> tuple_size(Vector) =:= Dim end, Vectors);
        _ ->
            true
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
ok(stop, _) -> true;
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
ok(rules, Rules) when is_list(Rules) -> {ok, [check_rule(Rule) || Rule <- Rules]};
ok(_, _) -> false.

%% --- The rules: the check, the start and the end ----------------------

%% A rule of the library, a module of the user, or a function.
kind(Fun) when is_function(Fun, 3) -> function;
kind({Base, _Id}) when is_atom(Base) -> kind(Base);
kind(Base) when is_atom(Base) ->
    case keys(Base) of
        custom -> {module, Base};
        _ -> {builtin, Base}
    end;
kind(_) ->
    bad.

%% Check a rule, with no start: {Name, Weight, Options}. A rule that is
%% in a boid ({Name, Weight, Options, State}) stays as it is.
check_rule(Rule = {_Name, Weight, _Opts, _State}) when is_number(Weight) ->
    Rule;
check_rule({Name, Weight}) ->
    check_rule({Name, Weight, #{}});
check_rule(Rule = {Name, Weight, Opts}) when is_number(Weight) ->
    case kind(Name) of
        {builtin, Base} ->
            Map = rule_options(Opts, Rule),
            {Necessary, Optional} = keys(Base),
            Good =
                Necessary -- maps:keys(Map) =:= [] andalso
                    maps:keys(Map) -- (Necessary ++ Optional) =:= [] andalso
                    lists:all(fun({Key, Value}) -> opt(Base, Key, Value) end, maps:to_list(Map)),
            Good orelse error({bad_option, {rules, Rule}}),
            {Name, Weight, Map};
        function when Opts =:= #{} ->
            Rule;
        {module, Module} ->
            _ = code:ensure_loaded(Module),
            Good = erlang:function_exported(Module, init, 1) andalso erlang:function_exported(Module, handle_step, 4),
            Good orelse error({bad_option, {rules, Rule}}),
            Rule;
        _ ->
            error({bad_option, {rules, Rule}})
    end;
check_rule(Rule) ->
    error({bad_option, {rules, Rule}}).

%% The options of a rule of the library are a map, or a list of pairs.
rule_options(Opts, _Rule) when is_map(Opts) ->
    Opts;
rule_options(Opts, Rule) when is_list(Opts) ->
    try
        maps:from_list(Opts)
    catch
        error:badarg -> error({bad_option, {rules, Rule}})
    end;
rule_options(_Opts, Rule) ->
    error({bad_option, {rules, Rule}}).

%% Start each rule of a boid that did not start. When a rule does not
%% start, the rules that started before it stop.
start(Boid = #{rules := Rules}) ->
    Boid#{rules := start_rules(Rules, [])}.

start_rules([Rule = {_, _, _} | Rest], Started) ->
    case start_rule(Rule) of
        {ok, Entry} ->
            start_rules(Rest, [{new, Entry} | Started]);
        {error, _Reason} ->
            _ = [stop_rule(Entry, replaced) || {new, Entry} <- Started],
            error({bad_option, {rules, Rule}})
    end;
start_rules([Entry | Rest], Started) ->
    start_rules(Rest, [{old, Entry} | Started]);
start_rules([], Started) ->
    [Entry || {_, Entry} <- lists:reverse(Started)].

start_rule({Name, Weight, Opts}) ->
    case kind(Name) of
        {module, Module} ->
            try Module:init(Opts) of
                {ok, State} -> {ok, {Name, Weight, Opts, State}};
                {error, Reason} -> {error, Reason};
                Other -> {error, {bad_return, Other}}
            catch
                Class:Reason when Class =/= exit -> {error, Reason}
            end;
        _ ->
            {ok, {Name, Weight, Opts, undefined}}
    end.

%% The end of a rule: terminate/2 of a module that has it.
stop_rule({Name, _Weight, _Opts, State}, Arg) ->
    case kind(Name) of
        {module, Module} ->
            case erlang:function_exported(Module, terminate, 2) of
                true -> Module:terminate(Arg, State);
                false -> ok
            end;
        _ ->
            ok
    end.

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
opt(_, target, Point) -> boids_vec:is_vec(Point);
opt(_, bounds, {Min, Max}) -> boids_vec:is_box(Min, Max);
opt(_, path, Path) -> is_list(Path) andalso Path =/= [] andalso lists:all(fun boids_vec:is_vec/1, Path);
opt(_, loop, Loop) -> is_boolean(Loop);
opt(_, field, Field) -> is_function(Field, 1) orelse boids_vec:is_vec(Field);
opt(_, Key, N) when Key =/= bounds -> boids_vec:is_size(N);
opt(_, _, _) -> false.

is_distance(N) -> N =:= infinity orelse boids_vec:is_size(N).

%% --- The rules of a boid that runs ------------------------------------

-doc """
Add a rule at the end of the rules of a boid: `{Name, Weight}` or
`{Name, Weight, Options}`. A module of yours starts: `Module:init(Args)`.
The result is `{ok, Boid}`, or `{error, Reason}` for a bad rule and for
a module that does not start.
""".
-spec add_rule(boid(), rule()) -> {ok, boid()} | {error, term()}.
add_rule(Boid = #{pos := Pos, rules := Rules}, Rule) ->
    try
        Checked = check_rule(Rule),
        sized(Checked, tuple_size(Pos)) orelse error({bad_option, {rules, Rule}}),
        Checked
    of
        Entry = {_, _, _, _} ->
            {ok, Boid#{rules := Rules ++ [Entry]}};
        Checked ->
            case start_rule(Checked) of
                {ok, Entry} -> {ok, Boid#{rules := Rules ++ [Entry]}};
                {error, Reason} -> {error, Reason}
            end
    catch
        error:{bad_option, _} = Reason -> {error, Reason}
    end.

-doc """
Remove the first rule with the name `Name` from a boid. For a module of
yours with `terminate/2`, the result has what `Module:terminate(Args,
State)` gives. For the other rules it has `ok`.
""".
-spec delete_rule(boid(), name(), term()) -> {ok, term(), boid()} | {error, not_found}.
delete_rule(Boid = #{rules := Rules}, Name, Args) ->
    case lists:keytake(Name, 1, Rules) of
        {value, Rule, Rest} -> {ok, stop_rule(Rule, Args), Boid#{rules := Rest}};
        false -> {error, not_found}
    end.

-doc "The names of the rules of a boid, in their order.".
-spec which_rules(boid()) -> [name()].
which_rules(#{rules := Rules}) ->
    [Name || {Name, _, _, _} <- Rules].

-doc """
Send a request to a rule of a boid that is a module of yours:
`Module:handle_call(Request, Boid, State)` gives the answer. The result
is the answer and the boid. The answer is `{error, bad_rule}` when the
boid has no such rule, or the rule has no `handle_call/3`, and `{error,
{failed, Reason}}` when the rule failed (the boid then has no such
rule).
""".
-spec call_rule(boid(), name(), term()) -> {term(), boid()}.
call_rule(Boid = #{rules := Rules}, Name, Request) ->
    case {lists:keyfind(Name, 1, Rules), kind(Name)} of
        {Rule = {_, _, _, State}, {module, Module}} ->
            case erlang:function_exported(Module, handle_call, 3) of
                true ->
                    try Module:handle_call(Request, Boid, State) of
                        {ok, Reply, State1} ->
                            {Reply, keep(Boid, Rule, State1)};
                        {ok, Reply, State1, Actions} ->
                            {Reply, actions(keep(Boid, Rule, State1), Actions)};
                        {remove_rule, Reply} ->
                            _ = stop_rule(Rule, remove_rule),
                            {Reply, drop(Boid, Rule)};
                        Other ->
                            {{error, {failed, {bad_return, Other}}}, failed(Boid, Rule, {bad_return, Other})}
                    catch
                        Class:Reason when Class =/= exit ->
                            {{error, {failed, Reason}}, failed(Boid, Rule, Reason)}
                    end;
                false ->
                    {{error, bad_rule}, Boid}
            end;
        _ ->
            {{error, bad_rule}, Boid}
    end.

-doc """
Give a message to each rule of a boid that is a module of yours with
`handle_info/3`. The result is the boid.
""".
-spec info(boid(), term()) -> boid().
info(Boid0 = #{rules := Rules}, Info) ->
    {Boid, Actions} =
        lists:foldl(
            fun(Rule = {Name, _, _, State}, {Boid1, Actions1}) ->
                case kind(Name) of
                    {module, Module} ->
                        case erlang:function_exported(Module, handle_info, 3) of
                            true -> told(Rule, Boid1, Actions1, fun() -> Module:handle_info(Info, Boid0, State) end);
                            false -> {Boid1, Actions1}
                        end;
                    _ ->
                        {Boid1, Actions1}
                end
            end,
            {Boid0, []},
            Rules
        ),
    actions(Boid, Actions).

told(Rule, Boid, Actions, Call) ->
    try Call() of
        {ok, State} ->
            {keep(Boid, Rule, State), Actions};
        {ok, State, More} when is_list(More) ->
            {keep(Boid, Rule, State), Actions ++ More};
        remove_rule ->
            _ = stop_rule(Rule, remove_rule),
            {drop(Boid, Rule), Actions};
        Other ->
            {failed(Boid, Rule, {bad_return, Other}), Actions}
    catch
        Class:Reason when Class =/= exit -> {failed(Boid, Rule, Reason), Actions}
    end.

-doc """
The end of a boid: each rule that is a module of yours with
`terminate/2` gets `Module:terminate(Arg, State)`.
""".
-spec terminate(boid(), term()) -> ok.
terminate(#{rules := Rules}, Arg) ->
    _ = [stop_rule(Rule, Arg) || Rule <- Rules],
    ok.

%% Put the new state of a rule into the boid.
keep(Boid = #{rules := Rules}, Rule = {Name, Weight, Opts, _}, State) ->
    Boid#{rules := replace(Rules, Rule, {Name, Weight, Opts, State})}.

drop(Boid = #{rules := Rules}, Rule) ->
    Boid#{rules := lists:delete(Rule, Rules)}.

replace([Rule | Rest], Rule, New) -> [New | Rest];
replace([Other | Rest], Rule, New) -> [Other | replace(Rest, Rule, New)].

%% A rule that fails is removed, as a handler of gen_event is. The boid
%% continues with its other rules.
failed(Boid, Rule, Reason) ->
    report(Boid, Rule, Reason),
    drop(Boid, Rule).

report(#{id := Id}, Rule = {Name, _, _, _}, Reason) ->
    logger:error("boids: the rule ~tp of the boid ~tp failed, and the boid has it no more: ~tp", [Name, Id, Reason]),
    try
        stop_rule(Rule, {error, Reason})
    catch
        _:_ -> ok
    end.

%% Do the actions that a rule asked for.
actions(Boid, Actions) ->
    lists:foldl(fun action/2, Boid, Actions).

action({set, Options}, Boid) ->
    update(Boid, Options);
action({add_rule, Rule}, Boid) ->
    case add_rule(Boid, Rule) of
        {ok, Added} -> Added;
        {error, Reason} -> error({bad_action, {add_rule, Rule}, Reason})
    end;
action({delete_rule, Name}, Boid) ->
    action({delete_rule, Name, remove_rule}, Boid);
action({delete_rule, Name, Args}, Boid) ->
    case delete_rule(Boid, Name, Args) of
        {ok, _Result, Deleted} -> Deleted;
        {error, not_found} -> Boid
    end;
action(stop, Boid) ->
    Boid#{stop => normal};
action({stop, Reason}, Boid) ->
    Boid#{stop => Reason};
action(Action, _Boid) ->
    error({bad_action, Action}).

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
The force of all the rules of a boid, and the boid with the new states
of its rules. See the module for `Env`.

A rule of yours that fails gives no force, and the boid has it no more:
the log gets an error.
""".
-spec force(boid(), [boids_space:neighbor()], env()) -> {vec(), boid()}.
force(Boid0 = #{rules := Rules, combine := Combine, max_force := MaxForce, pos := Pos}, Neighbors, Env) ->
    Zero = boids_vec:zero(tuple_size(Pos)),
    {Forces, {Kept, Actions}} =
        lists:mapfoldl(
            fun(Rule, {Kept1, Actions1}) ->
                case run_rule(Rule, Boid0, Neighbors, Env, Zero) of
                    {Force, removed, More} -> {Force, {Kept1, Actions1 ++ More}};
                    {Force, Rule1, More} -> {Force, {[Rule1 | Kept1], Actions1 ++ More}}
                end
            end,
            {[], []},
            Rules
        ),
    Boid = actions(Boid0#{rules := lists:reverse(Kept)}, Actions),
    {combine(Combine, Forces, MaxForce, Zero), Boid}.

%% The force of one rule with its weight, the rule with its new state
%% (or removed), and the actions that it asked for.
run_rule(Rule = {Name, Weight, Opts, State}, Boid, Ns, Env, Zero) ->
    case kind(Name) of
        {builtin, Base} ->
            case apply_rule(Base, Opts, Boid, Ns, Env, State) of
                %% A force is a tuple of numbers.
                {Force, Memory} when is_tuple(Force) ->
                    {boids_vec:scale(Force, Weight), {Name, Weight, Opts, Memory}, []};
                Force ->
                    {boids_vec:scale(Force, Weight), Rule, []}
            end;
        function ->
            ran(Rule, Boid, Zero, fun() -> {force, Name(Boid, Ns, Env), State} end);
        {module, Module} ->
            ran(Rule, Boid, Zero, fun() -> Module:handle_step(Boid, Ns, Env, State) end)
    end.

ran(Rule = {Name, Weight, Opts, _State}, Boid, Zero, Call) ->
    try Call() of
        {force, Force, State} ->
            forced(Force, Rule, {Name, Weight, Opts, State}, [], Boid, Zero);
        {force, Force, State, Actions} when is_list(Actions) ->
            forced(Force, Rule, {Name, Weight, Opts, State}, Actions, Boid, Zero);
        {ok, State} ->
            {Zero, {Name, Weight, Opts, State}, []};
        {ok, State, Actions} when is_list(Actions) ->
            {Zero, {Name, Weight, Opts, State}, Actions};
        remove_rule ->
            _ = stop_rule(Rule, remove_rule),
            {Zero, removed, []};
        Other ->
            report(Boid, Rule, {bad_return, Other}),
            {Zero, removed, []}
    catch
        Class:Reason when Class =/= exit ->
            report(Boid, Rule, Reason),
            {Zero, removed, []}
    end.

%% A force of a rule of the user must be a vector of the size of the boid.
forced(Force, Rule, {_, Weight, _, _} = Next, Actions, Boid, Zero) ->
    case boids_vec:is_vec(Force) andalso tuple_size(Force) =:= tuple_size(Zero) of
        true ->
            {boids_vec:scale(Force, Weight), Next, Actions};
        false ->
            report(Boid, Rule, {bad_force, Force}),
            {Zero, removed, []}
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

When a rule asked to stop the boid, the result has the key `stop` with
the reason: the process of the boid stops then.
""".
-spec step(boid(), [boids_space:neighbor()], env(), number()) -> boid().
step(Boid, _Neighbors, _Env, Dt) when Dt =< 0 ->
    Boid;
step(Boid, Neighbors, Env, Dt) ->
    {Force, Boid1} = force(Boid, Neighbors, Env#{dt => Dt}),
    integrate(Boid1, Force, Env, Dt).

%% --- The rules: the forces --------------------------------------------

%% The force of one rule of the library, or {Force, Memory} for a rule
%% that keeps a memory. Memory is the memory that the rule gave at the
%% last step.
apply_rule(separation, Opts, B = #{perception := Perception}, Ns, _Env, _Memory) ->
    boids_steer:separation(B, select(Ns, B, Opts, Perception / 2, all));
apply_rule(alignment, Opts, B, Ns, _Env, _Memory) ->
    boids_steer:alignment(B, select(Ns, B, Opts, infinity, same));
apply_rule(cohesion, Opts, B, Ns, _Env, _Memory) ->
    boids_steer:cohesion(B, select(Ns, B, Opts, infinity, same));
apply_rule(seek, Opts, B, Ns, Env, _Memory) ->
    to_target(Opts, B, Ns, Env, fun(Pos, _Vel) -> boids_steer:seek(B, Pos) end);
apply_rule(flee, Opts, B, Ns, Env, _Memory) ->
    to_target(Opts, B, Ns, Env, fun(Pos, _Vel) -> boids_steer:flee(B, Pos) end);
apply_rule(arrive, Opts, B = #{perception := Perception}, Ns, Env, _Memory) ->
    Slow = maps:get(slow_radius, Opts, Perception),
    to_target(Opts, B, Ns, Env, fun(Pos, _Vel) -> boids_steer:arrive(B, Pos, Slow) end);
apply_rule(pursue, Opts, B, Ns, Env, _Memory) ->
    Time = maps:get(max_time, Opts, infinity),
    to_target(Opts, B, Ns, Env, fun(Pos, Vel) -> boids_steer:pursue(B, Pos, Vel, Time) end);
apply_rule(evade, Opts, B, Ns, Env, _Memory) ->
    Time = maps:get(max_time, Opts, infinity),
    to_target(Opts, B, Ns, Env, fun(Pos, Vel) -> boids_steer:evade(B, Pos, Vel, Time) end);
apply_rule(wander, Opts, B = #{pos := Pos}, _Ns, Env, Memory) ->
    Dim = boids_vec:dim(Pos),
    Point0 =
        case Memory of
            undefined -> boids_vec:random_unit(Dim);
            Known -> Known
        end,
    %% The square root makes the change in a second the same for each
    %% length of step.
    Step = maps:get(jitter, Opts, 2.0) * math:sqrt(maps:get(dt, Env, 0.0)),
    Point = wander_point(Point0, boids_vec:scale(boids_vec:random_unit(Dim), Step)),
    {boids_steer:wander(B, Point, maps:get(distance, Opts, 2.0), maps:get(radius, Opts, 1.0)), Point};
apply_rule(avoid, Opts, B = #{pos := Pos, vel := Vel, perception := Perception}, _Ns, Env, _Memory) ->
    %% A boid does not see an obstacle with a center of another size.
    Obstacles = [
        O#{pos := seen_at(Env, Pos, At)}
     || O = #{pos := At} <- maps:get(obstacles, Env, []), tuple_size(At) =:= tuple_size(Pos)
    ],
    Ahead = boids_vec:norm(Vel) * maps:get(lookahead, Opts, 1.0),
    boids_steer:avoid(B, Obstacles, Ahead, maps:get(clearance, Opts, Perception / 10));
apply_rule(contain, Opts, B = #{pos := Pos, perception := Perception}, _Ns, Env, _Memory) ->
    case maps:get(bounds, Opts, maps:get(bounds, Env, undefined)) of
        undefined -> boids_vec:zero(boids_vec:dim(Pos));
        Bounds -> boids_steer:contain(B, Bounds, maps:get(margin, Opts, Perception))
    end;
apply_rule(follow, Opts = #{path := Path}, B = #{perception := Perception}, _Ns, _Env, _Memory) ->
    Ahead = maps:get(ahead, Opts, Perception),
    Predict = maps:get(predict, Opts, 0.5),
    boids_steer:follow(B, Path, Ahead, Predict, maps:get(loop, Opts, false));
apply_rule(cruise, Opts, B = #{max_speed := Max}, _Ns, _Env, _Memory) ->
    boids_steer:cruise(B, maps:get(speed, Opts, Max));
apply_rule(leader, Opts, B = #{perception := Perception}, Ns, Env, _Memory) ->
    Distance = maps:get(distance, Opts, Perception / 2),
    Slow = maps:get(slow_radius, Opts, Perception),
    to_target(Opts, B, Ns, Env, fun(Pos, Vel) -> boids_steer:leader(B, Pos, Vel, Distance, Slow) end);
apply_rule(dodge, Opts, B = #{perception := Perception}, Ns, _Env, _Memory) ->
    Near = select(Ns, B, maps:remove(radius, Opts), infinity, all),
    boids_steer:dodge(B, Near, maps:get(radius, Opts, Perception / 4), maps:get(horizon, Opts, 2.0));
apply_rule(flow, Opts = #{field := Field}, B = #{pos := Pos, vel := Vel}, _Ns, _Env, _Memory) ->
    Direction =
        case is_function(Field) of
            true -> Field(boids_vec:add(Pos, boids_vec:scale(Vel, maps:get(predict, Opts, 0.5))));
            false -> Field
        end,
    boids_steer:flow(B, Direction).

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
