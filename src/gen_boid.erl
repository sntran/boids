-module(gen_boid).
-moduledoc """
The behavior of a process that is a boid.

This module is the process of a boid, and your module tells what the
boid is: where it starts, what it decides at each step, and how it
answers messages. The library does the other work: the steps, the
neighbors, the forces of the rules, the movement, and the row of the
boid in its flock.

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
  of the boid (`boids_boid`), on top of the `defaults` of the flock. It can also give `ignore` or `{stop, Reason}`.
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

## The steps

The clock of the flock makes the steps: a `gen_boid` moves with the
other boids of its flock, each `tick` of the flock, or with
`boids:step/2`. First all the boids calculate their step from the same
state of the flock, then they all move.

With the option `seed` (an integer) in the options of `init/1`, the
random numbers of the process start from that seed.

## The supervisor of a boid

`start/3` starts the boid below the supervisor of its flock. That
supervisor does not start a boid again after an error. `start_link/3`
and `child_spec/1` are for a supervisor of yours, which starts the boid
again as you tell it. Give an `id` in the options of `init/1`, so that
the process that starts again is the same boid.

## A process or a value

A boid of `boids:add/2` is a value in a worker of the flock: it has no
process, and its step costs less. Use a `gen_boid` for a boid that
decides, that answers messages, or that has a supervisor of yours. The
two kinds are neighbors in the same flock.

## The memory

A step makes garbage: the copies of the rows of the neighbors. The
process hibernates after each step: it drops its heap, and it holds
about 4 KB. With `hibernate => false` in the options of the start, the
process holds about 80 KB, and a step is about 10 % faster.
""".
-behavior(gen_server).

-export([start/3, start_link/3, child_spec/1, stop/1]).
-export([call/2, call/3, cast/2, reply/2]).
-export([add_rule/2, delete_rule/2, which_rules/1]).
-export([start_child/4]).
-export([init/1, handle_call/3, handle_cast/2, handle_info/2, terminate/2]).

-export_type([boid/0, start_options/0]).

-type boid() :: pid() | atom() | {global, term()} | {via, module(), term()}.
-type start_options() :: #{
    flock := boids:flock(),
    name => atom() | {global, term()} | {via, module(), term()},
    hibernate => boolean()
}.
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

-doc """
Start a boid below the supervisor of its flock. The boid stops with its
flock, and it does not start again after an error.

`Options` is a map, or a list of `{Key, Value}`: `flock` (necessary: the
flock or its space), `name` (a name for the process: an atom, `{global,
Term}` or `{via, Module, Term}`), and `hibernate` (default: `true`, see
the module).

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
            gen_server:start_link({local, Name}, ?MODULE, {Module, Args, Options}, []);
        Options = #{name := Name} ->
            gen_server:start_link(Name, ?MODULE, {Module, Args, Options}, []);
        Options ->
            gen_server:start_link(?MODULE, {Module, Args, Options}, [])
    end.

start_options(Options0) ->
    Options = boids_boid:to_map(Options0),
    is_map_key(flock, Options) orelse error({bad_option, {flock, undefined}}),
    [error({bad_option, {Key, Value}}) || Key := Value <- Options, not lists:member(Key, [flock, name, hibernate])],
    is_boolean(maps:get(hibernate, Options, true)) orelse error({bad_option, {hibernate, maps:get(hibernate, Options)}}),
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
Add a rule at the end of the rules of a boid: `{Name, Weight}` or
`{Name, Weight, Options}`. The boid has the rule from its next step.
""".
-spec add_rule(boid(), boids_boid:rule()) -> ok | {error, term()}.
add_rule(Boid, Rule) ->
    gen_server:call(Boid, {change, add_rule, Rule}).

-doc "Remove the first rule with the name `Name` from a boid.".
-spec delete_rule(boid(), boids_boid:name()) -> ok.
delete_rule(Boid, Name) ->
    gen_server:call(Boid, {change, delete_rule, Name}).

-doc "The names of the rules of a boid, in their order.".
-spec which_rules(boid()) -> [boids_boid:name()].
which_rules(Boid) ->
    boids_boid:which_rules(gen_server:call(Boid, get)).

%% --- gen_server -------------------------------------------------------

-doc false.
init({Module, Args, Start = #{flock := Flock}}) ->
    case Module:init(Args) of
        {ok, Opts, User} ->
            try
                Space = #{defaults := Defaults} = boids:space(Flock),
                {Seed, BoidOpts} = seed(maps:merge(Defaults, boids_boid:to_map(Opts))),
                {Space, Seed, boids_boid:new(maps:merge(#{id => self()}, BoidOpts))}
            of
                {Space, Seed, Boid} ->
                    Seed =:= undefined orelse rand:seed(exsss, Seed),
                    Server = #{mod => Module, state => User, hibernate => maps:get(hibernate, Start, true)},
                    join(Space, Server, Boid)
            catch
                error:{bad_option, _} = Reason -> {stop, {shutdown, Reason}}
            end;
        ignore ->
            ignore;
        {stop, Reason} ->
            {stop, Reason}
    end.

%% The seed of a gen_boid is that of its process: the callbacks of the
%% module get its random numbers too.
seed(Opts = #{seed := Seed}) when is_integer(Seed) -> {Seed, maps:remove(seed, Opts)};
seed(Opts) -> {undefined, Opts}.

join(Space, Server, Boid = #{id := Id}) ->
    %% The tools that show processes show which boid this process is.
    proc_lib:set_label({boids, boid, Id}),
    case boids_flock:join(Space, self(), (boids_boid:entry(Boid))#{kind => server}) of
        ok ->
            ok = boids_clock:attach(Space),
            {ok, Server#{space => Space, boid => Boid, pending => undefined}};
        {error, Reason} ->
            {stop, {shutdown, Reason}}
    end.

-doc false.
handle_call(get, _From, State = #{boid := Boid}) ->
    {reply, Boid, State};
handle_call({change, Function, Arg}, _From, State = #{space := Space, boid := Boid0}) ->
    try boids_boid:Function(Boid0, Arg) of
        Boid ->
            boids:commit(Space, Boid),
            {reply, ok, State#{boid := Boid, pending := undefined}}
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

%% After a step, the heap has only garbage.
rest(Return) ->
    case element(tuple_size(Return), Return) of
        #{hibernate := true} -> erlang:append_element(Return, hibernate);
        _ -> Return
    end.
