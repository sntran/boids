-module(boids_server).
-moduledoc """
The process of one boid.

The process holds a boid (`boids_boid`). At each tick, it reads its
neighbors from the space of its flock, calculates the force of its
rules, moves, and writes its new row. It does this without a message to
another process.

`boids:add/2` starts such a process below the supervisor of the flock.
That supervisor does not start a boid again after an error. For a boid
that starts again, use `start_link/2` or `child_spec/1` below a
supervisor of yours.

The options are the options of a boid (see `boids_boid`), and these:

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

-export([start_link/2, child_spec/1, options/1]).
-export([init/1, handle_call/3, handle_cast/2, handle_info/2]).

-define(KEYS, [tick, max_dt, seed, priority, hibernate]).

-doc """
Start the process of a boid in a flock, with a link to the caller. The
options are those of `boids:add/2`, on top of the `defaults` of the
flock. Give an `id`, so that a process that starts again is the same
boid.

A bad option gives `{error, {shutdown, {bad_option, {Key, Value}}}}`,
and an id that is in the flock `{error, {shutdown, {exists, Id}}}`.
""".
-spec start_link(boids:flock(), boids:options()) -> {ok, pid()} | {error, term()}.
start_link(Flock, Opts) ->
    %% The start has a high priority: a flock with too much work must not
    %% make its caller wait.
    gen_server:start_link(?MODULE, {Flock, Opts}, [{spawn_opt, [{priority, high}]}]).

-doc """
The specification of a boid as a child of a supervisor of yours, from
`{Flock, Options}`. Give the name of the flock, and not its pid, so that
the boid finds a flock that started again.

```erlang
{ok, {#{strategy => rest_for_one}, [
    boids:child_spec(#{name => my_flock}),
    boids_server:child_spec({my_flock, #{id => hawk, pos => {0, 0}}})
]}}
```

In Elixir, the child is `{:boids_server, {:my_flock, id: :hawk, pos: {0, 0}}}`.
""".
-spec child_spec({boids:flock(), boids:options()}) -> supervisor:child_spec().
child_spec({Flock, Opts}) ->
    Id = proplists:get_value(id, maps:to_list(boids_boid:to_map(Opts)), make_ref()),
    #{id => {?MODULE, Id}, start => {?MODULE, start_link, [Flock, Opts]}}.

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
init({Flock, Opts}) ->
    try
        Space = #{defaults := Defaults} = boids:space(Flock),
        {Server, BoidOpts} = options(maps:merge(Defaults, boids_boid:to_map(Opts))),
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
            {stop, {shutdown, Reason}}
    end.

-doc false.
handle_call(get, _From, State = #{boid := Boid}) ->
    {reply, Boid, State};
handle_call({update, Changes}, _From, State = #{space := Space, boid := Boid0}) ->
    try boids_boid:update(Boid0, Changes) of
        Boid ->
            boids:commit(Space, Boid),
            {reply, ok, State#{boid := Boid, pending := undefined}}
    catch
        error:{bad_option, _} = Reason -> {reply, {error, Reason}, State}
    end;
handle_call({plan, Dt}, _From, State = #{space := Space, boid := Boid}) ->
    {reply, ok, State#{pending := boids:plan(Space, Boid, Dt)}};
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
    Boid = boids:advance(Space, Boid0, min((Now - Last) / 1.0e6, MaxDt)),
    %% The wait starts after the step, so a boid always has a rest.
    Due = wait(Tick + extra(Now - maps:get(due, State))),
    rest({noreply, State#{boid := Boid, last := Now, due := Due}});
handle_info(_Message, State) ->
    {noreply, State}.

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
