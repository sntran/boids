-module(boids_space).
-moduledoc """
The space of a flock: where each boid is, in ETS tables.

Each boid has one row with its position and its velocity. A grid of
cells is the index of the rows, so a boid finds its neighbors with no
message and with no read of all the rows. The tables are public: each
process writes its own row, and all the processes read all the rows at
the same time.

A space is a map. Its process (the owner of the tables) makes it with
`new/1`, and other processes get a copy of it. `boids_flock` is the owner
in a flock, but a space also works alone, in one process.

With `wrap`, each side of the box `bounds` continues at the opposite
side. Then `near/3` gives each neighbor at its nearest position, which
can be out of the box.
""".

-export([new/1, options/1, delete/1]).
-export([insert_new/2, put/2, remove/2]).
-export([lookup/2, server/2, near/3, all/1, count/1, dim/1, offset/3]).
-export([env/1, obstacles/1, set_obstacle/4, remove_obstacle/2, set_time_scale/2]).

-export_type([space/0, entry/0, neighbor/0, obstacle/0, env/0]).

-type vec() :: boids_vec:vec().
-type space() :: #{
    rows := ets:table(),
    grid := ets:table(),
    meta := ets:table(),
    owner := pid(),
    cell_size := number(),
    bounds := {vec(), vec()} | undefined,
    wrap := boolean(),
    defaults := map()
}.
-type entry() :: #{
    id := term(),
    pos := vec(),
    vel := vec(),
    group => term(),
    data => term(),
    pid => pid() | undefined,
    server => boolean()
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

%% A row: {Id, Pos, Vel, Group, Data, Cell, Pid, Server, Last}. Server is
%% true when the process of the boid is a boids_server.
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
    Meta = ets:new(boids_meta, [set, public, {read_concurrency, true}]),
    ets:insert(Meta, {time_scale, 1.0}),
    Space#{rows => Rows, grid => Grid, meta => Meta, owner => self()}.

-doc """
Check the options of a space, and give them with their defaults. A bad
option gives the error `{bad_option, {Key, Value}}`.
""".
-spec options(map()) -> map().
options(Opts) when is_map(Opts) ->
    maps:foreach(fun check/2, Opts),
    case maps:merge(#{cell_size => 10.0, bounds => undefined, wrap => false, defaults => #{}}, Opts) of
        #{wrap := true, bounds := undefined} -> error({bad_option, {wrap, true}});
        Space -> Space
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
ok(_, _) -> false.

-doc "Delete the tables of a space. Only the owner can do this.".
-spec delete(space()) -> ok.
delete(#{rows := Rows, grid := Grid, meta := Meta}) ->
    ets:delete(Rows),
    ets:delete(Grid),
    ets:delete(Meta),
    ok.

-doc "Add the row of a new boid. The result is `false` when the id is in the space.".
-spec insert_new(space(), entry()) -> boolean().
insert_new(Space = #{rows := Rows, grid := Grid}, Entry) ->
    Row = row(Space, Entry),
    ets:insert_new(Rows, Row) andalso ets:insert(Grid, spot(Row)).

-doc """
Write the row of a boid that is in the space: its position, its
velocity, its group and its data. The result is `false` when the id is
not in the space. Only the process of the boid calls this function.
""".
-spec put(space(), entry() | boids_boid:boid()) -> boolean().
put(Space = #{rows := Rows, grid := Grid}, #{id := Id, pos := Pos, vel := Vel, group := Group, data := Data}) ->
    case ets:lookup(Rows, Id) of
        [Row = {_, _, _, _, _, _, Pid, Server, _}] ->
            Old = spot(Row),
            Cell = cell(Space, Pos),
            case {Cell, Id, Pos, Vel, Group, Data} of
                Old ->
                    true;
                New ->
                    %% The new copy comes before the removal of the old
                    %% copy, so a reader always finds the boid in its cell
                    %% (specs/Space.tla, InsertFirst).
                    ets:insert(Rows, {Id, Pos, Vel, Group, Data, Cell, Pid, Server, Old}),
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
The process of a boid, when that process is a `boids_server`.
""".
-spec server(space(), term()) -> {ok, pid()} | error.
server(#{rows := Rows}, Id) ->
    case ets:lookup(Rows, Id) of
        [{_, _, _, _, _, _, Pid, true, _}] -> {ok, Pid};
        _ -> error
    end.

-doc "All the rows. The order is not specified.".
-spec all(space()) -> [entry()].
all(#{rows := Rows}) ->
    [entry(Row) || Row <- ets:tab2list(Rows)].

-doc "The number of rows.".
-spec count(space()) -> non_neg_integer().
count(#{rows := Rows}) ->
    ets:info(Rows, size).

-doc """
The size of the vectors of the space: that of its box, or that of its
boids. A space with no box and no boid has none.
""".
-spec dim(space()) -> 2 | 3 | undefined.
dim(#{bounds := {Min, _Max}}) ->
    tuple_size(Min);
dim(#{rows := Rows}) ->
    case ets:first_lookup(Rows) of
        {_Id, [Row]} -> tuple_size(element(2, Row));
        '$end_of_table' -> undefined
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
    %% The squares of the distances find most of the boids that are too
    %% far, with no square root.
    Limit = {Radius, Radius * Radius * 1.000001},
    Found =
        case cells(Space, Pos, Radius) of
            all ->
                within([spot(Row) || Row <- ets:tab2list(Rows)], Pos, Widths, Limit, []);
            Cells ->
                lists:foldl(fun(Cell, Acc) -> within(ets:lookup(Grid, Cell), Pos, Widths, Limit, Acc) end, [], Cells)
        end,
    %% A boid that writes its row during the read can have two copies in
    %% the grid: keep one of the two (specs/Space.tla, Dedupe). The keys
    %% of a map are exact, as the keys of the table: 1 and 1.0 are two
    %% ids. Then the nearest comes first.
    One = maps:values(#{element(2, Near) => Near || Near <- Found}),
    [neighbor(Widths, Pos, Near) || Near <- lists:sort(One)].

%% The sizes of the box when its sides continue, or none.
widths(#{wrap := true, bounds := {Min, Max}}) -> boids_vec:sub(Max, Min);
widths(_Space) -> none.

%% The boids of a list in the radius, as {Dist, Id, Offset, Pos, Vel,
%% Group, Data}. The offset is that of offset/3.
within([{_Cell, Id, Other = {Ox, Oy}, Vel, Group, Data} | Rest], Pos = {X, Y}, Widths, Limit, Acc) ->
    {Wx, Wy} = sizes(Widths, 2),
    Dx = short(Ox - X, Wx),
    Dy = short(Oy - Y, Wy),
    Near = in_radius(Dx * Dx + Dy * Dy, Limit),
    within(Rest, Pos, Widths, Limit, found(Near, Id, {Dx, Dy}, Other, Vel, Group, Data, Acc));
within([{_Cell, Id, Other = {Ox, Oy, Oz}, Vel, Group, Data} | Rest], Pos = {X, Y, Z}, Widths, Limit, Acc) ->
    {Wx, Wy, Wz} = sizes(Widths, 3),
    Dx = short(Ox - X, Wx),
    Dy = short(Oy - Y, Wy),
    Dz = short(Oz - Z, Wz),
    Near = in_radius(Dx * Dx + Dy * Dy + Dz * Dz, Limit),
    within(Rest, Pos, Widths, Limit, found(Near, Id, {Dx, Dy, Dz}, Other, Vel, Group, Data, Acc));
within([], _Pos, _Widths, _Limit, Acc) ->
    Acc.

sizes(none, 2) -> {none, none};
sizes(none, 3) -> {none, none, none};
sizes(Widths, _Dim) -> Widths.

%% As boids_vec:shortest/3, for one number.
short(D, none) -> D;
short(D, Width) when 2 * D =< Width, 2 * D >= -Width -> D;
short(D, Width) -> D - Width * round(D / Width).

%% The distance for a square of a distance, or far.
in_radius(Dist2, {Radius, Radius2}) when Dist2 =< Radius2 ->
    case math:sqrt(Dist2) of
        Dist when Dist =< Radius -> Dist;
        _ -> far
    end;
in_radius(_Dist2, _Limit) ->
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
The environment of the boids: the box, the obstacles and the scale of
the time. `boids_boid:step/4` uses it.
""".
-spec env(space()) -> env().
env(Space = #{bounds := Bounds, wrap := Wrap, meta := Meta}) ->
    %% The table has the scale of the time, and one row for each obstacle.
    Obstacles =
        case ets:info(Meta, size) of
            1 -> [];
            _ -> obstacles(Space)
        end,
    #{bounds => Bounds, wrap => Wrap, obstacles => Obstacles, time_scale => ets:lookup_element(Meta, time_scale, 2)}.

-doc "The obstacles of the space, in the order of their ids.".
-spec obstacles(space()) -> [obstacle()].
obstacles(#{meta := Meta}) ->
    Found = ets:match_object(Meta, {{obstacle, '_'}, '_', '_'}),
    [#{id => Id, pos => Pos, radius => Radius} || {{obstacle, Id}, Pos, Radius} <- lists:sort(Found)].

-doc """
Add an obstacle, or change it: a circle (a sphere in 3D) with the center
`Pos`. Each process can call this function, so an obstacle can move.
A center that is not a vector, or that does not have the size of the
vectors of the space, gives the error `badarg`. So does a radius that is
not a number of 0 or more.
""".
-spec set_obstacle(space(), term(), vec(), number()) -> ok.
set_obstacle(Space = #{meta := Meta}, Id, Pos, Radius) ->
    Size = dim(Space),
    Good =
        boids_vec:is_vec(Pos) andalso boids_vec:is_size(Radius) andalso
            (Size =:= undefined orelse Size =:= tuple_size(Pos)),
    Good orelse error(badarg),
    ets:insert(Meta, {{obstacle, Id}, Pos, Radius}),
    ok.

-doc "Remove an obstacle.".
-spec remove_obstacle(space(), term()) -> ok.
remove_obstacle(#{meta := Meta}, Id) ->
    ets:delete(Meta, {obstacle, Id}),
    ok.

-doc """
Set the scale of the time: the seconds of the boids for each second of
the caller. With 0, the boids stop. The default is 1.0.
""".
-spec set_time_scale(space(), number()) -> ok.
set_time_scale(#{meta := Meta}, Scale) when is_number(Scale), Scale >= 0, Scale =< 1.0e100 ->
    ets:insert(Meta, {time_scale, Scale}),
    ok.

%% --- The rows and the grid --------------------------------------------

row(Space, #{id := Id, pos := Pos, vel := Vel} = Entry) ->
    Group = maps:get(group, Entry, default),
    Data = maps:get(data, Entry, undefined),
    Pid = maps:get(pid, Entry, undefined),
    {Id, Pos, Vel, Group, Data, cell(Space, Pos), Pid, maps:get(server, Entry, false), none}.

entry({Id, Pos, Vel, Group, Data, _Cell, Pid, _Server, _Last}) ->
    #{id => Id, pos => Pos, vel => Vel, group => Group, data => Data, pid => Pid}.

spot({Id, Pos, Vel, Group, Data, Cell, _Pid, _Server, _Last}) ->
    {Cell, Id, Pos, Vel, Group, Data}.

%% The cell of a point. With wrap, the cells start at the minimum of the
%% box, and a point out of the box is in the cell of its point in the box.
cell(#{wrap := true, bounds := {Min, Max}, cell_size := Size}, Pos) ->
    At = tuple_to_list(boids_vec:sub(boids_vec:wrap(Pos, Min, Max), Min)),
    Box = tuple_to_list(boids_vec:sub(Max, Min)),
    %% A point very near the maximum can be at the width of the box,
    %% because of the precision: it is in the last cell.
    list_to_tuple([min(floor(X / Size), ceil(Width / Size) - 1) || {X, Width} <- lists:zip(At, Box)]);
cell(#{cell_size := Size}, Pos) ->
    list_to_tuple([floor(X / Size) || X <- tuple_to_list(Pos)]).

%% The cells that the ball of Radius at Pos touches, or all when a read
%% of all the rows costs less than a read of these cells.
cells(Space = #{rows := Rows}, Pos, Radius) ->
    Axes = axes(Space, Pos, Radius),
    Count = lists:foldl(fun(Axis, Acc) -> Acc * count_axis(Axis) end, 1, Axes),
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
