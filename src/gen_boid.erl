-module(gen_boid).
-moduledoc """
The process of a boid, and the behavior of its rules.

A boid is a process, and its rules are callback modules that the process
runs at each step. You add rules to a boid and remove them while it
runs, as you add handlers to an event manager of `gen_event` and remove
them. The process does the other work: the ticks, the neighbors, the
sum of the forces, the movement, and the row of the boid in its flock.

```erlang
{ok, Hawk} = gen_boid:start(Flock, #{pos => {50, 50}, group => hawks, rules => [{wander, 1.0}]}),
ok = gen_boid:add_rule(Hawk, {hunger, 1.0, #{prey => birds}}),
[wander, hunger] = gen_boid:which_rules(Hawk),
0 = gen_boid:call(Hawk, hunger, meals),
ok = gen_boid:delete_rule(Hawk, wander, []).
```

## A rule

A rule is one of the rules of the library (`separation`, `seek` and the
others: see `boids_boid`), or a module of yours with this behavior:

```erlang
-module(hunger).
-behavior(gen_boid).
-export([init/1, handle_step/4, handle_call/3]).

%% The rule starts: its state.
init(#{prey := Prey}) ->
    {ok, #{prey => Prey, meals => 0}}.

%% At each step: the force of the rule. The boid goes to the nearest
%% prey that it sees, and eats a prey that it touches.
handle_step(Boid, Neighbors, _Env, State = #{prey := Prey, meals := Meals}) ->
    case [N || N = #{group := Group} <- Neighbors, Group =:= Prey] of
        [] -> {ok, State};
        [#{dist := Dist} | _] when Dist < 1 -> {ok, State#{meals := Meals + 1}};
        [#{pos := Pos} | _] -> {force, boids_steer:seek(Boid, Pos), State}
    end.

handle_call(meals, _Boid, State = #{meals := Meals}) ->
    {ok, Meals, State}.
```

In Elixir, the module has `@behaviour :gen_boid`.

In the list `rules` of a boid and in `add_rule/2`, a rule is `{Name,
Weight}` or `{Name, Weight, Args}`. The name is the name of a rule of
the library, your module, or `{Name, Id}` when the boid has that rule
more than one time. The library multiplies the force of a rule by its
weight.

## The callbacks

`init/1` and `handle_step/4` are necessary.

- `init(Args)` runs when the boid gets the rule. It gives `{ok, State}`,
  or `{error, Reason}`: the boid then does not get the rule.
- `handle_step(Boid, Neighbors, Env, State)` runs at each step of the
  boid. `Neighbors` are the boids that the boid sees, the nearest first.
  `Env` has `dt` (the seconds of the step), `obstacles`, `bounds` and
  `wrap`. It gives `{force, Force, State}`, or `{ok, State}` for no
  force.
- `handle_call(Request, Boid, State)` runs for `call/3`. It gives `{ok,
  Reply, State}`.
- `handle_info(Info, Boid, State)` runs for each other message to the
  process. It gives `{ok, State}`.
- `terminate(Arg, State)` runs when the boid loses the rule. `Arg` is
  the argument of `delete_rule/3`, `remove_rule` (the rule removed
  itself), `replaced` (the boid got a new list of rules), `{stop,
  Reason}` (the process stops) or `{error, Reason}` (the rule failed).

`Boid` is the boid as a map (`t:boids_boid:boid/0`): `maps:get(pos,
Boid)` is its position.

A rule removes itself when a callback gives `remove_rule` (`{remove_rule,
Reply}` for `handle_call/3`).

Each result with a state can have a list of actions as its last part,
for example `{ok, State, Actions}`:

| Action | What it does |
|---|---|
| `{set, Options}` | Changes options of the boid, as `boids:update/3`. |
| `{add_rule, Rule}` | Adds a rule to the boid. |
| `{delete_rule, Name}`, `{delete_rule, Name, Args}` | Removes a rule from the boid. |
| `stop`, `{stop, Reason}` | Stops the process of the boid. |

The actions of a step apply after all the rules of that step. Thus a
rule can be the mind of a boid: it gives no force, and it adds and
removes rules when what the boid sees changes.

## A rule that fails

A rule that has an error, or that gives a bad result, does not stop the
boid. As a handler of `gen_event`, the boid loses that rule, the log
gets an error, and the boid continues with its other rules.

## The options of the process

`start/2` gets the options of the boid (`boids_boid`) and these, on top
of the `defaults` of the flock:

| Option | Default | Description |
|---|---|---|
| `tick` | `50` | The milliseconds between two steps, or `manual`: the boid moves only with `boids:step/2`. |
| `max_dt` | `0.25`, or 4 ticks | The maximum of the seconds of one step. A late tick does not make a long step. The default is the larger of 0.25 second and 4 ticks. |
| `seed` | (none) | An integer: the seed of the random numbers of the process. |
| `priority` | `low` | The priority of the process: `low` or `normal`. |
| `hibernate` | `true` | The process hibernates between two steps. |
| `name` | (none) | A name for the process: an atom, `{global, Term}` or `{via, Module, Term}`. |

The time of a step is the time that passed on the monotonic clock,
multiplied by the scale of the time of the flock. The process waits
`tick` milliseconds after each step, so the time between two steps is a
little more than `tick`.

## The supervisor of a boid

`start/2` starts the boid below the supervisor of its flock. That
supervisor does not start a boid again after an error. `start_link/2`
and `child_spec/1` are for a supervisor of yours, which starts the boid
again as you tell it. Give an `id` to the boid, so that the process that
starts again is the same boid.

## A flock with too much work

When the boids need more time than the computer has, each tick comes
late. A boid whose tick comes late waits longer before its next tick, so
that the node continues to answer. Its steps are then longer: `max_dt`
at most. With longer waits, the boids move more slowly than the clock.

With the priority `low`, the other processes of the node run before the
boids, so the node answers when the boids use all the processors. With
`normal`, the boids have the priority of the other processes.

## The memory

A step makes garbage: the copies of the rows of the neighbors. With
`hibernate`, the process drops its heap after each step, and it holds
about 4 KB. Without it, the process holds about 80 KB, and a step is
about 10 % faster.
""".
-behavior(gen_server).

-export([start/2, start_link/2, child_spec/1, stop/1]).
-export([add_rule/2, delete_rule/3, which_rules/1, call/3, call/4]).
-export([options/1, start_child/3]).
-export([init/1, handle_call/3, handle_cast/2, handle_info/2, terminate/2]).

-export_type([boid/0]).

-type boid() :: pid() | atom() | {global, term()} | {via, module(), term()}.
-type actions() :: [boids_boid:action()].

-callback init(Args :: term()) -> {ok, State :: term()} | {error, Reason :: term()}.
-callback handle_step(
    Boid :: boids_boid:boid(),
    Neighbors :: [boids_space:neighbor()],
    Env :: boids_boid:env(),
    State :: term()
) ->
    {force, boids_vec:vec(), NewState :: term()}
    | {force, boids_vec:vec(), NewState :: term(), actions()}
    | {ok, NewState :: term()}
    | {ok, NewState :: term(), actions()}
    | remove_rule.
-callback handle_call(Request :: term(), Boid :: boids_boid:boid(), State :: term()) ->
    {ok, Reply :: term(), NewState :: term()}
    | {ok, Reply :: term(), NewState :: term(), actions()}
    | {remove_rule, Reply :: term()}.
-callback handle_info(Info :: term(), Boid :: boids_boid:boid(), State :: term()) ->
    {ok, NewState :: term()} | {ok, NewState :: term(), actions()} | remove_rule.
-callback terminate(Arg :: term(), State :: term()) -> term().

-optional_callbacks([handle_call/3, handle_info/3, terminate/2]).

-define(KEYS, [tick, max_dt, seed, priority, hibernate]).

%% The start has a high priority: a flock with too much work must not
%% make its caller wait.
-define(GEN, [{spawn_opt, [{priority, high}]}]).

-doc """
Start a boid below the supervisor of its flock. The boid stops with its
flock, and it does not start again after an error. The options are those
of a boid (`boids_boid`) and of its process, as a map or a list of
`{Key, Value}`. `pos` is necessary.

A bad option gives `{error, {bad_option, {Key, Value}}}`, and an id that
is in the flock `{error, {exists, Id}}`.
""".
-spec start(boids:flock(), boids:options()) -> {ok, pid()} | {error, term()}.
start(Flock, Options) ->
    Space = boids:space(Flock),
    start_child(boids_flock:boid_sup(Space), Space, Options).

-doc false.
start_child(Sup, Space, Options) ->
    case supervisor:start_child(Sup, [Space, Options]) of
        {ok, Pid} -> {ok, Pid};
        {error, {shutdown, Reason}} -> {error, Reason};
        {error, Reason} -> {error, Reason}
    end.

-doc """
Start a boid with a link to the caller: for a supervisor of yours. The
options are those of `start/2`. Give the name of the flock, and not its
pid, so that the boid finds a flock that started again.

A bad option gives `{error, {shutdown, {bad_option, {Key, Value}}}}`,
and an id that is in the flock `{error, {shutdown, {exists, Id}}}`.
""".
-spec start_link(boids:flock(), boids:options()) -> {ok, pid()} | {error, term()}.
start_link(Flock, Options0) ->
    try boids_boid:to_map(Options0) of
        #{name := Name} = Options when is_atom(Name) ->
            gen_server:start_link({local, Name}, ?MODULE, {Flock, Options}, ?GEN);
        #{name := Name} = Options ->
            gen_server:start_link(Name, ?MODULE, {Flock, Options}, ?GEN);
        Options ->
            gen_server:start_link(?MODULE, {Flock, Options}, ?GEN)
    catch
        error:{bad_option, _} = Reason -> {error, {shutdown, Reason}}
    end.

-doc """
The specification of a boid as a child of a supervisor of yours, from
`{Flock, Options}` (see `start_link/2`).

```erlang
{ok, {#{strategy => rest_for_one}, [
    boids:child_spec(#{name => my_flock}),
    gen_boid:child_spec({my_flock, #{id => hawk, pos => {50, 50}, rules => [{hunger, 1.0, #{prey => birds}}]}})
]}}
```

In Elixir, the child is `{:gen_boid, {:my_flock, id: :hawk, pos: {50, 50}}}`.
""".
-spec child_spec({boids:flock(), boids:options()}) -> supervisor:child_spec().
child_spec({Flock, Options}) ->
    Id = maps:get(id, boids_boid:to_map(Options), make_ref()),
    #{id => {?MODULE, Id}, start => {?MODULE, start_link, [Flock, Options]}}.

-doc "Stop a boid: its process stops with the reason `normal`.".
-spec stop(boid()) -> ok.
stop(Boid) ->
    gen_server:stop(Boid).

-doc """
Add a rule at the end of the rules of a boid: `{Name, Weight}` or
`{Name, Weight, Args}`. A module of yours starts in the process of the
boid: `Module:init(Args)`. A bad rule, or a module that does not start,
gives `{error, Reason}`.
""".
-spec add_rule(boid(), boids_boid:rule()) -> ok | {error, term()}.
add_rule(Boid, Rule) ->
    gen_server:call(Boid, {add_rule, Rule}).

-doc """
Remove the first rule with the name `Name` from a boid. For a module of
yours with `terminate/2`, the result is what `Module:terminate(Args,
State)` gives. For the other rules it is `ok`. A boid with no such rule
gives `{error, not_found}`.
""".
-spec delete_rule(boid(), boids_boid:name(), term()) -> term() | {error, not_found}.
delete_rule(Boid, Name, Args) ->
    gen_server:call(Boid, {delete_rule, Name, Args}).

-doc "The names of the rules of a boid, in their order.".
-spec which_rules(boid()) -> [boids_boid:name()].
which_rules(Boid) ->
    gen_server:call(Boid, which_rules).

-doc """
Send a request to a rule of a boid, and wait for its answer:
`Module:handle_call(Request, Boid, State)` gives it. The time limit is 5
seconds. A boid with no such rule, or a rule with no `handle_call/3`,
gives `{error, bad_rule}`. A rule that fails gives `{error, {failed,
Reason}}`.
""".
-spec call(boid(), boids_boid:name(), term()) -> term().
call(Boid, Name, Request) ->
    gen_server:call(Boid, {call, Name, Request}).

-doc "As `call/3`, with a time limit in milliseconds, or `infinity`.".
-spec call(boid(), boids_boid:name(), term(), timeout()) -> term().
call(Boid, Name, Request, Timeout) ->
    gen_server:call(Boid, {call, Name, Request}, Timeout).

-doc """
Divide the options into those of the process and those of the boid.
A bad option of the process gives the error `{bad_option, {Key, Value}}`.
""".
-spec options(map()) -> {map(), map()}.
options(Opts) ->
    Given = maps:with(?KEYS, Opts),
    MaxDt =
        case Given of
            #{tick := Tick} when is_integer(Tick) -> max(0.25, 4 * Tick / 1000);
            _ -> 0.25
        end,
    Server = maps:merge(#{tick => 50, max_dt => MaxDt, priority => low, hibernate => true}, Given),
    maps:foreach(fun check/2, Server),
    {Server, maps:without([name | ?KEYS], Opts)}.

check(tick, manual) -> ok;
check(tick, Tick) when is_integer(Tick), Tick > 0 -> ok;
check(max_dt, Max) when is_number(Max), Max > 0 -> ok;
check(seed, Seed) when is_integer(Seed) -> ok;
check(priority, Priority) when Priority =:= low; Priority =:= normal -> ok;
check(hibernate, Hibernate) when is_boolean(Hibernate) -> ok;
check(Key, Value) -> error({bad_option, {Key, Value}}).

%% --- gen_server -------------------------------------------------------

-doc false.
init({Flock, Opts}) ->
    try
        Space = #{defaults := Defaults} = boids:space(Flock),
        {Server, BoidOpts} = options(maps:merge(Defaults, boids_boid:to_map(Opts))),
        %% The rules of the boid start here, in its process.
        {Space, Server, boids_boid:new(maps:merge(#{id => self()}, BoidOpts))}
    of
        {Space, Server, Boid} -> join(Space, Server, Boid)
    catch
        error:{bad_option, _} = Reason -> {stop, {shutdown, Reason}}
    end.

join(Space, Server = #{tick := Tick, priority := Priority}, Boid = #{id := Id}) ->
    case Server of
        #{seed := Seed} -> rand:seed(exsss, Seed);
        _ -> ok
    end,
    %% The tools that show processes show which boid this process is.
    proc_lib:set_label({boids, boid, Id}),
    case boids_flock:join(Space, self(), (boids_boid:entry(Boid))#{server => true}) of
        ok ->
            %% The first tick comes after a random part of the period, so
            %% the boids of a flock do not all move at the same time.
            Due =
                case Tick of
                    manual -> undefined;
                    _ -> wait(rand:uniform(Tick))
                end,
            process_flag(priority, Priority),
            {ok, Server#{space => Space, boid => Boid, last => now_us(), due => Due, pending => undefined}};
        {error, Reason} ->
            boids_boid:terminate(Boid, {stop, Reason}),
            {stop, {shutdown, Reason}}
    end.

-doc false.
handle_call(get, _From, State = #{boid := Boid}) ->
    {reply, Boid, State};
handle_call({update, Changes}, _From, State = #{boid := Boid}) ->
    try boids_boid:update(Boid, Changes) of
        Changed -> {reply, ok, changed(Changed, State)}
    catch
        error:{bad_option, _} = Reason -> {reply, {error, Reason}, State}
    end;
handle_call({add_rule, Rule}, _From, State = #{boid := Boid}) ->
    case boids_boid:add_rule(Boid, Rule) of
        {ok, Changed} -> {reply, ok, changed(Changed, State)};
        {error, Reason} -> {reply, {error, Reason}, State}
    end;
handle_call({delete_rule, Name, Args}, _From, State = #{boid := Boid}) ->
    case boids_boid:delete_rule(Boid, Name, Args) of
        {ok, Result, Changed} -> {reply, Result, changed(Changed, State)};
        {error, not_found} -> {reply, {error, not_found}, State}
    end;
handle_call(which_rules, _From, State = #{boid := Boid}) ->
    {reply, boids_boid:which_rules(Boid), State};
handle_call({call, Name, Request}, _From, State = #{boid := Boid}) ->
    {Reply, Changed} = boids_boid:call_rule(Boid, Name, Request),
    case Changed of
        #{stop := Reason} -> {stop, Reason, Reply, State#{boid := Changed}};
        _ -> {reply, Reply, changed(Changed, State)}
    end;
handle_call({plan, Dt}, _From, State = #{space := Space, boid := Boid}) ->
    case boids:plan(Space, Boid, Dt) of
        #{stop := Reason} = Planned -> {stop, Reason, ok, State#{boid := Planned}};
        Planned -> {reply, ok, State#{pending := Planned}}
    end;
handle_call(commit, _From, State = #{pending := undefined}) ->
    {reply, ok, State};
handle_call(commit, _From, State = #{space := Space, pending := Boid}) ->
    boids:commit(Space, Boid),
    rest({reply, ok, State#{boid := Boid, pending := undefined}}).

-doc false.
handle_cast(_Message, State) ->
    {noreply, State}.

-doc false.
handle_info(tick, State = #{space := Space, boid := Boid0, tick := Tick, last := Last, max_dt := MaxDt}) ->
    Now = now_us(),
    case boids:advance(Space, Boid0, min((Now - Last) / 1.0e6, MaxDt)) of
        #{stop := Reason} = Boid ->
            {stop, Reason, State#{boid := Boid}};
        Boid ->
            %% The wait starts after the step, so a boid always has a rest.
            Due = wait(Tick + extra(Now - maps:get(due, State))),
            rest({noreply, State#{boid := Boid, last := Now, due := Due}})
    end;
handle_info(Info, State = #{boid := Boid}) ->
    case boids_boid:info(Boid, Info) of
        #{stop := Reason} = Changed -> {stop, Reason, State#{boid := Changed}};
        Changed -> {noreply, changed(Changed, State)}
    end.

-doc false.
terminate(Reason, #{boid := Boid}) ->
    boids_boid:terminate(Boid, {stop, Reason}).

%% The boid changed out of a step: write it to the flock. A plan of
%% boids:step/2 that is not written is for the boid before the change.
changed(Boid, State = #{space := Space}) ->
    boids:commit(Space, Boid),
    State#{boid := Boid, pending := undefined}.

%% Send the next tick after Ms milliseconds. The result is its time.
wait(Ms) ->
    erlang:send_after(Ms, self(), tick),
    now_us() + Ms * 1000.

%% A tick that comes late shows that the processors have too much work.
%% The boid then waits 8 times that delay more, 1 second at most, so
%% that few boids wait for a processor at the same time. A delay of
%% 2 ms or less is the precision of the timer.
extra(Late) when Late > 2000 -> min((Late - 2000) div 125, 1000);
extra(_Late) -> 0.

%% After a step, the heap has only garbage.
rest(Return) ->
    case element(tuple_size(Return), Return) of
        #{hibernate := true} -> erlang:append_element(Return, hibernate);
        _ -> Return
    end.

now_us() ->
    erlang:monotonic_time(microsecond).
