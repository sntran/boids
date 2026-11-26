-module(boids_worker).
-moduledoc false.
-behavior(gen_server).

%% A worker of a flock: a process that holds boids as values, and makes
%% their steps. A flock has a small number of workers, so the boids use
%% all the processors with no process for each boid.
%%
%% The clock of the flock (boids_clock) asks for a step in two parts.
%% In the first part (plan), each worker calculates the step of each of
%% its boids, and writes nothing. In the second part (commit), each
%% worker writes its boids to the space. Thus all the boids calculate
%% from the same state of the flock (specs/Step.tla).

-export([start_link/2, of_id/2]).
-export([add/2, add_all/2, remove/2, get/2, change/4]).
-export([init/1, handle_call/3, handle_cast/2, handle_info/2]).

start_link(Space, Number) ->
    gen_server:start_link(?MODULE, {Space, Number}, [{spawn_opt, [{priority, low}]}]).

%% The worker of an id. An id is always with the same worker.
of_id(#{workers := Workers}, Id) ->
    element(erlang:phash2(Id, tuple_size(Workers)) + 1, Workers).

%% Add a boid: the result is ok, {error, {exists, Id}} or {error,
%% {bad_option, {pos, Pos}}}.
add(Space, Boid = #{id := Id}) ->
    gen_server:call(of_id(Space, Id), {add, Boid}, infinity).

%% Add boids with new ids, with one message for each worker.
add_all(Space = #{workers := Workers}, Boids) ->
    Parts = maps:groups_from_list(fun(#{id := Id}) -> of_id(Space, Id) end, Boids),
    Sent = [gen_server:send_request(Worker, {add_all, Part}) || Worker := Part <- Parts],
    true = tuple_size(Workers) >= length(Sent),
    lists:foreach(fun(Request) -> {reply, ok} = gen_server:receive_response(Request, infinity) end, Sent).

remove(Space, Id) ->
    gen_server:call(of_id(Space, Id), {remove, Id}, infinity).

get(Space, Id) ->
    gen_server:call(of_id(Space, Id), {get, Id}, infinity).

%% Change a boid with a function of boids_boid: update, add_rule or
%% delete_rule.
change(Space, Id, Function, Arg) ->
    gen_server:call(of_id(Space, Id), {change, Id, Function, Arg}, infinity).

%% --- gen_server -------------------------------------------------------

init({Space, Number}) ->
    proc_lib:set_label({boids, worker, Number}),
    %% pending has the boids after the step that the worker calculated,
    %% before their write. stale has the ids of the boids that changed
    %% after that calculation: their step is not good.
    {ok, #{space => Space, boids => #{}, pending => [], stale => #{}}}.

handle_call({plan, Dt}, _From, State = #{space := Space, boids := Boids}) ->
    {reply, ok, State#{pending := plan(Space, Boids, Dt), stale := #{}}};
handle_call(commit, _From, State = #{space := Space, boids := Boids, pending := Pending, stale := Stale}) ->
    Moved = commit(Space, Pending, Stale, []),
    Next =
        case map_size(Stale) =:= 0 andalso length(Moved) =:= map_size(Boids) of
            %% Each boid of the worker made the step: the usual step.
            true -> maps:from_list(Moved);
            false ->
                Failed = [Id || {Id, {failed, _}} <- Pending, not is_map_key(Id, Stale)],
                maps:merge(maps:without(Failed, Boids), maps:from_list(Moved))
        end,
    {reply, ok, State#{boids := Next, pending := [], stale := #{}}};
handle_call({add, Boid = #{id := Id, pos := Pos}}, _From, State = #{space := Space, boids := Boids}) ->
    case boids_space:fit(Space, Pos) of
        true ->
            case insert(Space, Boid) of
                true -> {reply, ok, stale(Id, State#{boids := Boids#{Id => Boid}})};
                false -> {reply, {error, {exists, Id}}, State}
            end;
        false ->
            {reply, {error, {bad_option, {pos, Pos}}}, State}
    end;
handle_call({add_all, New}, _From, State = #{space := Space, boids := Boids}) ->
    Added = #{Id => Boid || Boid = #{id := Id} <- New, insert(Space, Boid)},
    {reply, ok, State#{boids := maps:merge(Boids, Added)}};
handle_call({remove, Id}, _From, State = #{space := Space, boids := Boids}) ->
    case Boids of
        #{Id := _} ->
            boids_space:remove(Space, Id),
            {reply, ok, stale(Id, State#{boids := maps:remove(Id, Boids)})};
        _ ->
            {reply, {error, not_found}, State}
    end;
handle_call({get, Id}, _From, State = #{boids := Boids}) ->
    case Boids of
        #{Id := Boid} -> {reply, {ok, Boid}, State};
        _ -> {reply, {error, not_found}, State}
    end;
handle_call({change, Id, Function, Arg}, _From, State = #{space := Space, boids := Boids}) ->
    case Boids of
        #{Id := Boid0} ->
            try boids_boid:Function(Boid0, Arg) of
                Boid ->
                    boids_space:put(Space, Boid),
                    {reply, ok, stale(Id, State#{boids := Boids#{Id := Boid}})}
            catch
                error:{bad_option, _} = Reason -> {reply, {error, Reason}, State}
            end;
        _ ->
            {reply, {error, not_found}, State}
    end.

handle_cast(_Message, State) ->
    {noreply, State}.

handle_info(_Message, State) ->
    {noreply, State}.

insert(Space, Boid) ->
    boids_space:insert_new(Space, (boids_boid:entry(Boid))#{kind => data}).

%% Between the two parts of a step, a change of a boid makes its step
%% not good.
stale(_Id, State = #{pending := []}) -> State;
stale(Id, State = #{stale := Stale}) -> State#{stale := Stale#{Id => true}}.

%% The step of each boid, with no write to the space. The boids read
%% each cell of the grid one time, and the environment one time. The
%% result is a list of {Id, Boid}, or {Id, {failed, Error}}.
plan(Space, Boids, Dt0) ->
    Env0 = #{time_scale := Scale} = boids_space:env(Space),
    case Dt0 * Scale of
        Dt when Dt > 0 ->
            Env = Env0#{lookup => fun(Id) -> boids_space:lookup(Space, Id) end},
            %% In the order of the cells, the boids that come one after
            %% the other read the same cells: the processor has them in
            %% its cache.
            Sorted = lists:sort([{boids_space:cell(Space, Pos), Id, Boid} || Id := Boid = #{pos := Pos} <- Boids]),
            plan(Sorted, Space, Env, Dt, none, {#{}, #{}}, []);
        _ ->
            []
    end.

plan([{Cell, Id, Boid = #{pos := Pos, perception := Perception}} | Rest], Space, Env, Dt, Line0, Cache0, Acc) ->
    %% The worker keeps the cells that it read for the boids of this
    %% line of cells and of the line before. The cells of the lines
    %% before those are garbage: a worker that keeps all the cells
    %% uses a third of its time for the collection of the garbage.
    {Line, Cache1} =
        case {element(1, Cell), Cache0} of
            {Line0, _} -> {Line0, Cache0};
            {Other, {New, _Old}} -> {Other, {#{}, New}}
        end,
    {Near, Cache} = boids_space:near(Space, Pos, Perception, Cache1),
    try boids_boid:step(Boid, boids_boid:perceive(Boid, Near), Env, Dt) of
        Next -> plan(Rest, Space, Env, Dt, Line, Cache, [{Id, Next} | Acc])
    catch
        Class:Reason:Stack ->
            plan(Rest, Space, Env, Dt, Line, Cache, [{Id, {failed, {Class, Reason, Stack}}} | Acc])
    end;
plan([], _Space, _Env, _Dt, _Line, _Cache, Acc) ->
    Acc.

%% Write the boids of a step to the space. The result has the boids
%% that moved. A boid whose rule had an error goes from the flock.
commit(Space, [{Id, Boid} | Rest], Stale, Acc) when is_map_key(Id, Stale) ->
    _ = Boid,
    commit(Space, Rest, Stale, Acc);
commit(Space, [{Id, {failed, Error}} | Rest], Stale, Acc) ->
    logger:error(
        "The boid ~0tp stops, because a rule of the boid had an error: ~0tp",
        [Id, Error],
        #{domain => [boids]}
    ),
    boids_space:remove(Space, Id),
    commit(Space, Rest, Stale, Acc);
commit(Space, [Moved = {_Id, Boid} | Rest], Stale, Acc) ->
    boids_space:put(Space, Boid),
    commit(Space, Rest, Stale, [Moved | Acc]);
commit(_Space, [], _Stale, Acc) ->
    Acc.
