-module(gen_boid).
-moduledoc """
The behavior of a boid: a process that senses, decides and acts.

Each boid of a world is a process with this behavior. At each
step, the boid does three things:

1. **Sense.** It finds the neighbors that it sees, and the obstacles.
2. **Decide.** It calculates the force of its rules.
3. **Act.** It moves, and it writes its new position to the world.

The library does these three things. Your module tells what the boid is,
and it can add to each of them with a callback:

```erlang
-module(hawk).
-behavior(gen_boid).
-export([init/1, handle_sense/2, handle_decide/2, handle_act/1, handle_call/3]).

%% The boid starts: its options. The key state is for this module.
init(Pos) ->
    {ok, #{pos => Pos, group => hawks, perception => 25, rules => [{wander, 1.0}], state => #{energy => 10.0}}}.

%% After the library found the neighbors: add what this boid perceives.
handle_sense(Seen = #{neighbors := Neighbors}, Boid) ->
    {ok, Seen#{prey => [N || N = #{group := birds} <- Neighbors]}, Boid}.

%% Before the forces: the rules for this step.
handle_decide(#{prey := [_ | _]}, Boid = #{state := #{energy := Energy}}) when Energy > 2 ->
    {ok, boids_boid:update(Boid, #{rules => [{pursue, 1.0, #{target => {group, birds}}}]})};
handle_decide(_Seen, Boid) ->
    {ok, boids_boid:update(Boid, #{rules => [{wander, 1.0}]})}.

%% After the movement: the effects.
handle_act(Boid = #{vel := Vel, state := State = #{energy := Energy}}) ->
    {ok, Boid#{state := State#{energy := Energy - 0.01 * boids_vec:norm(Vel)}}}.

handle_call(energy, _From, Boid = #{state := #{energy := Energy}}) ->
    {reply, Energy, Boid}.
```

```erlang
{ok, Hawk} = gen_boid:start(World, hawk, {50, 50}),
10.0 = gen_boid:call(Hawk, energy).
```

In Elixir, the module has `@behaviour :gen_boid`.

## The boid is the state

Each callback gets the boid, and gives the boid. The boid is a map
(`t:boids_boid:boid/0`): `maps:get(pos, Boid)` is its position. Two of
its keys are yours:

- `state` is the state of your module. Only the boid sees it.
- `data` is what the neighbors see of the boid.

Change the other keys with the functions of `boids_boid`, which check
the new values: `boids_boid:update/2`, `boids_boid:add_rule/2` and
`boids_boid:delete_rule/2`. The `id` of a boid does not change.

## The callbacks

Only `init/1` is necessary. A module with only `init/1` is a boid that
follows its rules.

| Callback | When it runs | It gives |
|---|---|---|
| `init(Args)` | The boid starts. | `{ok, Options}`: the options of the boid (`boids_boid`) and of its process (below), on top of the `defaults` of the world. Or `ignore`, or `{stop, Reason}`. |
| `handle_sense(Seen, Boid)` | At each step, after the library found what the boid perceives. | `{ok, Seen, Boid}` |
| `handle_decide(Seen, Boid)` | At each step, before the forces of the rules. | `{ok, Boid}` |
| `handle_act(Boid)` | At each step, after the movement. | `{ok, Boid}` |
| `handle_call(Request, From, Boid)` | `call/2` sent a request. | `{reply, Reply, Boid}` or `{noreply, Boid}` |
| `handle_cast(Request, Boid)` | `cast/2` sent a request. | `{noreply, Boid}` |
| `handle_info(Info, Boid)` | Another message came. | `{noreply, Boid}` |
| `terminate(Reason, Boid)` | The process stops. | |

Each callback can also give `{stop, Reason, Boid}`. `handle_call/3` can
give `{stop, Reason, Reply, Boid}`.

`Seen` is a map with what the boid perceives in this step: `neighbors`
(the boids that it sees, the nearest first), `obstacles`, `bounds`,
`wrap`, and `dt` (the seconds of the step). `handle_sense/2` can add
keys of yours, or change `neighbors`. The rules get `Seen` too, so a rule
of yours (a function) reads your keys.

## The options of the process

| Option | Default | Description |
|---|---|---|
| `tick` | `50` | The milliseconds between two steps, or `manual`: the boid moves only with `boids:step/2`. |
| `max_dt` | `0.25`, or 4 ticks | The maximum of the seconds of one step. A late tick does not make a long step. The default is the larger of 0.25 second and 4 ticks. |
| `search` | `1` | The boid searches the world for its neighbors each `search` steps. In the other steps, it reads only the neighbors that it knows. |
| `seed` | (none) | An integer: the seed of the random numbers of the process. |
| `priority` | `low` | The priority of the process: `low` or `normal`. |
| `hibernate` | `true` | The process hibernates between two steps. |

The time of a step is the time that passed on the monotonic clock,
multiplied by the scale of the time of the world. With the scale
0, the boid does not move, and its callbacks run with `dt` 0. The
process waits `tick` milliseconds after each step, so the time between
two steps is a little more than `tick`.

## The neighbors that a boid knows

The search of the neighbors is the largest part of a step. With `search
=> 4`, a boid searches the world at one step of 4. In the 3 other
steps, it reads the rows of the neighbors that it found: it sees them
where they are now, and it does not see a boid that came near after the
search. A world of such boids makes about 15 % more steps in a
second.

## The supervisor of a boid

`start/3` starts the boid below the supervisor of its world. That
supervisor does not start a boid again after an error. `start_link/3`
and `child_spec/1` are for a supervisor of yours, which starts the boid
again as you tell it. Give an `id` in the options of `init/1`, so that
the process that starts again is the same boid.

## A world on several nodes

In a world on several nodes, the process of a boid is on the node of
its tile (`boids:nodes/1`). After each step, a boid that sees a tile of
another node shows its row to that node. A boid of `start/3` that is in
a tile of another node moves: a process for the boid starts on that
node, below the supervisor of the world of that node, and this process
stops with the reason `{shutdown, {moved, Node}}`.

- The boid keeps its id, its state, its rules, its relations, the
  options of its process and its random numbers: a boid with a `seed`
  continues its sequence on the new node.
- `terminate/2` of the module runs on the first node. `init/1` does not
  run on the new node. The node needs the code of the module.
- The id of a boid is not its process. `boids:whereis/2` gives the
  process of an id. In a callback, the function `lookup` of `Seen`
  gives the row of a neighbor, with its process: `{ok, #{pid := Pid}} =
  (maps:get(lookup, Seen))(Id)`.
- A boid of `start_link/3` stays on the node of its supervisor. In a
  tile of another node, it shows its row to that node.
- The move waits for the answer of the other node, with no time limit.
  When the connection to that node ends, the boid stays on its node,
  and tries again at its next step.
- After a split of the network, a boid can have a process on two
  nodes. When the nodes have a connection again, one of the two
  processes stops with the reason `{shutdown, replaced}`
  (`boids_world`).

## A world with too much work

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
about 3 KB. Without it, the process holds about 100 KB.
""".
-behavior(gen_server).

-export([start/3, start/4, start_link/3, start_link/4, child_spec/1, stop/1]).
-export([call/2, call/3, cast/2, reply/2]).
-export([add_rule/2, delete_rule/2, which_rules/1]).
-export([options/1, start_child/5]).
-export([adopt/2, start_in_world/4]).
-export([init/1, handle_call/3, handle_cast/2, handle_info/2, terminate/2]).

-export_type([boid/0, start_options/0, seen/0]).

-type boid() :: pid() | atom() | {global, term()} | {via, module(), term()}.
-type start_options() :: #{name => atom() | {global, term()} | {via, module(), term()}} | [{name, term()}].
-type seen() :: boids_boid:seen().

-callback init(Args :: term()) ->
    {ok, Options :: boids:options()} | ignore | {stop, Reason :: term()}.
-callback handle_sense(Seen :: seen(), Boid :: boids_boid:boid()) ->
    {ok, seen(), boids_boid:boid()} | {stop, Reason :: term(), boids_boid:boid()}.
-callback handle_decide(Seen :: seen(), Boid :: boids_boid:boid()) ->
    {ok, boids_boid:boid()} | {stop, Reason :: term(), boids_boid:boid()}.
-callback handle_act(Boid :: boids_boid:boid()) ->
    {ok, boids_boid:boid()} | {stop, Reason :: term(), boids_boid:boid()}.
-callback handle_call(Request :: term(), From :: gen_server:from(), Boid :: boids_boid:boid()) ->
    {reply, Reply :: term(), boids_boid:boid()}
    | {noreply, boids_boid:boid()}
    | {stop, Reason :: term(), Reply :: term(), boids_boid:boid()}
    | {stop, Reason :: term(), boids_boid:boid()}.
-callback handle_cast(Request :: term(), Boid :: boids_boid:boid()) ->
    {noreply, boids_boid:boid()} | {stop, Reason :: term(), boids_boid:boid()}.
-callback handle_info(Info :: term(), Boid :: boids_boid:boid()) ->
    {noreply, boids_boid:boid()} | {stop, Reason :: term(), boids_boid:boid()}.
-callback terminate(Reason :: term(), Boid :: boids_boid:boid()) -> term().

-optional_callbacks([
    handle_sense/2, handle_decide/2, handle_act/1, handle_call/3, handle_cast/2, handle_info/2, terminate/2
]).

-define(KEYS, [tick, max_dt, search, seed, priority, hibernate]).

%% The start has a high priority: a world with too much work must not
%% make its caller wait.
%%
%% A boid that hibernates has a heap for its boid only. Without a
%% minimum size, the heap becomes larger 4 or 5 times in each step, each
%% time with a collection of the garbage: a quarter of the time of a
%% world. This minimum (in words) is sufficient for the garbage of one
%% step with about 15 neighbors. A boid that hibernates does not keep it.
-define(GEN, [{spawn_opt, [{priority, high}, {min_heap_size, 4185}]}]).

-doc """
Start a boid in a world, below the supervisor of that
world. The boid stops with its world, and it does not start
again after an error.

`World` is the process of the world, its name, or its space
(the map of `boids:space/1`). `Module` is the module of the boid, and
`init/1` of that module gets `Args`.

A bad option of `init/1` gives `{error, {bad_option, {Key, Value}}}`,
and an id that is in the world `{error, {exists, Id}}`.
""".
-spec start(boids:world(), module(), term()) -> {ok, pid()} | ignore | {error, term()}.
start(World, Module, Args) ->
    start(World, Module, Args, #{}).

-doc """
As `start/3`, with options for the process: a map, or a list of `{Key,
Value}`. The option is `name`, a name for the process: an atom,
`{global, Term}` or `{via, Module, Term}`.
""".
-spec start(boids:world(), module(), term(), start_options()) -> {ok, pid()} | ignore | {error, term()}.
start(World, Module, Args, Options0) ->
    Options = start_options(Options0),
    Space = boids:space(World),
    start_child(boids_world:boid_sup(Space), Space, Module, Args, Options).

-doc false.
%% The start of a boid below the supervisor of its world
%% (boids_boid_sup). Only such a boid moves to another node.
start_in_world(World, Module, Args, Options) ->
    link(World, Module, Args, Options, true).

-doc false.
start_child(Sup, Space, Module, Args, Options) ->
    case supervisor:start_child(Sup, [Space, Module, Args, Options]) of
        {ok, undefined} -> ignore;
        {ok, Pid} -> {ok, Pid};
        {error, {shutdown, Reason}} -> {error, Reason};
        {error, Reason} -> {error, Reason}
    end.

-doc """
Start a boid in a world, with a link to the caller: for a
supervisor of yours. Give the name of the world, and not its pid,
so that the boid finds a world that started again.

A bad option of `init/1` gives `{error, {shutdown, {bad_option, {Key,
Value}}}}`, and an id that is in the world `{error, {shutdown,
{exists, Id}}}`.
""".
-spec start_link(boids:world(), module(), term()) -> {ok, pid()} | ignore | {error, term()}.
start_link(World, Module, Args) ->
    start_link(World, Module, Args, #{}).

-doc "As `start_link/3`, with the options of `start/4`.".
-spec start_link(boids:world(), module(), term(), start_options()) -> {ok, pid()} | ignore | {error, term()}.
start_link(World, Module, Args, Options) ->
    link(World, Module, Args, Options, false).

%% Roams: the boid moves to another node when it crosses a border. A
%% boid below a supervisor of the user stays on the node of that
%% supervisor.
link(World, Module, Args, Options0, Roams) ->
    case start_options(Options0) of
        #{name := Name} when is_atom(Name) ->
            gen_server:start_link({local, Name}, ?MODULE, {World, Module, Args, Roams}, ?GEN);
        #{name := Name} ->
            gen_server:start_link(Name, ?MODULE, {World, Module, Args, Roams}, ?GEN);
        _ ->
            gen_server:start_link(?MODULE, {World, Module, Args, Roams}, ?GEN)
    end.

start_options(Options0) ->
    Options = boids_boid:to_map(Options0),
    [error({bad_option, {Key, Value}}) || Key := Value <- Options, Key =/= name],
    Options.

-doc """
The specification of a boid as a child of a supervisor of yours, from
`{World, Module, Args}` or `{World, Module, Args, Options}`
(see `start_link/4`).

```erlang
{ok, {#{strategy => rest_for_one}, [
    boids:child_spec(#{name => my_world}),
    gen_boid:child_spec({my_world, hawk, {50, 50}})
]}}
```

In Elixir, the child is `{:gen_boid, {:my_world, Hawk, {50, 50}}}`.
""".
-spec child_spec({boids:world(), module(), term()} | {boids:world(), module(), term(), start_options()}) ->
    supervisor:child_spec().
child_spec({World, Module, Args}) ->
    child_spec({World, Module, Args, #{}});
child_spec({World, Module, Args, Options}) ->
    #{id => {?MODULE, Module, Args}, start => {?MODULE, start_link, [World, Module, Args, Options]}}.

-doc "Stop a boid: its process stops with the reason `normal`.".
-spec stop(boid()) -> ok.
stop(Boid) ->
    gen_server:stop(Boid).

-doc """
Send a request to a boid, and wait for its answer: `handle_call/3` of
its module gives it. The time limit is 5 seconds.
""".
-spec call(boid(), term()) -> term().
call(Boid, Request) ->
    gen_server:call(Boid, {'$gen_boid', Request}).

-doc "As `call/2`, with a time limit in milliseconds, or `infinity`.".
-spec call(boid(), term(), timeout()) -> term().
call(Boid, Request, Timeout) ->
    gen_server:call(Boid, {'$gen_boid', Request}, Timeout).

-doc "Send a request to a boid, with no answer: `handle_cast/2` of its module gets it.".
-spec cast(boid(), term()) -> ok.
cast(Boid, Request) ->
    gen_server:cast(Boid, {'$gen_boid', Request}).

-doc "Answer a request of `call/2`, when `handle_call/3` gave `noreply`.".
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

-doc false.
%% Start a boid that comes from another node, below the supervisor of
%% the world of this node.
adopt(World, Moving) ->
    Space = boids:space(World),
    start_child(boids_world:boid_sup(Space), Space, '$adopt', Moving, #{}).

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
    Server = maps:merge(#{tick => 50, max_dt => MaxDt, search => 1, priority => low, hibernate => true}, Given),
    maps:foreach(fun check/2, Server),
    {Server, maps:without(?KEYS, Opts)}.

check(tick, manual) -> ok;
check(tick, Tick) when is_integer(Tick), Tick > 0 -> ok;
check(max_dt, Max) when is_number(Max), Max > 0 -> ok;
check(search, Search) when is_integer(Search), Search > 0 -> ok;
check(seed, Seed) when is_integer(Seed) -> ok;
check(priority, Priority) when Priority =:= low; Priority =:= normal -> ok;
check(hibernate, Hibernate) when is_boolean(Hibernate) -> ok;
check(Key, Value) -> error({bad_option, {Key, Value}}).

%% --- gen_server ------------------------------------------------------

-doc false.
%% A boid that comes from another node, with all its state.
init({World, '$adopt', Moving = #{boid := Boid = #{id := Id}, mod := Module, server := Server}, Roams}) ->
    #{moves := Moves, relations := Relations} = Moving,
    Space = boids:space(World),
    %% The callbacks of a module run only when the node has the module
    %% in memory. On the first node, init/1 of the module did that.
    _ = Module =:= undefined orelse code:ensure_loaded(Module),
    case join(Space, Server#{mod => Module, moves => Moves, roams => Roams}, Boid) of
        {ok, State} ->
            ok = boids_world:adopt(Space, Id, Relations),
            %% The random numbers of the boid continue.
            _ = [rand:seed(Rand) || #{rand := Rand} <- [Moving], Rand =/= undefined],
            {ok, State};
        Stop ->
            Stop
    end;
init({World, Module, Args, Roams}) ->
    %% A boid with no module (boids:add/2) has its options as arguments.
    Given =
        case Module of
            undefined -> {ok, Args};
            _ -> Module:init(Args)
        end,
    case Given of
        {ok, Opts} ->
            try
                Space = #{defaults := Defaults} = boids:space(World),
                {Server, BoidOpts} = options(maps:merge(Defaults, boids_boid:to_map(Opts))),
                {Space, Server, boids_boid:new(BoidOpts)}
            of
                {Space, Server, Boid} -> join(Space, Server#{mod => Module, moves => 0, roams => Roams}, Boid)
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
    %% The moves of the boid from node to node before this process: the
    %% world of a node keeps the process with the most moves.
    Entry = (boids_boid:entry(Boid))#{kind => server, moves => maps:get(moves, Server)},
    case boids_world:join(Space, self(), Entry) of
        ok ->
            %% The first tick comes after a random part of the period, so
            %% the boids of a world do not all move at the same time.
            Due =
                case Tick of
                    manual -> undefined;
                    _ -> wait(rand:uniform(Tick))
                end,
            process_flag(priority, Priority),
            {ok, Server#{
                space => Space,
                boid => Boid,
                last => now_us(),
                due => Due,
                pending => undefined,
                %% The neighbors that the boid knows from its last search,
                %% and the steps from that search.
                known => [],
                steps => 0,
                %% What the rules use to find a boid of the world.
                tools => #{
                    lookup => fun(Other) -> boids_space:lookup(Space, Other) end,
                    related => fun(From, Label) -> boids_space:related(Space, From, Label) end
                }
            }};
        {error, Reason} ->
            {stop, {shutdown, Reason}}
    end.

-doc false.
handle_call(get, _From, State = #{boid := Boid}) ->
    {reply, Boid, State};
handle_call({change, Function, Arg}, _From, State = #{boid := Boid}) ->
    try boids_boid:Function(Boid, Arg) of
        Changed -> {reply, ok, keep(Changed, State)}
    catch
        error:{bad_option, _} = Reason -> {reply, {error, Reason}, State}
    end;
handle_call({plan, Dt}, _From, State0) ->
    %% The first part of a step of boids:step/2 (specs/Step.tla, Plan).
    case plan(State0, Dt) of
        {ok, Moved, State} -> {reply, ok, State#{pending := Moved}};
        {stop, Reason, State} -> {stop, Reason, ok, State}
    end;
handle_call(commit, _From, State = #{pending := undefined}) ->
    {reply, ok, State};
handle_call(commit, _From, State0 = #{pending := Moved}) ->
    case act(Moved, State0) of
        {ok, State} -> rest({reply, ok, State});
        {stop, Reason, State} -> {stop, Reason, ok, State}
    end;
handle_call({'$gen_boid', Request}, From, State = #{mod := Module, boid := Boid}) ->
    case exported(Module, handle_call, 3) of
        true -> result(Module:handle_call(Request, From, Boid), State);
        false -> {stop, {bad_call, Request}, State}
    end.

-doc false.
handle_cast({'$gen_boid', Request}, State = #{mod := Module, boid := Boid}) ->
    case exported(Module, handle_cast, 2) of
        true -> result(Module:handle_cast(Request, Boid), State);
        false -> {stop, {bad_cast, Request}, State}
    end;
handle_cast(_Message, State) ->
    {noreply, State}.

-doc false.
handle_info(tick, State0 = #{tick := Tick, last := Last, max_dt := MaxDt}) ->
    Now = now_us(),
    maybe
        {ok, Moved, State1} ?= plan(State0, min((Now - Last) / 1.0e6, MaxDt)),
        {ok, State} ?= act(Moved, State1),
        %% The wait starts after the step, so a boid always has a rest.
        Due = wait(Tick + extra(Now - maps:get(due, State))),
        rest({noreply, State#{last := Now, due := Due}})
    else
        {stop, Reason, Stopped} -> {stop, Reason, Stopped}
    end;
handle_info({'EXIT', _World, {shutdown, replaced}}, State) ->
    %% Another process of the boid, with more moves, took the row of
    %% this process (boids_world). A process that does not trap exits
    %% stops without this message.
    {stop, {shutdown, replaced}, State};
handle_info(Info, State = #{mod := Module, boid := Boid}) ->
    case exported(Module, handle_info, 2) of
        true -> result(Module:handle_info(Info, Boid), State);
        false -> {noreply, State}
    end.

-doc false.
terminate(Reason, #{mod := Module, boid := Boid}) ->
    exported(Module, terminate, 2) andalso Module:terminate(Reason, Boid),
    ok.

%% A boid with no module has no callback.
exported(undefined, _Function, _Arity) -> false;
exported(Module, Function, Arity) -> erlang:function_exported(Module, Function, Arity).

%% --- One step --------------------------------------------------------

%% Sense and decide, then the movement, with no write to the
%% world: the result is the boid after the movement.
plan(State0 = #{space := Space, boid := Boid0 = #{id := Id}, mod := Module, tools := Tools}, Dt0) ->
    Env = #{time_scale := Scale} = boids_space:env(Space),
    Dt = Dt0 * Scale,
    {Neighbors, State} = look(State0),
    Seen0 = maps:merge(Env, Tools#{neighbors => Neighbors, dt => Dt}),
    maybe
        {ok, Seen, Boid1 = #{id := Id}} ?= sense(Module, Seen0, Boid0),
        {ok, Boid2 = #{id := Id}} ?= decide(Module, Seen, Boid1),
        {ok, boids_boid:step(Boid2, maps:get(neighbors, Seen), Seen, Dt), State}
    else
        {stop, Reason, Boid} -> {stop, Reason, State#{boid := Boid}}
    end.

sense(Module, Seen, Boid) ->
    case exported(Module, handle_sense, 2) of
        true -> Module:handle_sense(Seen, Boid);
        false -> {ok, Seen, Boid}
    end.

decide(Module, Seen, Boid) ->
    case exported(Module, handle_decide, 2) of
        true -> Module:handle_decide(Seen, Boid);
        false -> {ok, Boid}
    end.

%% The boid moved: its module acts, then the world gets its row.
act(Moved = #{id := Id}, State = #{space := Space, mod := Module}) ->
    Acted =
        case exported(Module, handle_act, 1) of
            true -> Module:handle_act(Moved);
            false -> {ok, Moved}
        end,
    case Acted of
        {ok, Boid = #{id := Id}} ->
            _ = boids_space:put(Space, Boid),
            Place = boids_world:settle(Space, Boid, maps:get(moves, State)),
            settle(Place, State#{boid := Boid, pending := undefined});
        {stop, Reason, Boid} ->
            {stop, Reason, State#{boid := Boid}}
    end.

%% The boid wrote its row. In a world on several nodes, a boid that is
%% in a tile of another node moves to that node: its process starts
%% there with all its state, and this process stops. A boid below a
%% supervisor of the user stays on its node.
settle({away, Home}, State = #{roams := true, space := Space = #{name := Name}, boid := Boid = #{id := Id}}) ->
    Moving = #{
        boid => Boid,
        mod => maps:get(mod, State),
        server => maps:without([seed], maps:with(?KEYS, State)),
        relations => boids_space:relations(Space, Id),
        moves => maps:get(moves, State) + 1,
        %% The state of the random numbers of this process.
        rand => rand:export_seed()
    },
    %% The call has no time limit. The connection between two nodes
    %% loses no message: the answer comes, or the connection ends and
    %% the call fails. Thus a slow node does not make two processes of
    %% one boid.
    try erpc:call(Home, ?MODULE, adopt, [Name, Moving], infinity) of
        Result when element(1, Result) =:= ok; Result =:= {error, {exists, Id}} ->
            %% With the answer exists, the boid is on that node already.
            boids_world:moved(Space, Id, self()),
            {stop, {shutdown, {moved, Home}}, State};
        {error, _Reason} ->
            {ok, State}
    catch
        %% The connection to the node ended: the boid stays, and tries
        %% again at its next step.
        _:_ -> {ok, State}
    end;
settle(_Place, State) ->
    {ok, State}.

%% The neighbors that the boid sees. At one step of `search`, the boid
%% searches the grid. At the other steps, it reads the rows of the boids
%% that it found.
look(State = #{space := Space, boid := Boid, search := 1}) ->
    #{pos := Pos, perception := Perception} = Boid,
    {boids_boid:perceive(Boid, boids_space:near(Space, Pos, Perception)), State};
look(State = #{space := Space, boid := Boid, search := Search, steps := Steps, known := Known}) ->
    #{pos := Pos, perception := Perception} = Boid,
    case Steps of
        0 ->
            Near = boids_space:near(Space, Pos, Perception),
            Ids = [Id || #{id := Id} <- Near],
            {boids_boid:perceive(Boid, Near), State#{steps := 1 rem Search, known := Ids}};
        _ ->
            Near = boids_space:seen(Space, Pos, Perception, Known),
            {boids_boid:perceive(Boid, Near), State#{steps := (Steps + 1) rem Search}}
    end.

%% The result of a callback of the module, as a result of gen_server.
result({reply, Reply, Boid}, State) -> {reply, Reply, keep(Boid, State)};
result({noreply, Boid}, State) -> {noreply, keep(Boid, State)};
result({stop, Reason, Reply, Boid}, State) -> {stop, Reason, Reply, State#{boid := Boid}};
result({stop, Reason, Boid}, State) -> {stop, Reason, State#{boid := Boid}}.

%% Keep the boid that a callback gave. When it changed, the world gets
%% its row, and a step that the boid calculated before is not good.
keep(Boid, State = #{boid := Boid}) ->
    State;
keep(Boid = #{id := Id}, State = #{space := Space, boid := #{id := Id}, moves := Moves}) ->
    _ = boids_space:put(Space, Boid),
    _ = boids_world:settle(Space, Boid, Moves),
    State#{boid := Boid, pending := undefined}.

%% --- The clock -------------------------------------------------------

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
