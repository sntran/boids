-module(boids_flock).
-moduledoc """
The process of a flock: the owner of the space, and the list of the
processes that have a boid in it.

The process of a boid writes its own row in the space, with no message
to this process. This process adds the row at the start, and it removes
the row when the process of the boid stops.

Use the functions of `boids`. A flock starts with `boids:start_flock/1`,
or as a child of your supervisor with `boids:child_spec/1`.
""".
-behavior(gen_server).

-export([start_link/2, options/1, space/1, sup/1, boid_sup/1, join/3, leave/3]).
-export([init/1, handle_call/3, handle_cast/2, handle_info/2]).

-export_type([flock/0]).

-type flock() :: pid() | atom() | {global, term()} | {via, module(), term()}.

-doc false.
start_link(Sup, Opts0) ->
    Opts = options(Opts0),
    case maps:take(name, Opts) of
        {Name, Rest} when is_atom(Name) -> gen_server:start_link({local, Name}, ?MODULE, {Sup, Rest, Name}, []);
        {Name, Rest} -> gen_server:start_link(Name, ?MODULE, {Sup, Rest, Name}, []);
        error -> gen_server:start_link(?MODULE, {Sup, Opts, undefined}, [])
    end.

-doc """
Check the options of a flock, and give them as a map. A bad option gives
the error `{bad_option, {Key, Value}}`.
""".
-spec options(map() | [{atom(), term()}]) -> map().
options(Opts) when is_list(Opts) ->
    try
        options(maps:from_list(Opts))
    catch
        error:badarg -> error({bad_option, Opts})
    end;
options(Opts) when is_map(Opts) ->
    Space = boids_space:options(maps:remove(name, Opts)),
    %% Each default is good alone. The check of a boid sees them together,
    %% with its own options.
    {_Server, Boid} = gen_boid:options(maps:get(defaults, Space)),
    _ = boids_boid:options(Boid),
    case Opts of
        #{name := Name} when is_atom(Name) -> Opts;
        #{name := {global, _}} -> Opts;
        #{name := {via, Module, _}} when is_atom(Module) -> Opts;
        #{name := Name} -> error({bad_option, {name, Name}});
        _ -> Opts
    end;
options(Opts) ->
    error({bad_option, Opts}).

-doc "The space of a flock.".
-spec space(flock()) -> boids_space:space().
space(Flock) ->
    gen_server:call(Flock, space).

-doc false.
sup(Flock) ->
    gen_server:call(Flock, sup).

-doc false.
boid_sup(#{owner := Flock}) ->
    gen_server:call(Flock, boid_sup).

-doc """
Add the row of a boid of the process `Pid` to the space. The flock
removes the row when the process stops. All the boids of a flock have
positions of the same size: two numbers, or three.
""".
-spec join(boids_space:space(), pid(), boids_space:entry()) ->
    ok | {error, {exists, term()} | {bad_option, {pos, term()}}}.
join(#{owner := Flock}, Pid, Entry) ->
    gen_server:call(Flock, {join, Pid, Entry}).

-doc """
Remove the row of a boid of the process `Pid` from the space. When
another process has the id now, its row stays.
""".
-spec leave(boids_space:space(), term(), pid()) -> ok.
leave(#{owner := Flock}, Id, Pid) ->
    gen_server:call(Flock, {leave, Id, Pid}).

%% --- gen_server -------------------------------------------------------

-doc false.
init({Sup, Opts, Name}) ->
    %% The tools that show processes show that this process is a flock.
    proc_lib:set_label({boids, flock, Name}),
    %% The boids of a flock that has too much work run all the time. The
    %% flock must answer then too.
    process_flag(priority, high),
    {ok, #{space => boids_space:new(Opts), sup => Sup, ids => #{}, refs => #{}}}.

-doc false.
handle_call(space, _From, State = #{space := Space}) ->
    {reply, Space, State};
handle_call(sup, _From, State = #{sup := Sup}) ->
    {reply, Sup, State};
handle_call(boid_sup, _From, State = #{sup := Sup}) ->
    [Pid] = [Pid || {boids_boid_sup, Pid, _, _} <- supervisor:which_children(Sup)],
    {reply, Pid, State};
handle_call({join, Pid, Entry = #{id := Id, pos := Pos}}, _From, State0 = #{space := Space}) ->
    State = #{ids := Ids, refs := Refs} = forget_dead(Id, State0),
    Dim = boids_space:dim(Space),
    case Dim =:= undefined orelse Dim =:= tuple_size(Pos) of
        true ->
            case boids_space:insert_new(Space, Entry#{pid => Pid}) of
                true ->
                    Ref = monitor(process, Pid),
                    {reply, ok, State#{ids := Ids#{Id => Ref}, refs := Refs#{Ref => Id}}};
                false ->
                    {reply, {error, {exists, Id}}, State}
            end;
        false ->
            {reply, {error, {bad_option, {pos, Pos}}}, State}
    end;
handle_call({leave, Id, Pid}, _From, State = #{space := Space}) ->
    %% A leave can come late: after the end of its process, and after
    %% another process has the id (specs/Flock.tla, CheckOwner).
    case boids_space:lookup(Space, Id) of
        {ok, #{pid := Pid}} -> {reply, ok, forget(Id, State)};
        _ -> {reply, ok, State}
    end.

-doc false.
handle_cast(_Message, State) ->
    {noreply, State}.

-doc false.
handle_info({'DOWN', Ref, process, _Pid, _Reason}, State = #{refs := Refs}) ->
    case Refs of
        #{Ref := Id} -> {noreply, forget(Id, State)};
        _ -> {noreply, State}
    end;
handle_info(_Message, State) ->
    {noreply, State}.

%% A boid that starts again with its id can come before the message
%% 'DOWN' of its last process (specs/Flock.tla, TakeOver).
forget_dead(Id, State = #{space := Space}) ->
    case boids_space:lookup(Space, Id) of
        {ok, #{pid := Pid}} when node(Pid) =:= node() ->
            case is_process_alive(Pid) of
                true -> State;
                false -> forget(Id, State)
            end;
        _ ->
            State
    end.

forget(Id, State = #{space := Space, ids := Ids, refs := Refs}) ->
    boids_space:remove(Space, Id),
    case Ids of
        #{Id := Ref} ->
            demonitor(Ref, [flush]),
            State#{ids := maps:remove(Id, Ids), refs := maps:remove(Ref, Refs)};
        _ ->
            State
    end.
