-module(gen_boid).
-moduledoc """
The behavior of a process that is a boid.

A boid of a flock is a process. This module is that process, and your
module tells what the boid is: where it starts, what it decides at each
step, and how it answers messages. The library does the other work: the
ticks, the neighbors, the forces of the rules, the movement, and the row
of the boid in its flock.

```erlang
-module(hawk).
-behavior(gen_boid).
-export([init/1, handle_step/3, handle_call/4]).

%% The boid starts: its options, and the state of this module.
init(Pos) ->
    {ok, #{pos => Pos, group => hawks, perception => 25, rules => [{wander, 1.0}]}, #{meals => 0}}.

%% At each step, before the forces: the hawk hunts a bird that it sees.
handle_step(_Boid, Neighbors, State = #{meals := Meals}) ->
    case [N || N = #{group := birds} <- Neighbors] of
        [] -> {ok, #{rules => [{wander, 1.0}]}, State};
        [#{dist := Dist} | _] when Dist < 1 -> {ok, State#{meals := Meals + 1}};
        [_ | _] -> {ok, #{rules => [{pursue, 1.0, #{target => {group, birds}}}]}, State}
    end.

handle_call(meals, _From, _Boid, State = #{meals := Meals}) ->
    {reply, Meals, State}.
```

```erlang
{ok, Hawk} = gen_boid:start_link(hawk, {50, 50}, #{flock => Flock}),
0 = gen_boid:call(Hawk, meals).
```

In Elixir, the module has `@behaviour :gen_boid`.

## The callbacks

Only `init/1` is necessary.

- `init(Args)` gives `{ok, Options, State}`. `Options` are the options
  of the boid (`boids_boid`) and of its process (below), on top of the
  `defaults` of the flock. It can also give `ignore` or `{stop, Reason}`.
- `handle_step(Boid, Neighbors, State)` runs at each step, before the
  forces of the rules. `Neighbors` are the boids that the boid sees, the
  nearest first. It gives `{ok, State}`, or `{ok, Changes, State}` to
  change options of the boid for this step and the next steps.
- `handle_call(Request, From, Boid, State)`, `handle_cast(Request, Boid,
  State)` and `handle_info(Info, Boid, State)` are those of `gen_server`,
  with the boid. Each result can have changes of the boid: `{reply,
  Reply, Changes, State}` and `{noreply, Changes, State}`.
- `terminate(Reason, Boid, State)` runs when the process stops, as in
  `gen_server`.

`Boid` is the boid as a map (`t:boids_boid:boid/0`): `maps:get(pos,
Boid)` is its position. `Changes` are options of a boid, as for
`boids:update/3`. Each callback can give `{stop, Reason, State}`.

A boid with no module of yours is a `gen_boid` with the module
`boids_boid`: `boids:add/2` starts one.

## The options of the process

| Option | Default | Description |
|---|---|---|
| `tick` | `50` | The milliseconds between two steps, or `manual`: the boid moves only with `boids:step/2`. |
| `max_dt` | `0.25`, or 4 ticks | The maximum of the seconds of one step. A late tick does not make a long step. The default is the larger of 0.25 second and 4 ticks. |
| `seed` | (none) | An integer: the seed of the random numbers of the process. |
| `priority` | `low` | The priority of the process: `low` or `normal`. |
| `hibernate` | `true` | The process hibernates between two steps. |

The time of a step is the time that passed on the monotonic clock,
multiplied by the scale of the time of the flock. The process waits
`tick` milliseconds after each step, so the time between two steps is a
little more than `tick`.

## The supervisor of a boid

`start/3` starts the boid below the supervisor of its flock. That
supervisor does not start a boid again after an error. `start_link/3`
and `child_spec/1` are for a supervisor of yours, which starts the boid
again as you tell it. Give an `id` in the options of `init/1`, so that
the process that starts again is the same boid.

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

-export([start/3, start_link/3, child_spec/1, stop/1]).
-export([call/2, call/3, cast/2, reply/2]).
-export([options/1, start_child/4]).
-export([init/1, handle_call/3, handle_cast/2, handle_info/2, terminate/2]).

-export_type([boid/0, start_options/0]).

-type boid() :: pid() | atom() | {global, term()} | {via, module(), term()}.
-type start_options() :: #{flock := boids:flock(), name => atom() | {global, term()} | {via, module(), term()}}.
-type changes() :: boids:options().

-callback init(Args :: term()) ->
    {ok, Options :: boids:options(), State :: term()} | ignore | {stop, Reason :: term()}.
-callback handle_step(Boid :: boids_boid:boid(), Neighbors :: [boids_space:neighbor()], State :: term()) ->
    {ok, NewState :: term()}
    | {ok, changes(), NewState :: term()}
    | {stop, Reason :: term(), NewState :: term()}.
-callback handle_call(Request :: term(), From :: gen_server:from(), Boid :: boids_boid:boid(), State :: term()) ->
    {reply, Reply :: term(), NewState :: term()}
    | {reply, Reply :: term(), changes(), NewState :: term()}
    | {noreply, NewState :: term()}
    | {noreply, changes(), NewState :: term()}
    | {stop, Reason :: term(), Reply :: term(), NewState :: term()}
    | {stop, Reason :: term(), NewState :: term()}.
-callback handle_cast(Request :: term(), Boid :: boids_boid:boid(), State :: term()) ->
    {noreply, NewState :: term()}
    | {noreply, changes(), NewState :: term()}
    | {stop, Reason :: term(), NewState :: term()}.
-callback handle_info(Info :: term(), Boid :: boids_boid:boid(), State :: term()) ->
    {noreply, NewState :: term()}
    | {noreply, changes(), NewState :: term()}
    | {stop, Reason :: term(), NewState :: term()}.
-callback terminate(Reason :: term(), Boid :: boids_boid:boid(), State :: term()) -> term().

-optional_callbacks([handle_step/3, handle_call/4, handle_cast/3, handle_info/3, terminate/3]).

-define(KEYS, [tick, max_dt, seed, priority, hibernate]).

%% The start has a high priority: a flock with too much work must not
%% make its caller wait.
-define(GEN, [{spawn_opt, [{priority, high}]}]).

-doc """
Start a boid below the supervisor of its flock. The boid stops with its
flock, and it does not start again after an error.

`Options` is a map, or a list of `{Key, Value}`: `flock` (necessary: the
flock or its space), and `name` (a name for the process: an atom,
`{global, Term}` or `{via, Module, Term}`).

A bad option of `init/1` gives `{error, {bad_option, {Key, Value}}}`,
and an id that is in the flock `{error, {exists, Id}}`.
""".
-spec start(module(), term(), start_options() | [{atom(), term()}]) -> {ok, pid()} | ignore | {error, term()}.
start(Module, Args, Options0) ->
    Options = #{flock := Flock} = start_options(Options0),
    Space = boids:space(Flock),
    start_child(boids_flock:boid_sup(Space), Module, Args, Options#{flock := Space}).

-doc false.
start_child(Sup, Module, Args, Options) ->
    case supervisor:start_child(Sup, [Module, Args, Options]) of
        {ok, undefined} -> ignore;
        {ok, Pid} -> {ok, Pid};
        {error, {shutdown, Reason}} -> {error, Reason};
        {error, Reason} -> {error, Reason}
    end.

-doc """
Start a boid with a link to the caller: for a supervisor of yours. The
options are those of `start/3`. Give the name of the flock, and not its
pid, so that the boid finds a flock that started again.

A bad option of `init/1` gives `{error, {shutdown, {bad_option, {Key,
Value}}}}`, and an id that is in the flock `{error, {shutdown, {exists,
Id}}}`.
""".
-spec start_link(module(), term(), start_options() | [{atom(), term()}]) -> {ok, pid()} | ignore | {error, term()}.
start_link(Module, Args, Options0) ->
    case start_options(Options0) of
        Options = #{name := Name} when is_atom(Name) ->
            gen_server:start_link({local, Name}, ?MODULE, {Module, Args, Options}, ?GEN);
        Options = #{name := Name} ->
            gen_server:start_link(Name, ?MODULE, {Module, Args, Options}, ?GEN);
        Options ->
            gen_server:start_link(?MODULE, {Module, Args, Options}, ?GEN)
    end.

start_options(Options0) ->
    Options = boids_boid:to_map(Options0),
    is_map_key(flock, Options) orelse error({bad_option, {flock, undefined}}),
    [error({bad_option, {Key, maps:get(Key, Options)}}) || Key <- maps:keys(Options), Key =/= flock, Key =/= name],
    Options.

-doc """
The specification of a boid as a child of a supervisor of yours, from
`{Module, Args, Options}` (see `start_link/3`).

```erlang
{ok, {#{strategy => rest_for_one}, [
    boids:child_spec(#{name => my_flock}),
    gen_boid:child_spec({hawk, {50, 50}, #{flock => my_flock}})
]}}
```

In Elixir, the child is `{:gen_boid, {Hawk, {50, 50}, flock: :my_flock}}`.
""".
-spec child_spec({module(), term(), start_options() | [{atom(), term()}]}) -> supervisor:child_spec().
child_spec({Module, Args, Options}) ->
    #{id => {?MODULE, Module, Args}, start => {?MODULE, start_link, [Module, Args, Options]}}.

-doc "Stop a boid: its process stops with the reason `normal`.".
-spec stop(boid()) -> ok.
stop(Boid) ->
    gen_server:stop(Boid).

-doc """
Send a request to a boid, and wait for its answer: `handle_call/4` of
its module gives it. The time limit is 5 seconds.
""".
-spec call(boid(), term()) -> term().
call(Boid, Request) ->
    gen_server:call(Boid, {'$gen_boid', Request}).

-doc "As `call/2`, with a time limit in milliseconds, or `infinity`.".
-spec call(boid(), term(), timeout()) -> term().
call(Boid, Request, Timeout) ->
    gen_server:call(Boid, {'$gen_boid', Request}, Timeout).

-doc "Send a request to a boid, with no answer: `handle_cast/3` of its module gets it.".
-spec cast(boid(), term()) -> ok.
cast(Boid, Request) ->
    gen_server:cast(Boid, {'$gen_boid', Request}).

-doc "Answer a request of `call/2`, when `handle_call/4` gave `noreply`.".
-spec reply(gen_server:from(), term()) -> ok.
reply(From, Reply) ->
    gen_server:reply(From, Reply).

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
    {Server, maps:without(?KEYS, Opts)}.

check(tick, manual) -> ok;
check(tick, Tick) when is_integer(Tick), Tick > 0 -> ok;
check(max_dt, Max) when is_number(Max), Max > 0 -> ok;
check(seed, Seed) when is_integer(Seed) -> ok;
check(priority, Priority) when Priority =:= low; Priority =:= normal -> ok;
check(hibernate, Hibernate) when is_boolean(Hibernate) -> ok;
check(Key, Value) -> error({bad_option, {Key, Value}}).

%% --- gen_server -------------------------------------------------------

-doc false.
init({Module, Args, #{flock := Flock}}) ->
    case Module:init(Args) of
        {ok, Opts, User} ->
            try
                Space = #{defaults := Defaults} = boids:space(Flock),
                {Server, BoidOpts} = options(maps:merge(Defaults, boids_boid:to_map(Opts))),
                {Space, Server, boids_boid:new(maps:merge(#{id => self()}, BoidOpts))}
            of
                {Space, Server, Boid} -> join(Space, Server#{mod => Module, state => User}, Boid)
            catch
                error:{bad_option, _} = Reason -> {stop, {shutdown, Reason}}
            end;
        ignore ->
            ignore;
        {stop, Reason} ->
            {stop, Reason}
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
            {stop, {shutdown, Reason}}
    end.

-doc false.
handle_call(get, _From, State = #{boid := Boid}) ->
    {reply, Boid, State};
handle_call({update, Changes}, _From, State) ->
    try change(Changes, State) of
        Changed -> {reply, ok, Changed}
    catch
        error:{bad_option, _} = Reason -> {reply, {error, Reason}, State}
    end;
handle_call({plan, Dt}, _From, State0) ->
    case plan(State0, Dt) of
        {ok, Boid, State} -> {reply, ok, State#{pending := Boid}};
        {stop, Reason, State} -> {stop, Reason, ok, State}
    end;
handle_call(commit, _From, State = #{pending := undefined}) ->
    {reply, ok, State};
handle_call(commit, _From, State = #{space := Space, pending := Boid}) ->
    boids:commit(Space, Boid),
    rest({reply, ok, State#{boid := Boid, pending := undefined}});
handle_call({'$gen_boid', Request}, From, State = #{mod := Module, boid := Boid, state := User}) ->
    case erlang:function_exported(Module, handle_call, 4) of
        true -> result(Module:handle_call(Request, From, Boid, User), State);
        false -> {stop, {bad_call, Request}, State}
    end.

-doc false.
handle_cast({'$gen_boid', Request}, State = #{mod := Module, boid := Boid, state := User}) ->
    case erlang:function_exported(Module, handle_cast, 3) of
        true -> result(Module:handle_cast(Request, Boid, User), State);
        false -> {stop, {bad_cast, Request}, State}
    end;
handle_cast(_Message, State) ->
    {noreply, State}.

-doc false.
handle_info(tick, State0 = #{space := Space, tick := Tick, last := Last, max_dt := MaxDt}) ->
    Now = now_us(),
    case plan(State0, min((Now - Last) / 1.0e6, MaxDt)) of
        {ok, Boid, State} ->
            boids:commit(Space, Boid),
            %% The wait starts after the step, so a boid always has a rest.
            Due = wait(Tick + extra(Now - maps:get(due, State))),
            rest({noreply, State#{boid := Boid, last := Now, due := Due}});
        {stop, Reason, State} ->
            {stop, Reason, State}
    end;
handle_info(Info, State = #{mod := Module, boid := Boid, state := User}) ->
    case erlang:function_exported(Module, handle_info, 3) of
        true -> result(Module:handle_info(Info, Boid, User), State);
        false -> {noreply, State}
    end.

-doc false.
terminate(Reason, #{mod := Module, boid := Boid, state := User}) ->
    erlang:function_exported(Module, terminate, 3) andalso Module:terminate(Reason, Boid, User),
    ok.

%% One step of the boid, with no write to the flock: the module decides,
%% then the rules give the force (specs/Step.tla, Plan).
plan(State = #{space := Space, boid := Boid0, mod := Module, state := User0}, Dt) ->
    Neighbors = boids:sense(Space, Boid0),
    Decided =
        case erlang:function_exported(Module, handle_step, 3) of
            true -> Module:handle_step(Boid0, Neighbors, User0);
            false -> {ok, User0}
        end,
    case Decided of
        {ok, User} ->
            {ok, boids:plan(Space, Boid0, Neighbors, Dt), State#{state := User}};
        {ok, Changes, User} ->
            Boid = boids_boid:update(Boid0, Changes),
            {ok, boids:plan(Space, Boid, Neighbors, Dt), State#{state := User}};
        {stop, Reason, User} ->
            {stop, Reason, State#{state := User}}
    end.

%% The result of a callback of the module, as a result of gen_server.
result({reply, Reply, User}, State) -> {reply, Reply, State#{state := User}};
result({reply, Reply, Changes, User}, State) -> {reply, Reply, change(Changes, State#{state := User})};
result({noreply, User}, State) -> {noreply, State#{state := User}};
result({noreply, Changes, User}, State) -> {noreply, change(Changes, State#{state := User})};
result({stop, Reason, Reply, User}, State) -> {stop, Reason, Reply, State#{state := User}};
result({stop, Reason, User}, State) -> {stop, Reason, State#{state := User}}.

%% Change options of the boid, and write the boid to the flock.
change(Changes, State = #{space := Space, boid := Boid0}) ->
    Boid = boids_boid:update(Boid0, Changes),
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
