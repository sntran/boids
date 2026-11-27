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
-export([relate/5, unrelate/4, relations/1]).
-export([settle/2, find/2, find_local/2, moved/3, adopt/3]).

%% A row of a boid of another node that gets no update in this time goes.
-define(GHOST_MS, 500).
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
world removes the row when the process stops. All the boids of a
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
-spec relate(boids_space:space(), term(), term(), term(), boolean()) -> ok | {error, {not_found, term()} | cycle}.
relate(#{owner := Server}, From, Label, To, Found) ->
    gen_server:call(Server, {relate, From, Label, To, Found}).

-doc "Remove the relation `Label` from the boid `From` to the boid `To`.".
-spec unrelate(boids_space:space(), term(), term(), term()) -> ok.
unrelate(#{owner := Server}, From, Label, To) ->
    gen_server:call(Server, {unrelate, From, Label, To}).

-doc """
Show a boid that wrote its row to the other nodes that it is near. The
result is `{away, Home}` for a boid in a tile of the node `Home`, and
`home` for a boid in a tile of this node.
""".
-spec settle(boids_space:space(), boids_boid:boid()) -> home | {away, node()}.
settle(Space, Boid = #{pos := Pos}) ->
    case boids_space:place(Space, Pos, maps:get(perception, Boid, 0)) of
        home ->
            home;
        {border, Nodes} ->
            show(Space, Nodes, Boid),
            home;
        {away, Home, Nodes} ->
            show(Space, [Home | Nodes], Boid),
            {away, Home}
    end.

show(#{name := Name} = Space, Nodes, Boid = #{id := Id}) ->
    {Kind, Pid} = boids_space:owner(Space, Id),
    Entry = (boids_boid:entry(Boid))#{pid => Pid, kind => Kind},
    %% The boid shows its row to the worlds of other nodes. It does not
    %% wait for a node that has no connection.
    lists:foreach(fun(Node) -> erlang:send({Name, Node}, {show, Entry}, [noconnect]) end, Nodes).

-doc """
Find a boid of the world, on this node or on another node: `{Kind, Pid}`
with the kind `server` (a `gen_boid`) or `process`, or `error`.
""".
-spec find(boids_space:space(), term()) -> {server | process, pid()} | error.
find(Space, Id) ->
    case boids_space:owner(Space, Id) of
        {{ghost, Kind}, Pid} ->
            {Kind, Pid};
        {Kind, Pid} ->
            {Kind, Pid};
        error ->
            case {Space, boids_space:nodes(Space) -- [node()]} of
                {#{name := Name}, Nodes = [_ | _]} ->
                    Found = erpc:multicall(Nodes, ?MODULE, find_local, [Name, Id], 5000),
                    case [Owner || {ok, Owner = {_Kind, _Pid}} <- Found] of
                        [Owner | _] -> Owner;
                        [] -> error
                    end;
                _ ->
                    error
            end
    end.

-doc false.
find_local(Name, Id) ->
    case boids_space:owner(space(Name), Id) of
        {Kind, Pid} when is_atom(Kind) -> {Kind, Pid};
        _ -> error
    end.

-doc false.
moved(#{owner := Server}, Id, Pid) ->
    gen_server:call(Server, {moved, Id, Pid}).

-doc false.
adopt(#{owner := Server}, Id, Relations) ->
    gen_server:call(Server, {adopt, Id, Relations}).

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
    %% The tools that show processes show that this process is a
    %% world.
    proc_lib:set_label({boids, world, Name}),
    %% The boids of a world that has too much work run all the
    %% time. The world must answer then too.
    process_flag(priority, high),
    {Relations, Rest} = kind(Opts),
    Links = graph:new([Relations]),
    Space0 = boids_space:new(Rest),
    State = #{sup => Sup, ids => #{}, refs => #{}, links => Links, ghosts => #{}},
    case is_atom(Name) andalso Name =/= undefined of
        true ->
            %% A world with a name is one world on all the nodes that
            %% have a world with that name and the same options.
            Space = Space0#{name => Name},
            Group = {Name, erlang:phash2(maps:with([cell_size, bounds, wrap, tile], Space))},
            {_Ref, _Members} = pg:monitor(boids, Group),
            ok = pg:join(boids, Group, self()),
            erlang:send_after(?GHOST_MS div 2, self(), sweep),
            {ok, members(State#{space => Space, group => Group})};
        false ->
            {ok, State#{space => Space0, group => undefined}}
    end.

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
handle_call({relate, From, Label, To, Found}, _From, State = #{space := Space, links := Links0}) ->
    %% The relation is on the node of the boid that has it. The caller
    %% found the other boid, on this node or on another node.
    Missing =
        [From || not is_atom(element(1, owner(Space, From)))] ++
            [To || not Found, boids_space:lookup(Space, To) =:= error],
    case Missing of
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
handle_call({adopt, Id, Relations}, _From, State = #{space := Space, links := Links0}) ->
    %% The relations of a boid that came from another node.
    Links = lists:foldl(
        fun({Label, Others}, Acc0) ->
            Acc = lists:foldl(
                fun(To, G) -> graph:add_edge(graph:add_vertex(graph:add_vertex(G, Id), To), Id, To, Label) end,
                Acc0,
                Others
            ),
            publish(Space, Acc, [Id | Others], Label),
            Acc
        end,
        Links0,
        Relations
    ),
    {reply, ok, State#{links := Links}};
handle_call({moved, Id, Pid}, _From, State0 = #{space := Space, links := Links0}) ->
    %% The boid is on another node now. Its relations went with it. The
    %% relations of the boids of this node to it stay.
    case boids_space:lookup(Space, Id) of
        {ok, #{pid := Pid}} ->
            Out = [Edge || graph:has_vertex(Links0, Id), Edge <- graph:out_edges(Links0, Id)],
            Links = graph:del_edges(Links0, Out),
            [publish(Space, Links, [From, To], Label) || {From, To, Label} <- Out],
            {reply, ok, forget_row(Id, State0#{links := Links})};
        _ ->
            {reply, ok, State0}
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
handle_info({show, Entry = #{id := Id}}, State = #{space := Space, ghosts := Ghosts}) ->
    %% A boid of another node shows itself near a border.
    case boids_space:show(Space, Entry) of
        true -> {noreply, State#{ghosts := Ghosts#{Id => erlang:monotonic_time(millisecond)}}};
        false -> {noreply, State}
    end;
handle_info(sweep, State = #{space := Space, ghosts := Ghosts}) ->
    erlang:send_after(?GHOST_MS div 2, self(), sweep),
    Old = erlang:monotonic_time(millisecond) - ?GHOST_MS,
    Gone = [Id || Id := Time <- Ghosts, Time < Old],
    lists:foreach(fun(Id) -> boids_space:remove(Space, Id) end, Gone),
    {noreply, State#{ghosts := maps:without(Gone, Ghosts)}};
handle_info({_Ref, Change, _Group, _Pids}, State) when Change =:= join; Change =:= leave ->
    %% A node has a world with the name of this world now, or has it no
    %% more.
    {noreply, members(State)};
handle_info(_Message, State) ->
    {noreply, State}.

%% The nodes of the world, for the boids of this node. The rows of the
%% boids of a node that went go at the next sweep.
members(State = #{space := Space, group := Group}) ->
    boids_space:set_nodes(Space, [node() | [node(Pid) || Pid <- pg:get_members(boids, Group)]]),
    State.

owner(Space, Id) ->
    case boids_space:owner(Space, Id) of
        error -> {{none, none}, undefined};
        Owner -> Owner
    end.

%% A boid that starts again with its id can come before the message
%% 'DOWN' of its last process (specs/Members.tla, TakeOver).
forget_dead(Id, State = #{space := Space, ghosts := Ghosts}) ->
    case boids_space:owner(Space, Id) of
        {{ghost, _}, _Pid} ->
            %% A boid that shows itself here from another node comes to
            %% this node: its row becomes the row of its new process.
            boids_space:remove(Space, Id),
            State#{ghosts := maps:remove(Id, Ghosts)};
        {_Kind, Pid} when node(Pid) =:= node() ->
            case is_process_alive(Pid) of
                true -> State;
                false -> forget(Id, State)
            end;
        _ ->
            State
    end.

forget(Id, State) ->
    forget_row(Id, unrelate(Id, State)).

forget_row(Id, State = #{space := Space, ids := Ids, refs := Refs}) ->
    boids_space:remove(Space, Id),
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
