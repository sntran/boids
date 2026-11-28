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

The facts of the world are what all its boids perceive, and that is not
a boid: the obstacles and the scale of the time. Only this process
writes them (`set/3`), one change after the other, and the boids read
them with no message. A write of an obstacle changes more than one row
of a table, and two processes that write at the same time can lose a
part of it (`specs/Space.tla`).

## The facts of a world on several nodes

All the nodes of a world have the same facts (`specs/Facts.tla`).

- Each change of a fact has a version: `{Counter, Node}`. The counter is
  larger than each counter that the node knows. It is the time of the
  system in microseconds, or the largest counter that the node knows
  plus 1 when that is more. A node takes a change only when its version
  is larger than the version that the node has for that key: the
  counter first, then the name of the node.
- Thus all the nodes get the same value, also when the clocks of the
  computers do not agree. When the clocks agree, the change that was
  the last in time wins: after a split, the side that made more changes
  does not win for that reason, and a world that starts again with no
  fact makes changes that are after the older facts of the other nodes.
- The process that changes a fact writes it on its node, and sends the
  change to the worlds of the other nodes. It does not wait for them.
  Each of them answers to the process that asked for the change
  (`set/3`), which waits for these answers.
- A fact that is removed stays as a mark, with its version, so that an
  older change cannot bring it back. A node drops a mark after some time
  (`boids:mark_time/0`), or never when that time is `infinity`.
- A node that comes to the world, and a node that has a connection
  again after a split of the network, gets all the facts and the marks
  of each other node, and gives its own. After that, all the nodes have
  the same value for each key.
- The code has no part for one kind of fact, except `write/3`. A node
  that cannot write a fact of another node (its value is bad for this
  node) writes an error to its log, and keeps the fact for the other
  nodes.

## A world on several nodes

A world with a name that is an atom is one world on all the connected
nodes that have a world with that name and the same options. The
processes of these worlds are in one group (`pg`, the scope `boids`),
and each of them keeps the list of the nodes for the boids of its node
(`boids_space:nodes/1`).

- A boid near a border of its node sends its row to the process of the
  world of the other node (`settle/2`). That process writes it to its
  tables, and removes a row that gets no update for half a second.
- A boid that comes from another node joins with the number of its
  moves. It takes the row that showed it. It also takes the row of a
  `gen_boid` of this node with its id that made fewer moves, which
  stops: when the connection ends during a move, a node can have an old
  process of the boid (`specs/Move.tla`).
- After a split of the network, a boid can have a process on two nodes.
  When the nodes join again, each world tells the other its boids. For
  a boid with two processes, the world of the node with the smaller
  name decides which process stays: the one with more moves, then the
  one of the node with the larger name. Only one world decides, and the
  moves and the node of a process do not change: two decisions for the
  same two processes are the same decision, so the two processes cannot
  stop for each other (`specs/MoveMany.tla`).
- A world that starts a process for a boid that comes from another node
  tells the other nodes. Thus two processes of one boid on nodes that
  always had a connection are found too.
- Only a `gen_boid` of the world moves, and only such a boid is in
  these decisions. A `gen_boid` below a supervisor of yours has no part
  in them.
- A world with the same name and other options on another node does
  not join this world. This process writes one error to the log for
  such a node.
- `find/2` finds a boid on this node or on the other nodes.

Use the functions of `boids`. A world starts with
`boids:start_world/1`, or as a child of your supervisor with
`boids:child_spec/1`.
""".
-behavior(gen_server).

-export([start_link/2, options/1, space/1, sup/1, boid_sup/1, join/3, leave/3]).
-export([relate/5, unrelate/4, relations/1, set/3, facts/1]).
-export([settle/2, settle/3, find/2, find_local/2, moved/3, adopt/5]).

%% A row of a boid of another node that gets no update in this time goes.
-define(GHOST_MS, 500).

%% The time after a world with the name of this world came, before the
%% check of its options: the two groups of that world come one after the
%% other.
-define(OPTIONS_MS, 500).
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
Add the relation `Label` from the boid `From` to the boid `To`. `From`
is a boid of this node: a relation is on the node of the boid that has
it. With `Found`, the caller found the boid `To` on this node or on
another node (`find/2`). Without it, `To` must have a row on this node.

The result is `{error, {not_found, Id}}` for an id that is not there,
and `{error, cycle}` when the world has the option `relations =>
acyclic` and the relation makes a cycle with the relations of this
node.
""".
-spec relate(boids_space:space(), term(), term(), term(), boolean()) -> ok | {error, {not_found, term()} | cycle}.
relate(#{owner := Server}, From, Label, To, Found) ->
    gen_server:call(Server, {relate, From, Label, To, Found}).

-doc """
Remove the relation `Label` from the boid `From` to the boid `To`, on
this node.
""".
-spec unrelate(boids_space:space(), term(), term(), term()) -> ok.
unrelate(#{owner := Server}, From, Label, To) ->
    gen_server:call(Server, {unrelate, From, Label, To}).

-doc """
Change a fact of the world, on all its nodes. A fact is what all the
boids of the world perceive, and that is not a boid:

| Key | Value |
|---|---|
| `time_scale` | The scale of the time: a number from 0 to 1.0e100. |
| `{obstacle, Id}` | An obstacle: `{Pos, Radius}`, or `none` to remove it. |

Only the process of the world writes the facts of its node, one change
after the other, to tables that only it can write. The boids read them
with no message (`boids_space:env/3`). The result is `{error, badarg}`
for a key that is not a fact, or for a bad value: the world does not
change.

The process of the world of this node sends the change to the worlds
of the other nodes, and this function waits for their answers. Thus,
when the result is `ok`, each node that has a connection to this node
has the change. A node with no connection gets the change when it has a
connection again. With no answer of a node in the time limit
(`boids:timeout/0`), the result is `{error, timeout}`: this node has
the change, and the node that is slow gets it later.

`boids:set_time_scale/2`, `boids:set_obstacle/4` and
`boids:remove_obstacle/2` use this function.
""".
-spec set(server() | boids_space:space(), time_scale | {obstacle, term()}, term()) ->
    ok | {error, badarg | timeout}.
set(#{owner := Server}, Key, Value) ->
    set(Server, Key, Value);
set(Server, Key, Value) ->
    %% The worlds of the other nodes answer to this alias, which stays
    %% until unalias/1.
    Ack = alias([]),
    try gen_server:call(Server, {set, Key, Value, Ack}) of
        {ok, Peers} ->
            Deadline = erlang:monotonic_time(millisecond) + boids:timeout(),
            await(Ack, #{Pid => monitor(process, Pid) || Pid <- Peers}, Deadline);
        Error ->
            Error
    after
        unalias(Ack)
    end.

%% Wait for the answer of the world of each other node. A world that
%% stopped, or that has no connection now, gives no answer: it gets the
%% facts of this node when it comes again.
await(_Ack, Waiting, _Deadline) when map_size(Waiting) =:= 0 ->
    ok;
await(Ack, Waiting, Deadline) ->
    receive
        {Ack, Pid} when is_map_key(Pid, Waiting) ->
            demonitor(map_get(Pid, Waiting), [flush]),
            await(Ack, maps:remove(Pid, Waiting), Deadline);
        {'DOWN', Ref, process, Pid, _Reason} when map_get(Pid, Waiting) =:= Ref ->
            await(Ack, maps:remove(Pid, Waiting), Deadline)
    after max(0, Deadline - erlang:monotonic_time(millisecond)) ->
        %% An answer that comes after this moment goes nowhere.
        unalias(Ack),
        maps:foreach(fun(Pid, Ref) -> demonitor(Ref, [flush]), late(Ack, Pid) end, Waiting),
        {error, timeout}
    end.

%% Remove an answer that came at the moment of the time limit, so that it
%% does not stay in the messages of the caller.
late(Ack, Pid) -> receive {Ack, Pid} -> ok after 0 -> ok end.

-doc """
The facts of the world on this node, with their versions, in the order
of their keys: a list of `{Key, Value, Version}`. The value `none` is
the mark of a fact that was removed. A fact that never changed (the
scale of the time of a new world) is not in the list.
""".
-spec facts(server() | boids_space:space()) -> [{term(), term(), {pos_integer(), node()}}].
facts(#{owner := Server}) ->
    facts(Server);
facts(Server) ->
    gen_server:call(Server, facts).

-doc """
Show a boid that wrote its row to the other nodes that it is near. The
result is `{away, Home}` for a boid in a tile of the node `Home`, and
`home` for a boid in a tile of this node.
""".
-spec settle(boids_space:space(), boids_boid:boid()) -> home | {away, node()}.
settle(Space, Boid) ->
    settle(Space, Boid, none).

-doc """
As `settle/2`, for a `gen_boid` that made `Moves` moves from node to
node before this process. `none` is for a boid that does not move from
node to node.
""".
-spec settle(boids_space:space(), boids_boid:boid(), non_neg_integer() | none) -> home | {away, node()}.
settle(Space, Boid = #{pos := Pos}, Moves) ->
    case boids_space:place(Space, Pos, maps:get(perception, Boid, 0)) of
        home ->
            home;
        {border, Nodes} ->
            show(Space, Nodes, Boid, Moves),
            home;
        {away, Home, Nodes} ->
            show(Space, [Home | Nodes], Boid, Moves),
            {away, Home}
    end.

show(#{name := Name} = Space, Nodes, Boid = #{id := Id}, Moves) ->
    case boids_space:owner(Space, Id) of
        {Kind, Pid} when is_atom(Kind) ->
            Entry = (boids_boid:entry(Boid))#{pid => Pid, kind => Kind, moves => Moves},
            %% The boid shows its row to the worlds of other nodes. It
            %% does not wait for a node that has no connection.
            lists:foreach(fun(Node) -> erlang:send({Name, Node}, {show, Entry}, [noconnect]) end, Nodes);
        _ ->
            %% Only a boid of this node shows itself.
            ok
    end.

-doc """
Find a boid of the world, on this node or on another node: `{Kind, Pid}`
with the kind `server` (a `gen_boid`) or `process`, or `error`. The
result is `timeout` when no node has the boid and a node gave no answer
in the time limit (`boids:timeout/0`).
""".
-spec find(boids_space:space(), term()) -> {server | process, pid()} | error | timeout.
find(Space, Id) ->
    case boids_space:owner(Space, Id) of
        {{ghost, Kind}, Pid} ->
            {Kind, Pid};
        {Kind, Pid} ->
            {Kind, Pid};
        error ->
            case {Space, boids_space:nodes(Space) -- [node()]} of
                {#{name := Name}, Nodes = [_ | _]} ->
                    Found = erpc:multicall(Nodes, ?MODULE, find_local, [Name, Id], boids:timeout()),
                    Late = lists:member({error, {erpc, timeout}}, Found),
                    case [Owner || {ok, Owner = {_Kind, _Pid}} <- Found] of
                        [Owner | _] -> Owner;
                        %% A node gave no answer in the time limit: the
                        %% boid can be there.
                        [] when Late -> timeout;
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
adopt(#{owner := Server}, Id, Relations, Moves, Caller) ->
    gen_server:call(Server, {adopt, Id, Relations, Moves, Caller}).

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
    State0 = #{sup => Sup, ids => #{}, refs => #{}, ages => #{}, links => Links, ghosts => #{}, warned => []},
    %% The facts of the world with their versions: Key => {Version,
    %% Value}, where the value none is the mark of a removed fact. The
    %% clock is the largest counter of a version that this node knows.
    %% The marks are in the order of their time: {Time, Key, Version}.
    %% The peers are the processes of this world on the other nodes.
    State = State0#{facts => #{}, clock => 0, marks => queue:new(), peers => []},
    case is_atom(Name) andalso Name =/= undefined of
        true ->
            %% A world with a name is one world on all the nodes that
            %% have a world with that name and the same options.
            Space = Space0#{name => Name},
            Group = {Name, erlang:phash2(maps:with([cell_size, bounds, wrap, tile], Space))},
            %% The worlds that are in the group now get the event of
            %% the join of this world: they give their facts.
            {_Ref, Members} = pg:monitor(boids, Group),
            Peers = [Pid || Pid <- Members, node(Pid) =/= node()],
            ok = pg:join(boids, Group, self()),
            %% The group of all the worlds with the name, with each
            %% options: a world of that group that is not in the first
            %% group has other options.
            Names = {names, Name},
            {_Other, _All} = pg:monitor(boids, Names),
            ok = pg:join(boids, Names, self()),
            erlang:send_after(?OPTIONS_MS, self(), options),
            erlang:send_after(?GHOST_MS div 2, self(), sweep),
            {ok, members(State#{space => Space, group => Group, names => Names, peers := Peers})};
        false ->
            {ok, State#{space => Space0, group => undefined, names => undefined}}
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
    %% The moves of the boid before this process: 0 for a new boid, and
    %% none for a boid that does not move from node to node.
    Moves = maps:get(moves, Entry, none),
    State = #{ids := Ids, refs := Refs, ages := Ages} = forget_dead(Id, Moves, State0),
    case boids_space:fit(Space, Pos) of
        true ->
            case boids_space:insert_new(Space, Entry#{pid => Pid}) of
                true ->
                    Ref = monitor(process, Pid),
                    Roams =
                        case Moves of
                            none -> Ages;
                            _ -> Ages#{Id => Moves}
                        end,
                    Joined = State#{ids := Ids#{Id => Ref}, refs := Refs#{Ref => Id}, ages := Roams},
                    {reply, ok, Joined};
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
handle_call({adopt, Id, Relations, Moves, Caller}, _From, State = #{space := Space, links := Links0}) ->
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
    arrive(Id, Moves, Caller, State),
    {reply, ok, State#{links := Links}};
handle_call({moved, Id, Pid}, _From, State = #{space := Space}) ->
    %% The boid is on another node now.
    case boids_space:lookup(Space, Id) of
        {ok, #{pid := Pid}} -> {reply, ok, depart(Id, State)};
        _ -> {reply, ok, State}
    end;
handle_call({unrelate, From, Label, To}, _From, State = #{space := Space, links := Links0}) ->
    Links = graph:del_edge(Links0, {From, To, Label}),
    publish(Space, Links, [From, To], Label),
    {reply, ok, State#{links := Links}};
handle_call(relations, _From, State = #{links := Links}) ->
    {reply, Links, State};
handle_call({set, Key, Value, Ack}, _From, State0 = #{space := Space, clock := Clock}) ->
    %% A bad value of a caller must not stop the world: each write
    %% checks its value before it changes a table.
    try write(Space, Key, Value) of
        ok ->
            %% The change is after each change that this node knows
            %% (specs/Facts.tla, Change). Its counter is the time of
            %% the system when that is larger: with clocks that agree,
            %% the last change in time has the largest counter, also
            %% for a node that did not see the other changes.
            Counter = max(Clock + 1, erlang:system_time(microsecond)),
            Fact = {Key, Value, {Counter, node()}},
            State = #{peers := Peers} = keep(Fact, State0),
            %% This process tells the other nodes, so a caller that
            %% stops in the middle changes nothing. It does not wait for
            %% them: they answer to the caller. A node with no connection
            %% gets the fact when it comes again.
            Sent = [Pid || Pid <- Peers, erlang:send(Pid, {fact, Fact, Ack}, [noconnect]) =:= ok],
            {reply, {ok, Sent}, State}
    catch
        error:badarg -> {reply, {error, badarg}, State0}
    end;
handle_call(facts, _From, State = #{facts := Facts}) ->
    {reply, [{Key, Value, Version} || Key := {Version, Value} <- maps:iterator(Facts, ordered)], State};
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
    case {boids_space:show(Space, Entry), Entry} of
        {true, _} ->
            {noreply, State#{ghosts := Ghosts#{Id => erlang:monotonic_time(millisecond)}}};
        {false, #{kind := server, pid := Pid, moves := Moves}} when is_integer(Moves) ->
            %% This node has a boid with that id: the boid can have two
            %% processes.
            {noreply, claim(Id, node(Pid), Moves, State)};
        {false, _} ->
            {noreply, State}
    end;
handle_info({fact, Fact, Ack}, State) ->
    %% A change of a fact on another node. The process that asked for
    %% the change waits for this answer.
    Learned = learn(Fact, State),
    _ = erlang:send(Ack, {Ack, self()}, [noconnect]),
    {noreply, Learned};
handle_info({facts, Facts}, State) ->
    %% All the facts of a node that has a connection to this node now: a
    %% new node, or a node after a split of the network.
    {noreply, lists:foldl(fun learn/2, State, Facts)};
handle_info({census, Node, Claims}, State0) ->
    %% The boids of a node that joined the world, after a split of the
    %% network or at its start.
    {noreply, lists:foldl(fun({Id, Moves}, State) -> claim(Id, Node, Moves, State) end, State0, Claims)};
handle_info({claim, Id, Node, Moves}, State) ->
    {noreply, claim(Id, Node, Moves, State)};
handle_info({claim, Id, Node, Moves, Caller}, State = #{space := Space}) ->
    %% A node started a process for the boid, for the call of the
    %% process `Caller`. When that process is the process of this node,
    %% it waits for the answer of its call, and it stops with that
    %% answer: this world does nothing.
    case boids_space:owner(Space, Id) of
        {server, Caller} -> {noreply, State};
        _ -> {noreply, claim(Id, Node, Moves, State)}
    end;
handle_info({yield, Id, Moves}, State = #{space := Space, ages := Ages}) ->
    %% The world that decides tells that the process of this node, with
    %% this number of moves, stops. A process that came after the
    %% decision has another number of moves, and stays (specs/Move.tla,
    %% Yield).
    case {boids_space:owner(Space, Id), Ages} of
        {{server, Pid}, #{Id := Moves}} ->
            exit(Pid, {shutdown, replaced}),
            {noreply, depart(Id, State)};
        _ ->
            {noreply, State}
    end;
handle_info(options, State = #{space := #{name := Name}, group := Group, names := Names, warned := Warned}) ->
    %% The worlds with the name of this world and other options.
    Same = [node(Pid) || Pid <- pg:get_members(boids, Group)],
    Others = lists:usort([node(Pid) || Pid <- pg:get_members(boids, Names)]) -- Same,
    lists:foreach(
        fun(Node) ->
            logger:error(
                "The world ~0tp of the node ~0tp has other options than the world ~0tp of this node: "
                "the two worlds do not join",
                [Name, Node, Name],
                #{domain => [boids]}
            )
        end,
        Others -- Warned
    ),
    {noreply, State#{warned := Others}};
handle_info(sweep, State = #{space := Space, ghosts := Ghosts}) ->
    erlang:send_after(?GHOST_MS div 2, self(), sweep),
    Old = erlang:monotonic_time(millisecond) - ?GHOST_MS,
    Gone = [Id || Id := Time <- Ghosts, Time < Old],
    lists:foreach(fun(Id) -> boids_space:remove(Space, Id) end, Gone),
    {noreply, drop_marks(boids:mark_time(), State#{ghosts := maps:without(Gone, Ghosts)})};
handle_info({_Ref, join, Group, Pids}, State = #{group := Group, peers := Peers, facts := Facts}) ->
    %% A node has a world with the name and the options of this world
    %% now: a new node, or a node that had no connection for some time.
    %% That world gets the boids of this node, to find the boids that
    %% have a process on the two nodes.
    Others = [Pid || Pid <- Pids, node(Pid) =/= node()],
    Claims = claims(State),
    [Pid ! {census, node(), Claims} || Pid <- Others, Claims =/= []],
    %% It also gets all the facts of this node, with their versions and
    %% the marks. From this moment, it gets each change of this node
    %% (specs/Facts.tla, Join).
    Known = [{Key, Value, Version} || Key := {Version, Value} <- Facts],
    [Pid ! {facts, Known} || Pid <- Others, Known =/= []],
    {noreply, members(State#{peers := lists:usort(Others ++ Peers)})};
handle_info({_Ref, join, Names, _Pids}, State = #{names := Names}) ->
    erlang:send_after(?OPTIONS_MS, self(), options),
    {noreply, State};
handle_info({_Ref, leave, Group, Pids}, State = #{group := Group, peers := Peers}) ->
    %% A node has the world no more, or it has no connection.
    {noreply, members(State#{peers := Peers -- Pids})};
handle_info({_Ref, leave, _Names, _Pids}, State) ->
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

%% The boids of this node that move from node to node, each with its
%% moves.
claims(#{space := Space, ages := Ages}) ->
    [{Id, Moves} || Id := Moves <- Ages, {server, _Pid} <- [boids_space:owner(Space, Id)]].

%% A boid came to this node: the process `Caller` of another node
%% called. This world tells the other nodes: a node that has a process
%% of the boid too is found, also when the two nodes always had a
%% connection (specs/MoveMany.tla, Adopt).
arrive(Id, Moves, Caller, #{space := Space}) ->
    %% Only a world with a name has other nodes.
    Tell = fun(Node) -> erlang:send({maps:get(name, Space), Node}, {claim, Id, node(), Moves, Caller}, [noconnect]) end,
    lists:foreach(Tell, boids_space:nodes(Space) -- [node()]).

%% The node `Node` has a process of the boid `Id`, with a number of
%% moves. When this node has one too, the boid has two processes, and
%% one of them stops. The world of the node with the smaller name
%% decides: with one world that decides, the two processes cannot stop
%% for each other. The process with more moves stays, then the process
%% of the node with the larger name. The moves and the node of a process
%% do not change, so a second decision for the same two processes is the
%% same decision (specs/MoveMany.tla, Claim).
claim(Id, Node, Moves, State = #{space := Space = #{name := Name}, ages := Ages}) ->
    case {boids_space:owner(Space, Id), Ages} of
        {{server, Pid}, #{Id := Own}} when Node =/= node() ->
            case {node() < Node, {Own, node()} < {Moves, Node}} of
                {true, true} ->
                    exit(Pid, {shutdown, replaced}),
                    depart(Id, State);
                {true, false} ->
                    erlang:send({Name, Node}, {yield, Id, Moves}, [noconnect]),
                    State;
                {false, _} ->
                    erlang:send({Name, Node}, {claim, Id, node(), Own}, [noconnect]),
                    State
            end;
        _ ->
            State
    end.

%% A boid of this node is on another node now. Its relations are with
%% it. The relations of the boids of this node to it stay.
depart(Id, State = #{space := Space, links := Links0}) ->
    Out = [Edge || graph:has_vertex(Links0, Id), Edge <- graph:out_edges(Links0, Id)],
    Links = graph:del_edges(Links0, Out),
    [publish(Space, Links, [From, To], Label) || {From, To, Label} <- Out],
    forget_row(Id, State#{links := Links}).

%% A boid that starts again with its id can come before the message
%% 'DOWN' of its last process (specs/Members.tla, TakeOver).
forget_dead(Id, Moves, State = #{space := Space, ghosts := Ghosts, ages := Ages}) ->
    case boids_space:owner(Space, Id) of
        {{ghost, _}, _Pid} ->
            %% A boid that shows itself here from another node comes to
            %% this node: its row becomes the row of its new process.
            boids_space:remove(Space, Id),
            State#{ghosts := maps:remove(Id, Ghosts)};
        {Kind, Pid} when node(Pid) =:= node() ->
            case is_process_alive(Pid) of
                true when Kind =:= server, is_integer(Moves), Moves > map_get(Id, Ages) ->
                    %% The process that comes made more moves than the
                    %% process of this node: after a lost answer of a
                    %% move, this node has an old process of the boid.
                    %% The new process takes its place, so that two
                    %% processes cannot stop for each other
                    %% (specs/Move.tla, Adopt). The relations stay.
                    exit(Pid, {shutdown, replaced}),
                    forget_row(Id, State);
                true ->
                    State;
                false ->
                    forget(Id, State)
            end;
        _ ->
            State
    end.

forget(Id, State) ->
    forget_row(Id, unrelate(Id, State)).

forget_row(Id, State = #{space := Space, ids := Ids, refs := Refs, ages := Ages}) ->
    boids_space:remove(Space, Id),
    case Ids of
        #{Id := Ref} ->
            demonitor(Ref, [flush]),
            State#{ids := maps:remove(Id, Ids), refs := maps:remove(Ref, Refs), ages := maps:remove(Id, Ages)};
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

%% Write a fact of the world to the tables of this node. Each change of
%% a fact comes here, and to no other place: a new kind of fact is a new
%% clause. The value none removes the fact. A bad value gives the error
%% badarg, with no change.
write(Space, time_scale, Scale) -> boids_space:set_time_scale(Space, Scale);
write(Space, {obstacle, Id}, none) -> boids_space:remove_obstacle(Space, Id);
write(Space, {obstacle, Id}, {Pos, Radius}) -> boids_space:set_obstacle(Space, Id, Pos, Radius);
write(_Space, _Key, _Value) -> error(badarg).

%% A fact of another node, with its version. This node takes the fact
%% only when the version is larger than the version that it has for the
%% key: the counter first, then the name of the node. So the nodes come
%% to the same facts in each order of the messages (specs/Facts.tla,
%% Learn).
learn(Fact = {Key, Value, Version = {Counter, Node}}, State0 = #{space := Space, facts := Facts, clock := Clock}) ->
    %% The next change of this node is after this change.
    State = State0#{clock := max(Clock, Counter)},
    case Facts of
        #{Key := {Have, _Value}} when Version =< Have ->
            State;
        _ ->
            try
                write(Space, Key, Value)
            catch
                error:badarg ->
                    %% The fact is good for its node, and not for this
                    %% node: for example, a kind of fact that this
                    %% version of the library does not know.
                    logger:error(
                        "The world ~0tp of this node cannot write the fact ~0tP of the node ~0tp: "
                        "it keeps the fact for the other nodes",
                        [maps:get(name, Space, undefined), Key, 8, Node],
                        #{domain => [boids]}
                    )
            end,
            keep(Fact, State)
    end.

%% Keep a fact with its version. A fact that is removed stays as a mark:
%% an older change that comes later does not bring it back. A world on
%% one node only (a world with no name) has no use for a mark.
keep({Key, none, {Counter, _Node}}, State = #{group := undefined, facts := Facts, clock := Clock}) ->
    State#{facts := maps:remove(Key, Facts), clock := max(Clock, Counter)};
keep({Key, Value, Version = {Counter, _Node}}, State = #{facts := Facts, clock := Clock, marks := Marks}) ->
    Kept = State#{facts := Facts#{Key => {Version, Value}}, clock := max(Clock, Counter)},
    case Value of
        none -> Kept#{marks := queue:in({erlang:monotonic_time(millisecond), Key, Version}, Marks)};
        _ -> Kept
    end.

%% Drop the marks that this node got more than `Time` milliseconds ago.
%% With the time infinity, the node keeps each mark.
drop_marks(infinity, State) ->
    State;
drop_marks(Time, State) ->
    drop_before(erlang:monotonic_time(millisecond) - Time, State).

%% Drop the marks that this node got before the time `Old`. A key that
%% has another fact now keeps that fact.
drop_before(Old, State = #{marks := Marks, facts := Facts}) ->
    case queue:peek(Marks) of
        {value, {Time, Key, Version}} when Time < Old ->
            Rest = State#{marks := queue:drop(Marks)},
            case Facts of
                #{Key := {Version, none}} -> drop_before(Old, Rest#{facts := maps:remove(Key, Facts)});
                _ -> drop_before(Old, Rest)
            end;
        _ ->
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
