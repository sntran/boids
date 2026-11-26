-module(boids_clock).
-moduledoc false.
-behavior(gen_server).

%% The clock of a flock: the process that makes the steps of the flock.
%% A step has two parts (specs/Step.tla). First each worker and each
%% gen_boid calculates the step of its boids, and the flock does not
%% change. Then each of them writes its boids.

-export([start_link/2, options/1, step/2, attach/1, subscribe/2, unsubscribe/2]).
-export([init/1, handle_call/3, handle_cast/2, handle_info/2]).

-define(KEYS, [tick, max_dt, workers]).

start_link(Space, Opts) ->
    gen_server:start_link(?MODULE, {Space, Opts}, []).

%% Divide the options of a flock into those of the clock, with their
%% defaults, and the others. A bad option gives the error {bad_option,
%% {Key, Value}}.
options(Opts) ->
    Given = maps:with(?KEYS, Opts),
    MaxDt =
        case Given of
            #{tick := Tick} when is_integer(Tick) -> max(0.25, 4 * Tick / 1000);
            _ -> 0.25
        end,
    Clock = maps:merge(#{tick => 50, max_dt => MaxDt, workers => erlang:system_info(schedulers_online)}, Given),
    maps:foreach(fun check/2, Clock),
    {Clock, maps:without(?KEYS, Opts)}.

check(tick, manual) -> ok;
check(tick, Tick) when is_integer(Tick), Tick > 0 -> ok;
check(max_dt, Max) when is_number(Max), Max > 0 -> ok;
check(workers, Count) when is_integer(Count), Count > 0, Count =< 1024 -> ok;
check(Key, Value) -> error({bad_option, {Key, Value}}).

%% Make one step of Dt seconds. The function returns after the step.
step(#{clock := Clock}, Dt) ->
    gen_server:call(Clock, {step, Dt}, infinity).

%% The gen_boid that calls this function moves at each step of the clock.
attach(#{clock := Clock}) ->
    gen_server:call(Clock, {attach, self()}, infinity).

subscribe(#{clock := Clock}, Pid) ->
    gen_server:call(Clock, {subscribe, Pid}, infinity).

unsubscribe(#{clock := Clock}, Pid) ->
    gen_server:call(Clock, {unsubscribe, Pid}, infinity).

%% --- gen_server -------------------------------------------------------

init({Space = #{owner := Flock, workers := Workers}, Opts = #{tick := Tick}}) ->
    proc_lib:set_label({boids, clock, Flock}),
    %% The clock must run when the workers use all the processors.
    process_flag(priority, high),
    Now = now_us(),
    State = Opts#{
        space => Space,
        workers => tuple_to_list(Workers),
        servers => #{},
        subscribers => #{},
        count => 0,
        last => Now,
        due => Now
    },
    {ok, wait(State, Tick)}.

handle_call({step, Dt}, _From, State) when is_number(Dt), Dt >= 0 ->
    {reply, ok, run(State, Dt)};
handle_call({attach, Pid}, _From, State = #{servers := Servers}) ->
    {reply, ok, State#{servers := Servers#{Pid => monitor(process, Pid)}}};
handle_call({subscribe, Pid}, _From, State = #{subscribers := Subscribers}) ->
    case Subscribers of
        #{Pid := _} -> {reply, ok, State};
        _ -> {reply, ok, State#{subscribers := Subscribers#{Pid => monitor(process, Pid)}}}
    end;
handle_call({unsubscribe, Pid}, _From, State = #{subscribers := Subscribers}) ->
    case maps:take(Pid, Subscribers) of
        {Ref, Rest} ->
            demonitor(Ref, [flush]),
            {reply, ok, State#{subscribers := Rest}};
        error ->
            {reply, ok, State}
    end.

handle_cast(_Message, State) ->
    {noreply, State}.

handle_info(tick, State = #{tick := Tick, last := Last, max_dt := MaxDt}) ->
    Now = now_us(),
    %% A late tick does not make a long step.
    Stepped = run(State#{last := Now}, min((Now - Last) / 1.0e6, MaxDt)),
    {noreply, wait(Stepped, Tick)};
handle_info({'DOWN', _Ref, process, Pid, _Reason}, State = #{servers := Servers, subscribers := Subscribers}) ->
    {noreply, State#{servers := maps:remove(Pid, Servers), subscribers := maps:remove(Pid, Subscribers)}};
handle_info(_Message, State) ->
    {noreply, State}.

%% One step of the flock, then a message to each subscriber.
run(State = #{space := #{owner := Flock}, workers := Workers, servers := Servers, subscribers := Subscribers}, Dt) ->
    Count = maps:get(count, State) + 1,
    Pids = Workers ++ maps:keys(Servers),
    request(Pids, {plan, Dt}),
    request(Pids, commit),
    maps:foreach(fun(Pid, _Ref) -> Pid ! {boids, Flock, {step, Count, Dt}} end, Subscribers),
    State#{count := Count}.

%% A gen_boid that stops during the step gives an error, which changes
%% nothing for the other boids.
request(Pids, Request) ->
    Sent = [gen_server:send_request(Pid, Request) || Pid <- Pids],
    lists:foreach(fun(Id) -> gen_server:receive_response(Id, infinity) end, Sent).

%% The ticks have a constant period. When the steps need more time than
%% the period, the next tick comes immediately, and the period starts
%% again from there.
wait(State, manual) ->
    State;
wait(State = #{due := Due}, Tick) ->
    Now = now_us(),
    Next = max(Due + Tick * 1000, Now),
    erlang:send_after((Next - Now) div 1000, self(), tick),
    State#{due := Next}.

now_us() ->
    erlang:monotonic_time(microsecond).
