-module(boids_world).
-moduledoc """
The process of a world: the owner of its tables, the list of the
processes that have a boid in it, and the relations between the boids.

The process of a boid writes its own row in the world, with no message
to this process. This process adds the row at the start, and it removes
the row when the process of the boid stops.

The relations are a graph (`graph`): a boid is a vertex, and a relation
is an edge with a label. This process has the graph, and it writes a
copy of the relations of each boid to a table, where the boids read
them with no message.

Use the functions of `boids`. A world starts with
`boids:start_world/1`, or as a child of your supervisor with
`boids:child_spec/1`.
""".
-behavior(gen_server).

-export([start_link/2, options/1, space/1, sup/1, boid_sup/1, join/3, leave/3]).
-export([relate/4, unrelate/4, relations/1]).
-export([init/1, handle_call/3, handle_cast/2, handle_info/2]).

-export_type([server/0]).

-type server() :: pid() | atom() | {global, term()} | {via, module(), term()}.

-doc false.
start_link(Sup, Opts0) ->
    Opts = options(Opts0),
    case maps:take(name, Opts) of
        {Name, Rest} when is_atom(Name) -> gen_server:start_link({local, Name}, ?MODULE, {Sup, Rest, Name}, []);
        {Name, Rest} -> gen_server:start_link(Name, ?MODULE, {Sup, Rest, Name}, []);
        error -> gen_server:start_link(?MODULE, {Sup, Opts, undefined}, [])
    end.

-doc """
Check the options of a world, and give them as a map. A bad
option gives the error `{bad_option, {Key, Value}}`.
""".
-spec options(map() | [{atom(), term()}]) -> map().
options(Opts) when is_list(Opts) ->
    try
        options(maps:from_list(Opts))
    catch
        error:badarg -> error({bad_option, Opts})
    end;
options(Opts) when is_map(Opts) ->
    {_Relations, Rest} = kind(maps:remove(name, Opts)),
    Space = boids_space:options(Rest),
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

%% The option relations of a world, and the other options.
kind(Opts) ->
    case maps:take(relations, Opts) of
        {Kind, Rest} when Kind =:= cyclic; Kind =:= acyclic -> {Kind, Rest};
        {Kind, _Rest} -> error({bad_option, {relations, Kind}});
        error -> {cyclic, Opts}
    end.

-doc "The space of a world: the map with its tables (`boids_space`).".
-spec space(server()) -> boids_space:space().
space(Server) ->
    gen_server:call(Server, space).

-doc false.
sup(Server) ->
    gen_server:call(Server, sup).

-doc false.
boid_sup(#{owner := Server}) ->
    gen_server:call(Server, boid_sup).

-doc """
Add the row of a boid of the process `Pid` to the world. The
world removes the row when the process stops. All the boids of an
world have positions of the same size: two numbers, or three.
""".
-spec join(boids_space:space(), pid(), boids_space:entry()) ->
    ok | {error, {exists, term()} | {bad_option, {pos, term()}}}.
join(#{owner := Server}, Pid, Entry) ->
    gen_server:call(Server, {join, Pid, Entry}).

-doc """
Remove the row of a boid of the process `Pid` from the world. When
another process has the id now, its row stays.
""".
-spec leave(boids_space:space(), term(), pid()) -> ok.
leave(#{owner := Server}, Id, Pid) ->
    gen_server:call(Server, {leave, Id, Pid}).

-doc """
Add the relation `Label` from the boid `From` to the boid `To`. The
result is `{error, {not_found, Id}}` for an id that is not in the
world, and `{error, cycle}` when the world has the option
`relations => acyclic` and the relation makes a cycle.
""".
-spec relate(boids_space:space(), term(), term(), term()) -> ok | {error, {not_found, term()} | cycle}.
relate(#{owner := Server}, From, Label, To) ->
    gen_server:call(Server, {relate, From, Label, To}).

-doc "Remove the relation `Label` from the boid `From` to the boid `To`.".
-spec unrelate(boids_space:space(), term(), term(), term()) -> ok.
unrelate(#{owner := Server}, From, Label, To) ->
    gen_server:call(Server, {unrelate, From, Label, To}).

-doc """
The graph of the relations: each boid with a relation is a vertex, and
each relation is an edge with its label.
""".
-spec relations(boids_space:space()) -> graph:graph().
relations(#{owner := Server}) ->
    gen_server:call(Server, relations).

%% --- gen_server ------------------------------------------------------

-doc false.
init({Sup, Opts, Name}) ->
    %% The tools that show processes show that this process is an
    %% world.
    proc_lib:set_label({boids, world, Name}),
    %% The boids of a world that has too much work run all the
    %% time. The world must answer then too.
    process_flag(priority, high),
    {Relations, Rest} = kind(Opts),
    Links = graph:new([Relations]),
    {ok, #{space => boids_space:new(Rest), sup => Sup, ids => #{}, refs => #{}, links => Links}}.

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
    case boids_space:fit(Space, Pos) of
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
handle_call({relate, From, Label, To}, _From, State = #{space := Space, links := Links0}) ->
    case [Id || Id <- [From, To], boids_space:lookup(Space, Id) =:= error] of
        [] ->
            Links1 = graph:add_vertex(graph:add_vertex(Links0, From), To),
            try graph:add_edge(Links1, From, To, Label) of
                Links ->
                    publish(Space, Links, [From, To], Label),
                    {reply, ok, State#{links := Links}}
            catch
                %% The graph has no cycle (the option relations).
                error:{bad_edge, _} -> {reply, {error, cycle}, State}
            end;
        [Id | _] ->
            {reply, {error, {not_found, Id}}, State}
    end;
handle_call({unrelate, From, Label, To}, _From, State = #{space := Space, links := Links0}) ->
    Links = graph:del_edge(Links0, {From, To, Label}),
    publish(Space, Links, [From, To], Label),
    {reply, ok, State#{links := Links}};
handle_call(relations, _From, State = #{links := Links}) ->
    {reply, Links, State};
handle_call({leave, Id, Pid}, _From, State = #{space := Space}) ->
    %% A leave can come late: after the end of its process, and after
    %% another process has the id (specs/Members.tla, CheckOwner).
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
%% 'DOWN' of its last process (specs/Members.tla, TakeOver).
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

forget(Id, State0 = #{space := Space}) ->
    boids_space:remove(Space, Id),
    State = #{ids := Ids, refs := Refs} = unrelate(Id, State0),
    case Ids of
        #{Id := Ref} ->
            demonitor(Ref, [flush]),
            State#{ids := maps:remove(Id, Ids), refs := maps:remove(Ref, Refs)};
        _ ->
            State
    end.

%% A boid that goes from the world has no relation.
unrelate(Id, State = #{space := Space, links := Links0}) ->
    case graph:has_vertex(Links0, Id) of
        true ->
            Edges = graph:out_edges(Links0, Id) ++ graph:in_edges(Links0, Id),
            Links = graph:del_vertex(Links0, Id),
            [publish(Space, Links, [From, To], Label) || {From, To, Label} <- Edges],
            State#{links := Links};
        false ->
            State
    end.

%% Write the relations with a label of boids to the table of the
%% world, in the two directions: the boids read them there at each
%% step.
publish(Space, Links, Ids, Label) ->
    lists:foreach(
        fun(Id) ->
            {Out, In} =
                case graph:has_vertex(Links, Id) of
                    true ->
                        {
                            [To || {_, To, L} <- graph:out_edges(Links, Id), L =:= Label],
                            [From || {From, _, L} <- graph:in_edges(Links, Id), L =:= Label]
                        };
                    false ->
                        {[], []}
                end,
            boids_space:relate(Space, out, {Id, Label}, Out),
            boids_space:relate(Space, in, {Id, Label}, In)
        end,
        Ids
    ).
