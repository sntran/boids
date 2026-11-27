-module(boids_space).
-moduledoc """
The space of a world: the ETS tables that tell where each boid
is.

Each boid has one row with its position and its velocity. A grid of
cells is the index of the rows, so a boid finds its neighbors with no
message and with no read of all the rows. The tables are public: each
process writes its own row, and all the processes read all the rows at
the same time.

A space is a map. Its process (the owner of the tables) makes it with
`new/1`, and other processes get a copy of it. The process of a
world (`boids_world`) is the owner for
`boids:start_world/1`, but a space also works alone, in one
process.

With `wrap`, each side of the box `bounds` continues at the opposite
side. Then `near/3` gives each neighbor at its nearest position, which
can be out of the box.

## The obstacles

An obstacle has one row, and a second grid of cells is the index of the
obstacles: an obstacle is in each cell that it touches, and in each
coarse cell (8 cells long on each side) that it touches. A boid gets
only the obstacles near it (`obstacles/3`), with a read of the coarse
cells near it, and of the cells near it when the coarse cells have many
obstacles. An obstacle that touches more than 1,024 cells is not in the
cells: each read gets it, as a large obstacle.

Only the owner of the space writes the obstacles and the scale of the
time: their tables are protected. In a world, the owner is the process
of the world, and each change is a message to it
(`boids_world:set/3`). Each process reads them with no message.

A write of an obstacle changes more than one row, and it changes a
version at its start and at its end. A read that sees a write during
the read reads the rows of all the obstacles again (specs/Space.tla,
Check). So a read finds an obstacle that moves one time: not two times,
and not zero times.

## Tiles and nodes

A world can be on several nodes. The tables of a space are of one node.
A space is cut into tiles (the option `tile`), and each tile is on one
node of the world (`home/2`). The space of a node has the rows of the
boids of that node. It also has rows of boids of other nodes that are
near a border (`show/2`): `near/3` and `lookup/2` give them, and
`all/1` and `count/1` do not.
""".

-export([new/1, options/1, delete/1]).
-export([insert_new/2, put/2, remove/2]).
-export([lookup/2, owner/2, servers/1, near/3, seen/4, all/1, count/1, dim/1, fit/2, offset/3]).
-export([relate/4, related/3, related_to/3, relations/2]).
-export([show/2, nodes/1, set_nodes/2, home/2, place/3]).
-export([env/1, env/3, obstacles/1, obstacles/3, set_obstacle/4, remove_obstacle/2, set_time_scale/2]).

-export_type([space/0, entry/0, neighbor/0, obstacle/0, env/0, kind/0]).

-type vec() :: boids_vec:vec().
-type space() :: #{
    rows := ets:table(),
    grid := ets:table(),
    meta := ets:table(),
    owner := pid(),
    cell_size := number(),
    bounds := {vec(), vec()} | undefined,
    wrap := boolean(),
    links := ets:table(),
    facts := ets:table(),
    obstacle_cells := ets:table(),
    defaults := map(),
    tile := number(),
    name => atom()
}.
-type kind() :: server | process | {ghost, server | process}.
-type entry() :: #{
    id := term(),
    pos := vec(),
    vel := vec(),
    group => term(),
    data => term(),
    pid => pid() | undefined,
    kind => kind(),
    %% The moves of the boid from node to node before this process, or
    %% none for a boid that does not move from node to node.
    moves => non_neg_integer() | none
}.
-type neighbor() :: #{
    id := term(),
    pos := vec(),
    vel := vec(),
    group := term(),
    data := term(),
    offset := vec(),
    dist := float()
}.
-type obstacle() :: #{id := term(), pos := vec(), radius := number()}.
-type env() :: #{
    bounds := {vec(), vec()} | undefined,
    wrap := boolean(),
    obstacles := [obstacle()],
    time_scale := number()
}.

%% A row: {Id, Pos, Vel, Group, Data, Cell, Pid, Kind, Last}. Kind tells
%% which process has the boid: a gen_boid (server), or another process
%% (process).
%%
%% The grid has a copy of the row in the cell of its position:
%% {Cell, Id, Pos, Vel, Group, Data}. One read of a cell gives all its
%% boids, with no read of their rows.
%%
%% A write changes the row, adds the new copy, then removes the old copy
%% (specs/Space.tla). Last is that old copy, or none: when the process
%% of a boid stops in the middle of a write, the removal of its row
%% finds the two copies.

-doc """
Make a space. The process that calls this function is the owner of the
tables.

The options:

- `cell_size`: the side of a cell of the grid (default: 10.0). The best
  value is near the distance that a boid sees.
- `bounds`: `{Min, Max}`, the box of the space (default: `undefined`).
- `wrap`: `true` when each side of the box continues at the opposite
  side (default: `false`). It needs `bounds`.
- `defaults`: options for each boid of the space (default: `#{}`).

A bad option gives the error `{bad_option, {Key, Value}}`.
""".
-spec new(map()) -> space().
new(Opts) ->
    Space = options(Opts),
    Rows = ets:new(boids_rows, [set, public, {read_concurrency, true}, {write_concurrency, true}]),
    Grid = ets:new(boids_grid, [duplicate_bag, public, {read_concurrency, true}, {write_concurrency, true}]),
    %% The table has the size of the vectors of the first boid, and the
    %% nodes that have a part of the world: one node, until the world of
    %% this node finds the same world on other nodes.
    Meta = ets:new(boids_meta, [set, public, {read_concurrency, true}]),
    ets:insert(Meta, {nodes, [node()]}),
    %% The facts of the world, which only the owner writes: the scale of
    %% the time, one row for each obstacle ({{obstacle, Id}, Pos,
    %% Radius}), and the version of the obstacles.
    Facts = ets:new(boids_facts, [set, protected, {read_concurrency, true}]),
    ets:insert(Facts, [{time_scale, 1.0}, {obstacle_version, 0}]),
    %% The index of the obstacles: {Cell, Id} for each cell that an
    %% obstacle touches, {{coarse, Cell}, Id} for each coarse cell, and
    %% {large, Id} for a large obstacle. Only the owner writes it.
    Cells = ets:new(boids_obstacle_cells, [bag, protected, {read_concurrency, true}]),
    %% The relations between the boids, for the reads of the boids:
    %% {{out, From, Label}, [To]} and {{in, To, Label}, [From]}. Only
    %% the owner writes them.
    Links = ets:new(boids_links, [set, protected, {read_concurrency, true}]),
    Space#{
        rows => Rows,
        grid => Grid,
        meta => Meta,
        links => Links,
        facts => Facts,
        obstacle_cells => Cells,
        owner => self()
    }.

-doc """
Check the options of a space, and give them with their defaults. A bad
option gives the error `{bad_option, {Key, Value}}`.
""".
-spec options(map()) -> map().
options(Opts) when is_map(Opts) ->
    maps:foreach(fun check/2, Opts),
    case maps:merge(#{cell_size => 10.0, bounds => undefined, wrap => false, defaults => #{}}, Opts) of
        #{wrap := true, bounds := undefined} -> error({bad_option, {wrap, true}});
        %% A tile is large, so that few boids are near a border of it.
        Space = #{cell_size := Size} -> maps:merge(#{tile => 16 * Size}, Space)
    end;
options(Opts) ->
    error({bad_option, Opts}).

check(Key, Value) ->
    ok(Key, Value) orelse error({bad_option, {Key, Value}}).

ok(cell_size, Size) -> boids_vec:is_size(Size) andalso Size > 0;
ok(bounds, undefined) -> true;
ok(bounds, {Min, Max}) -> boids_vec:is_box(Min, Max);
ok(wrap, Wrap) -> is_boolean(Wrap);
ok(defaults, Defaults) -> is_map(Defaults);
ok(tile, Size) -> boids_vec:is_size(Size) andalso Size > 0;
ok(_, _) -> false.

-doc "Delete the tables of a space. Only the owner can do this.".
-spec delete(space()) -> ok.
delete(#{rows := Rows, grid := Grid, meta := Meta, links := Links, facts := Facts, obstacle_cells := Cells}) ->
    ets:delete(Cells),
    ets:delete(Facts),
    ets:delete(Links),
    ets:delete(Rows),
    ets:delete(Grid),
    ets:delete(Meta),
    ok.

-doc """
Add the row of a new boid. The result is `false` when the id is in the
space, or when the position does not have the size of the vectors of the
space (`fit/2`).
""".
-spec insert_new(space(), entry()) -> boolean().
insert_new(Space = #{rows := Rows, grid := Grid}, Entry = #{pos := Pos}) ->
    fit(Space, Pos) andalso
        begin
            Row = row(Space, Entry),
            ets:insert_new(Rows, Row) andalso ets:insert(Grid, spot(Row))
        end.

-doc """
Write the row of a boid that is in the space: its position, its
velocity, its group and its data. The result is `false` when the id is
not in the space. Only the process of the boid calls this function.
""".
-spec put(space(), entry() | boids_boid:boid()) -> boolean().
put(Space = #{rows := Rows, grid := Grid}, #{id := Id, pos := Pos, vel := Vel, group := Group, data := Data}) ->
    case ets:lookup(Rows, Id) of
        [Row = {_, _, _, _, _, _, Pid, Kind, _}] ->
            Old = spot(Row),
            Cell = cell(Space, Pos),
            case {Cell, Id, Pos, Vel, Group, Data} of
                Old ->
                    true;
                New ->
                    %% The new copy comes before the removal of the old
                    %% copy, so a reader always finds the boid in its cell
                    %% (specs/Space.tla, InsertFirst).
                    ets:insert(Rows, {Id, Pos, Vel, Group, Data, Cell, Pid, Kind, Old}),
                    ets:insert(Grid, New),
                    ets:delete_object(Grid, Old)
            end;
        [] ->
            false
    end.

-doc """
Remove the row of a boid. The process of the boid calls this function,
or another process after the end of that process.
""".
-spec remove(space(), term()) -> ok.
remove(#{rows := Rows, grid := Grid}, Id) ->
    case ets:take(Rows, Id) of
        [Row] ->
            %% The process of the boid can stop in the middle of a write:
            %% the grid then has the copy before the write
            %% (specs/Space.tla, RemoveLast).
            ets:delete_object(Grid, spot(Row)),
            Last = element(tuple_size(Row), Row),
            Last =/= none andalso ets:delete_object(Grid, Last);
        [] ->
            true
    end,
    ok.

-doc "The row of a boid.".
-spec lookup(space(), term()) -> {ok, entry()} | error.
lookup(#{rows := Rows}, Id) ->
    case ets:lookup(Rows, Id) of
        [Row] -> {ok, entry(Row)};
        [] -> error
    end.

-doc """
The process that has a boid: `{server, Pid}` for a `gen_boid`, and
`{process, Pid}` for another process.
""".
-spec owner(space(), term()) -> {kind(), pid()} | error.
owner(#{rows := Rows}, Id) ->
    case ets:lookup(Rows, Id) of
        [{_, _, _, _, _, _, Pid, Kind, _}] -> {Kind, Pid};
        [] -> error
    end.

-doc "The processes of the boids whose process is a `gen_boid`.".
-spec servers(space()) -> [pid()].
servers(#{rows := Rows}) ->
    ets:select(Rows, [{{'_', '_', '_', '_', '_', '_', '$1', server, '_'}, [], ['$1']}]).

-doc "All the rows. The order is not specified.".
-spec all(space()) -> [entry()].
all(#{rows := Rows}) ->
    %% A row with a kind that is a tuple is the row of a boid of another
    %% node, which shows itself near a border.
    [entry(Row) || Row <- ets:tab2list(Rows), is_atom(element(8, Row))].

-doc "The number of rows of the boids of this node.".
-spec count(space()) -> non_neg_integer().
count(#{rows := Rows}) ->
    ets:select_count(Rows, [{{'_', '_', '_', '_', '_', '_', '_', '$1', '_'}, [{is_atom, '$1'}], [true]}]).

-doc """
The size of the vectors of the space: that of its box, or that of its
first boid. A space with no box that had no boid has none.
""".
-spec dim(space()) -> 2 | 3 | undefined.
dim(#{bounds := {Min, _Max}}) -> tuple_size(Min);
dim(#{meta := Meta}) -> ets:lookup_element(Meta, dim, 2, undefined).

-doc """
Tell if a position has the size of the vectors of the space. In a space
with no size, the position gives its size to the space.
""".
-spec fit(space(), vec()) -> boolean().
fit(Space = #{meta := Meta}, Pos) ->
    Size = tuple_size(Pos),
    case dim(Space) of
        Size -> true;
        %% Two processes can give the first boid at the same time.
        undefined -> ets:insert_new(Meta, {dim, Size}) orelse dim(Space) =:= Size;
        _ -> false
    end.

-doc """
The boids at the distance `Radius` or less from the point `Pos`, in the
order of their distance. A boid at `Pos` is in the result too.

The boids move during the read. A boid that changes its cell at that
moment can be absent from the result.
""".
-spec near(space(), vec(), number()) -> [neighbor()].
near(Space = #{rows := Rows, grid := Grid}, Pos, Radius) when is_number(Radius), Radius >= 0 ->
    Widths = widths(Space),
    Query = query(Pos, Widths, Radius),
    Found =
        case cells(Space, Pos, Radius) of
            all -> within([spot(Row) || Row <- ets:tab2list(Rows)], Query, []);
            Cells -> lists:foldl(fun(Cell, Acc) -> within(ets:lookup(Grid, Cell), Query, Acc) end, [], Cells)
        end,
    %% A boid that writes its row during the read can have two copies in
    %% the grid: keep one of the two (specs/Space.tla, Dedupe). The keys
    %% of a map are exact, as the keys of the table: 1 and 1.0 are two
    %% ids. Then the nearest comes first.
    One = maps:values(#{element(2, Near) => Near || Near <- Found}),
    [neighbor(Widths, Pos, Near) || Near <- lists:sort(One)].

-doc """
The boids of a list of ids at the distance `Radius` or less from the
point `Pos`, in the order of their distance: as `near/3`, with a read of
the rows of these boids only. A boid that knows its neighbors reads them
with this function, which costs less than a search of the grid. An id
that is not in the space gives nothing.
""".
-spec seen(space(), vec(), number(), [term()]) -> [neighbor()].
seen(Space = #{rows := Rows}, Pos, Radius, Ids) when is_number(Radius), Radius >= 0 ->
    Widths = widths(Space),
    Spots = [spot(Row) || Id <- Ids, Row <- ets:lookup(Rows, Id)],
    [neighbor(Widths, Pos, Near) || Near <- lists:sort(within(Spots, query(Pos, Widths, Radius), []))].

%% The sizes of the box when its sides continue, or none.
widths(#{wrap := true, bounds := {Min, Max}}) -> boids_vec:sub(Max, Min);
widths(_Space) -> none.

%% The numbers of a read, as floats: the calculation with floats only is
%% the fastest. The squares of the distances find most of the boids that
%% are too far, with no square root.
query({X, Y}, none, Radius) ->
    {float(X), float(Y), float(Radius), Radius * Radius * 1.000001};
query({X, Y, Z}, none, Radius) ->
    {float(X), float(Y), float(Z), float(Radius), Radius * Radius * 1.000001};
query({X, Y}, {Wx, Wy}, Radius) ->
    {float(X), float(Y), float(Wx), float(Wy), float(Radius), Radius * Radius * 1.000001};
query({X, Y, Z}, {Wx, Wy, Wz}, Radius) ->
    {float(X), float(Y), float(Z), float(Wx), float(Wy), float(Wz), float(Radius), Radius * Radius * 1.000001}.

%% The boids of a list in the radius, as {Dist, Id, Offset, Pos, Vel,
%% Group, Data}. The offset is that of offset/3.
within(Spots, {X, Y, Radius, Limit}, Acc) -> within2(Spots, X, Y, Radius, Limit, Acc);
within(Spots, {X, Y, Z, Radius, Limit}, Acc) -> within3(Spots, X, Y, Z, Radius, Limit, Acc);
within(Spots, {X, Y, Wx, Wy, Radius, Limit}, Acc) -> wrap2(Spots, X, Y, Wx, Wy, Radius, Limit, Acc);
within(Spots, {X, Y, Z, Wx, Wy, Wz, Radius, Limit}, Acc) -> wrap3(Spots, X, Y, Z, Wx, Wy, Wz, Radius, Limit, Acc).

within2([{_Cell, Id, Other = {Ox, Oy}, Vel, Group, Data} | Rest], X, Y, Radius, Limit, Acc) when
    is_float(X), is_float(Y), is_float(Limit)
->
    Dx = Ox - X,
    Dy = Oy - Y,
    Near = in_radius(Dx * Dx + Dy * Dy, Radius, Limit),
    within2(Rest, X, Y, Radius, Limit, found(Near, Id, {Dx, Dy}, Other, Vel, Group, Data, Acc));
within2([], _X, _Y, _Radius, _Limit, Acc) ->
    Acc.

within3([{_Cell, Id, Other = {Ox, Oy, Oz}, Vel, Group, Data} | Rest], X, Y, Z, Radius, Limit, Acc) when
    is_float(X), is_float(Y), is_float(Z), is_float(Limit)
->
    Dx = Ox - X,
    Dy = Oy - Y,
    Dz = Oz - Z,
    Near = in_radius(Dx * Dx + Dy * Dy + Dz * Dz, Radius, Limit),
    within3(Rest, X, Y, Z, Radius, Limit, found(Near, Id, {Dx, Dy, Dz}, Other, Vel, Group, Data, Acc));
within3([], _X, _Y, _Z, _Radius, _Limit, Acc) ->
    Acc.

wrap2([{_Cell, Id, Other = {Ox, Oy}, Vel, Group, Data} | Rest], X, Y, Wx, Wy, Radius, Limit, Acc) when
    is_float(X), is_float(Y), is_float(Wx), is_float(Wy), is_float(Limit)
->
    Dx = short(Ox - X, Wx),
    Dy = short(Oy - Y, Wy),
    Near = in_radius(Dx * Dx + Dy * Dy, Radius, Limit),
    wrap2(Rest, X, Y, Wx, Wy, Radius, Limit, found(Near, Id, {Dx, Dy}, Other, Vel, Group, Data, Acc));
wrap2([], _X, _Y, _Wx, _Wy, _Radius, _Limit, Acc) ->
    Acc.

wrap3([{_Cell, Id, Other = {Ox, Oy, Oz}, Vel, Group, Data} | Rest], X, Y, Z, Wx, Wy, Wz, Radius, Limit, Acc) when
    is_float(X), is_float(Y), is_float(Z), is_float(Wx), is_float(Wy), is_float(Wz), is_float(Limit)
->
    Dx = short(Ox - X, Wx),
    Dy = short(Oy - Y, Wy),
    Dz = short(Oz - Z, Wz),
    Near = in_radius(Dx * Dx + Dy * Dy + Dz * Dz, Radius, Limit),
    wrap3(Rest, X, Y, Z, Wx, Wy, Wz, Radius, Limit, found(Near, Id, {Dx, Dy, Dz}, Other, Vel, Group, Data, Acc));
wrap3([], _X, _Y, _Z, _Wx, _Wy, _Wz, _Radius, _Limit, Acc) ->
    Acc.

%% As boids_vec:shortest/3, for one number.
short(D, Width) when is_float(D), is_float(Width), 2 * D =< Width, 2 * D >= -Width -> D;
short(D, Width) -> D - Width * round(D / Width).

%% The distance for a square of a distance, or far.
in_radius(Dist2, Radius, Limit) when Dist2 =< Limit ->
    case math:sqrt(Dist2) of
        Dist when Dist =< Radius -> Dist;
        _ -> far
    end;
in_radius(_Dist2, _Radius, _Limit) ->
    far.

found(far, _Id, _Offset, _Other, _Vel, _Group, _Data, Acc) -> Acc;
found(Dist, Id, Offset, Other, Vel, Group, Data, Acc) -> [{Dist, Id, Offset, Other, Vel, Group, Data} | Acc].

%% With wrap, a reader sees a boid at the nearest of its positions.
neighbor(Widths, Pos, {Dist, Id, Offset, Other, Vel, Group, Data}) ->
    At =
        case Widths of
            none -> Other;
            _ -> boids_vec:add(Pos, Offset)
        end,
    #{id => Id, pos => At, vel => Vel, group => Group, data => Data, offset => Offset, dist => Dist}.

-doc """
The vector from the point `From` to the point `To`. With `wrap`, it is
the shortest of such vectors.
""".
-spec offset(space() | env(), vec(), vec()) -> vec().
offset(#{wrap := true, bounds := {Min, Max}}, From, To) ->
    boids_vec:shortest(boids_vec:sub(To, From), Min, Max);
offset(_Space, From, To) ->
    boids_vec:sub(To, From).

-doc """
The facts of the world: the box, all the obstacles and the scale of the
time. A boid gets `env/3`.
""".
-spec env(space()) -> env().
env(Space = #{bounds := Bounds, wrap := Wrap, facts := Facts}) ->
    #{
        bounds => Bounds,
        wrap => Wrap,
        obstacles => obstacles(Space),
        time_scale => ets:lookup_element(Facts, time_scale, 2)
    }.

-doc """
The facts of the world that a boid at `Pos` perceives: the box, the
scale of the time, and the obstacles at the distance `Reach` or less
(`obstacles/3`). `boids_boid:step/4` uses them, with the reach of
`boids_boid:reach/1`.
""".
-spec env(space(), vec(), number()) -> env().
env(Space = #{bounds := Bounds, wrap := Wrap, facts := Facts}, Pos, Reach) ->
    #{
        bounds => Bounds,
        wrap => Wrap,
        obstacles => obstacles(Space, Pos, Reach),
        time_scale => ets:lookup_element(Facts, time_scale, 2)
    }.

-doc "All the obstacles of the space, in the order of their ids.".
-spec obstacles(space()) -> [obstacle()].
obstacles(#{facts := Facts}) ->
    [obstacle(Row) || Row <- all_obstacles(Facts)].

-doc """
The obstacles at the distance `Reach` or less from the point `Pos`, in
the order of their ids. The distance is from `Pos` to the edge of the
obstacle. With `wrap`, it is the shortest distance, across a side too.
An obstacle with a center of another size is not in the result.

The read uses the index of the cells, so an obstacle far from `Pos`
costs nothing. A read finds each obstacle one time, also an obstacle
that moves during the read.
""".
-spec obstacles(space(), vec(), number()) -> [obstacle()].
obstacles(Space = #{facts := Facts, obstacle_cells := Cells}, Pos, Reach) when is_number(Reach), Reach >= 0 ->
    case ets:info(Cells, size) of
        %% No obstacle.
        0 ->
            [];
        Size ->
            Version = ets:lookup_element(Facts, obstacle_version, 2),
            Found =
                case Version band 1 =:= 0 andalso near_ids(Space, Pos, Reach, Size) of
                    false -> false;
                    Ids -> [Row || Id <- Ids, Row <- ets:lookup(Facts, {obstacle, Id})]
                end,
            Rows =
                case Found =/= false andalso ets:lookup_element(Facts, obstacle_version, 2) =:= Version of
                    true ->
                        Found;
                    %% A write runs, or a read of all the rows costs
                    %% less, or a write ran during the read. Such a
                    %% write can hide an obstacle from the cells: read
                    %% all the rows (specs/Space.tla, Check).
                    false ->
                        all_obstacles(Facts)
                end,
            [obstacle(Row) || Row <- Rows, reaches(Space, Pos, Reach, Row)]
    end.

%% The rows of all the obstacles, in the order of their ids. A row that
%% a write changes during the read is in the result one time.
all_obstacles(Facts) ->
    lists:sort(ets:match_object(Facts, {{obstacle, '_'}, '_', '_'})).

%% The ids of the obstacles in the cells to the distance Reach from Pos,
%% and of the large obstacles, in their order. False when a read of all
%% the rows costs less: more cells to read than rows in the index.
%%
%% The coarse cells come first: one to four reads (eight in 3D). A boid
%% far from all the obstacles finds none there. When they have fewer
%% obstacles than there are fine cells, their obstacles are the result:
%% the read of their rows costs less than the read of the fine cells.
%% Both are all the obstacles near Pos, and more: obstacles/3 keeps only
%% those at the distance.
near_ids(Space, Pos, Reach, Size) ->
    Axes = axes(Space, Pos, Reach),
    case cell_count(Axes) of
        Count when Count =< 1024, Count < Size ->
            Coarse = ids(Space, [large | [{coarse, Cell} || Cell <- cells_of(coarse(Space), Pos, Reach)]]),
            case length(Coarse) =< Count of
                true -> Coarse;
                false -> ids(Space, [large | product([numbers(Axis) || Axis <- Axes])])
            end;
        _ ->
            false
    end.

%% The ids of the obstacles in some cells of the index, with no copy.
ids(#{obstacle_cells := Cells}, Keys) ->
    lists:usort([Id || Key <- Keys, {_, Id} <- ets:lookup(Cells, Key)]).

%% The space with the coarse cells of the index of the obstacles: each
%% is 8 cells long on each side.
coarse(Space = #{cell_size := Size}) ->
    Space#{cell_size := Size * 8}.

%% True when the obstacle of a row is at the distance Reach or less
%% from Pos, with a center of the same size.
reaches(Space, Pos, Reach, {{obstacle, _Id}, At, Radius}) when tuple_size(At) =:= tuple_size(Pos) ->
    Limit = Reach + Radius,
    boids_vec:norm2(offset(Space, Pos, At)) =< Limit * Limit;
reaches(_Space, _Pos, _Reach, _Row) ->
    false.

obstacle({{obstacle, Id}, Pos, Radius}) ->
    #{id => Id, pos => Pos, radius => Radius}.

-doc """
Add an obstacle, or change it: a circle (a sphere in 3D) with the center
`Pos`. Call it again to move the obstacle.

Only the owner of the space calls this function: in a world, the
process of the world (`boids_world:set/3`). Another process gets the
error `badarg`, because the tables of the obstacles are protected. Thus
the writes of the obstacles come one after the other.

A center that is not a vector, or that does not have the size of the
vectors of the space, gives the error `badarg`. So does a radius that is
not a number of 0 or more.

The obstacle goes into the cells that it touches. The write adds the
new cells, then changes the row, then removes the old cells.
""".
-spec set_obstacle(space(), term(), vec(), number()) -> ok.
set_obstacle(Space = #{facts := Facts, obstacle_cells := Cells}, Id, Pos, Radius) ->
    Size = dim(Space),
    Good =
        boids_vec:is_vec(Pos) andalso boids_vec:is_size(Radius) andalso
            (Size =:= undefined orelse Size =:= tuple_size(Pos)),
    Good orelse error(badarg),
    New = obstacle_cells(Space, Pos, Radius),
    Old = [Cell || {_, At, R} <- ets:lookup(Facts, {obstacle, Id}), Cell <- obstacle_cells(Space, At, R)],
    write_obstacles(Facts, fun() ->
        ets:insert(Cells, [{Cell, Id} || Cell <- New -- Old]),
        ets:insert(Facts, {{obstacle, Id}, Pos, Radius}),
        [ets:delete_object(Cells, {Cell, Id}) || Cell <- Old -- New]
    end).

-doc """
Remove an obstacle. Only the owner of the space calls this function, as
for `set_obstacle/4`.
""".
-spec remove_obstacle(space(), term()) -> ok.
remove_obstacle(Space = #{facts := Facts, obstacle_cells := Cells}, Id) ->
    Old = [Cell || {_, At, R} <- ets:lookup(Facts, {obstacle, Id}), Cell <- obstacle_cells(Space, At, R)],
    write_obstacles(Facts, fun() ->
        ets:delete(Facts, {obstacle, Id}),
        [ets:delete_object(Cells, {Cell, Id}) || Cell <- Old]
    end).

%% The keys of an obstacle in the index: the cells that it touches and
%% its coarse cells, or [large] for an obstacle that touches more than
%% 1,024 cells.
obstacle_cells(Space, Pos, Radius) ->
    case cells_of(Space, Pos, Radius) of
        large -> [large];
        Cells -> Cells ++ [{coarse, Cell} || Cell <- cells_of(coarse(Space), Pos, Radius)]
    end.

%% The cells that the ball of Radius at Pos touches, or large when they
%% are more than 1,024.
cells_of(Space, Pos, Radius) ->
    Axes = axes(Space, Pos, Radius),
    case cell_count(Axes) of
        Count when Count > 1024 -> large;
        _ -> product([numbers(Axis) || Axis <- Axes])
    end.

%% The number of cells of some axes.
cell_count(Axes) ->
    lists:foldl(fun(Axis, Acc) -> Acc * count_axis(Axis) end, 1, Axes).

%% A write of the obstacles by the owner of the space. The version
%% changes at the start and at the end of the write: it is odd during
%% the write, so a reader knows that a write runs (specs/Space.tla, Open
%% and Close). A process that is not the owner gets the error badarg
%% here, before a change.
write_obstacles(Facts, Write) ->
    ets:update_counter(Facts, obstacle_version, 1),
    Write(),
    ets:update_counter(Facts, obstacle_version, 1),
    ok.

-doc """
Set the scale of the time: the seconds of the boids for each second of
the caller. With 0, the boids stop. The default is 1.0. A scale that is
not a number from 0 to 1.0e100 gives the error `badarg`.

Only the owner of the space calls this function, as for
`set_obstacle/4`.
""".
-spec set_time_scale(space(), number()) -> ok.
set_time_scale(#{facts := Facts}, Scale) ->
    is_number(Scale) andalso Scale >= 0 andalso Scale =< 1.0e100 orelse error(badarg),
    ets:insert(Facts, {time_scale, Scale}),
    ok.

%% --- The nodes of a world ---------------------------------------------

-doc "The nodes that have a part of the world of this space.".
-spec nodes(space()) -> [node()].
nodes(#{meta := Meta}) ->
    ets:lookup_element(Meta, nodes, 2).

-doc false.
set_nodes(#{meta := Meta}, Nodes) ->
    ets:insert(Meta, {nodes, lists:usort(Nodes)}),
    ok.

-doc """
The node that has the tile of a position. A world is cut into tiles (the
option `tile`), and each tile is on one node: the node with the largest
hash of the tile and of its name. Thus each node gives the same answer
with no message, and a new node takes only its part of the tiles.
""".
-spec home(space(), vec()) -> node().
home(Space, Pos) ->
    case ?MODULE:nodes(Space) of
        [Node] -> Node;
        Nodes -> pick(tile(Space, Pos), Nodes)
    end.

-doc """
Where a boid at `Pos` that sees the distance `Radius` is, for this node:

- `home`: in a tile of this node, and it sees no tile of another node;
- `{border, Nodes}`: in a tile of this node, and it sees tiles of these
  nodes;
- `{away, Home, Nodes}`: in a tile of the node `Home`. It also sees
  tiles of these other nodes.
""".
-spec place(space(), vec(), number()) -> home | {border, [node()]} | {away, node(), [node()]}.
place(Space, Pos, Radius) ->
    case ?MODULE:nodes(Space) of
        [_One] ->
            home;
        Nodes ->
            Home = pick(tile(Space, Pos), Nodes),
            Seen = lists:usort([pick(tile(Space, Corner), Nodes) || Corner <- corners(Pos, Radius)]),
            case {Home =:= node(), Seen -- [node()]} of
                {true, []} -> home;
                {true, Others} -> {border, Others};
                {false, Others} -> {away, Home, Others -- [Home]}
            end
    end.

%% The corners of the box around what a boid sees. With a tile that is
%% larger than that box, they are in all the tiles that the boid sees.
corners({X, Y}, R) ->
    [{X - R, Y - R}, {X - R, Y + R}, {X + R, Y - R}, {X + R, Y + R}];
corners({X, Y, Z}, R) ->
    [{X + Dx, Y + Dy, Z + Dz} || Dx <- [-R, R], Dy <- [-R, R], Dz <- [-R, R]].

tile(Space = #{tile := Size}, Pos) ->
    cell(Space#{cell_size := Size}, Pos).

pick(Tile, Nodes) ->
    {_Hash, Node} = lists:max([{erlang:phash2({Tile, Node}), Node} || Node <- Nodes]),
    Node.

-doc """
Write the row of a boid of another node, which shows itself near a
border. The result is `false` when a boid of this node has the id. Only
the owner of the space calls this function.
""".
-spec show(space(), entry()) -> boolean().
show(Space = #{rows := Rows, grid := Grid}, Entry = #{id := Id, pos := Pos, vel := Vel, pid := Pid}) ->
    Kind = {ghost, maps:get(kind, Entry, server)},
    case ets:lookup(Rows, Id) of
        [] ->
            insert_new(Space, Entry#{kind => Kind});
        [Row = {_, _, _, _, _, _, _, {ghost, _}, _}] ->
            Old = spot(Row),
            Cell = cell(Space, Pos),
            Group = maps:get(group, Entry, default),
            Data = maps:get(data, Entry, undefined),
            New = {Cell, Id, Pos, Vel, Group, Data},
            ets:insert(Rows, {Id, Pos, Vel, Group, Data, Cell, Pid, Kind, Old}),
            %% As a write of a boid: the new copy, then the removal of
            %% the old copy (specs/Space.tla, InsertFirst).
            New =:= Old orelse (ets:insert(Grid, New) andalso ets:delete_object(Grid, Old)),
            true;
        [_Local] ->
            false
    end.

%% --- The relations ----------------------------------------------------

-doc """
Write the boids that the boid `From` has the relation `Label` to, and
the same for the opposite direction of each of them. Only the owner of
the space calls this function: `boids_world` keeps the relations,
and writes here what the boids read at each step.
""".
-spec relate(space(), out | in, {term(), term()}, [term()]) -> ok.
relate(#{links := Links}, Direction, {Id, Label}, []) ->
    ets:delete(Links, {Direction, Id, Label}),
    ok;
relate(#{links := Links}, Direction, {Id, Label}, Others) ->
    ets:insert(Links, {{Direction, Id, Label}, Others}),
    ok.

-doc "All the relations of the boid `From`: a list of `{Label, [To]}`.".
-spec relations(space(), term()) -> [{term(), [term()]}].
relations(#{links := Links}, From) ->
    [{Label, Others} || [Label, Others] <- ets:match(Links, {{out, From, '$1'}, '$2'})].

-doc "The boids that the boid `From` has the relation `Label` to.".
-spec related(space(), term(), term()) -> [term()].
related(#{links := Links}, From, Label) ->
    ets:lookup_element(Links, {out, From, Label}, 2, []).

-doc "The boids that have the relation `Label` to the boid `To`.".
-spec related_to(space(), term(), term()) -> [term()].
related_to(#{links := Links}, To, Label) ->
    ets:lookup_element(Links, {in, To, Label}, 2, []).

%% --- The rows and the grid --------------------------------------------

row(Space, #{id := Id, pos := Pos, vel := Vel} = Entry) ->
    Group = maps:get(group, Entry, default),
    Data = maps:get(data, Entry, undefined),
    Pid = maps:get(pid, Entry, undefined),
    {Id, Pos, Vel, Group, Data, cell(Space, Pos), Pid, maps:get(kind, Entry, process), none}.

entry({Id, Pos, Vel, Group, Data, _Cell, Pid, _Kind, _Last}) ->
    #{id => Id, pos => Pos, vel => Vel, group => Group, data => Data, pid => Pid}.

spot({Id, Pos, Vel, Group, Data, Cell, _Pid, _Kind, _Last}) ->
    {Cell, Id, Pos, Vel, Group, Data}.

%% The cell of a point. With wrap, the cells start at the minimum of the
%% box, and a point out of the box is in the cell of its point in the box.
cell(#{wrap := true, bounds := {Min, Max}, cell_size := Size}, Pos) ->
    case {boids_vec:sub(boids_vec:wrap(Pos, Min, Max), Min), boids_vec:sub(Max, Min)} of
        {{X, Y}, {Wx, Wy}} -> {index(X, Wx, Size), index(Y, Wy, Size)};
        {{X, Y, Z}, {Wx, Wy, Wz}} -> {index(X, Wx, Size), index(Y, Wy, Size), index(Z, Wz, Size)}
    end;
cell(#{cell_size := Size}, {X, Y}) ->
    {floor(X / Size), floor(Y / Size)};
cell(#{cell_size := Size}, {X, Y, Z}) ->
    {floor(X / Size), floor(Y / Size), floor(Z / Size)}.

%% A point very near the maximum can be at the width of the box, because
%% of the precision: it is in the last cell.
index(X, Width, Size) ->
    min(floor(X / Size), ceil(Width / Size) - 1).

%% The cells that the ball of Radius at Pos touches, or all when a read
%% of all the rows costs less than a read of these cells.
cells(Space = #{rows := Rows}, Pos, Radius) ->
    Axes = axes(Space, Pos, Radius),
    Count = cell_count(Axes),
    %% A small number of cells needs no read of the size of the table.
    case Count > 27 andalso Count > ets:info(Rows, size) of
        true -> all;
        false -> product([numbers(Axis) || Axis <- Axes])
    end.

count_axis([{Lo, Hi}]) -> Hi - Lo + 1;
count_axis([{Lo1, Hi1}, {Lo2, Hi2}]) -> Hi1 - Lo1 + Hi2 - Lo2 + 2.

numbers([{Lo, Hi}]) -> lists:seq(Lo, Hi);
numbers([{Lo1, Hi1}, {Lo2, Hi2}]) -> lists:usort(lists:seq(Lo1, Hi1) ++ lists:seq(Lo2, Hi2)).

product([Xs, Ys]) -> [{X, Y} || X <- Xs, Y <- Ys];
product([Xs, Ys, Zs]) -> [{X, Y, Z} || X <- Xs, Y <- Ys, Z <- Zs].

%% Each axis is one or two ranges of cell numbers: {First, Last}.
axes(#{wrap := true, bounds := {Min, Max}, cell_size := Size}, Pos, Radius) ->
    case {boids_vec:wrap(Pos, Min, Max), Min, Max} of
        {{X, Y}, {X1, Y1}, {X2, Y2}} ->
            [wrap_axis(X - X1, Radius, X2 - X1, Size), wrap_axis(Y - Y1, Radius, Y2 - Y1, Size)];
        {{X, Y, Z}, {X1, Y1, Z1}, {X2, Y2, Z2}} ->
            [
                wrap_axis(X - X1, Radius, X2 - X1, Size),
                wrap_axis(Y - Y1, Radius, Y2 - Y1, Size),
                wrap_axis(Z - Z1, Radius, Z2 - Z1, Size)
            ]
    end;
axes(#{cell_size := Size}, {X, Y}, Radius) ->
    [axis(X, Radius, Size), axis(Y, Radius, Size)];
axes(#{cell_size := Size}, {X, Y, Z}, Radius) ->
    [axis(X, Radius, Size), axis(Y, Radius, Size), axis(Z, Radius, Size)].

axis(X, Radius, Size) ->
    [{floor((X - Radius) / Size), floor((X + Radius) / Size)}].

wrap_axis(_X, Radius, Width, Size) when 2 * Radius >= Width ->
    [range(0, Width, Size, Width)];
wrap_axis(X, Radius, Width, Size) when X - Radius < 0 ->
    [range(0, X + Radius, Size, Width), range(X - Radius + Width, Width, Size, Width)];
wrap_axis(X, Radius, Width, Size) when X + Radius >= Width ->
    [range(X - Radius, Width, Size, Width), range(0, X + Radius - Width, Size, Width)];
wrap_axis(X, Radius, Width, Size) ->
    [range(X - Radius, X + Radius, Size, Width)].

%% The cells from Lo to Hi of an axis with wrap. The last cell has the
%% last point of the box, which is less than Width.
range(Lo, Hi, Size, Width) ->
    {floor(Lo / Size), min(floor(Hi / Size), ceil(Width / Size) - 1)}.
