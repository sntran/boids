-module(boids_grid).
-moduledoc """
A grid of square cells: the places where a boid can walk, and what
each place costs. Each cell is blocked, or open with a cost: a number
more than 0, and 1 by default.

```erlang
Grid = boids_grid:from_rows([
    "..........",
    "....##....",
    "....##....",
    ".........."
], #{cell_size => 2.0}),
false = boids_grid:walkable(Grid, {9.0, 3.0}),
none = boids_grid:hit(Grid, {1.0, 1.0}, {19.0, 1.0}),
{_At, {1.0, 0.0}} = boids_grid:hit(Grid, {1.0, 3.0}, {19.0, 3.0}).
```

The cell `{I, J}` is the square from `Origin + {I, J} * CellSize`, with
the side `CellSize`. The first row of `from_rows/2` is the row `J = 0`.
A place outside the grid is blocked.

The functions read the grid for the code of a boid:

- `walkable/2`, `cost/2` and `blocked/2` tell what is at a place.
- `hit/3` gives the first contact of a line with a blocked cell, and
  the direction of that edge: the limit of the movement of a boid.
- `nearest/2` gives the walkable place nearest to a position: for a
  boid in a cell that became blocked.
- `walls/3` gives the walls near a position: for a force away from
  them.
- `steps/2` gives the steps from a cell to the cells around it, with
  their costs: for a search of the shortest way.

The cells are in a binary. A binary of more than 64 bytes is not copied
from process to process: all the processes with the same grid share one
copy of its cells. A change of a cell (`set_cost/3`) makes a new grid.

**A grid has two dimensions.**
""".

-export([new/1, from_rows/2, is_grid/1]).
-export([size/1, cell_size/1, origin/1, bounds/1]).
-export([cell/2, center/2, cost/2, costs/1, blocked/2, walkable/2, set_cost/3]).
-export([steps/2, hit/3, hit/4, nearest/2, nearest/3, walls/3, walls/4]).

-export_type([grid/0, cell/0]).

-record(boids_grid, {
    cell_size :: float(),
    origin :: {float(), float()},
    cols :: pos_integer(),
    rows :: pos_integer(),
    %% The cost of each cell, row after row, as a float of 64 bits. A
    %% blocked cell has the cost -1.0.
    cells :: binary(),
    %% The number of the open cells.
    open :: non_neg_integer()
}).

-opaque grid() :: #boids_grid{}.
-type cell() :: {integer(), integer()}.
-type vec() :: {number(), number()}.

-define(BLOCKED, -1.0).
-define(OPTIONS, [size, cell_size, origin, blocked, costs]).

%% The part of a cell between a contact with a blocked cell and the
%% edge of that cell: the boid stays out of the blocked cell.
-define(GAP, 1.0e-6).

-doc """
Make a grid from its options (a map, or a list of `{Key, Value}`):

| Option | Default | Description |
|---|---|---|
| `size` | (necessary) | `{Columns, Rows}`: the number of cells. |
| `cell_size` | `1.0` | The side of a cell. |
| `origin` | `{0.0, 0.0}` | The corner of the cell `{0, 0}`. |
| `blocked` | `[]` | The cells that are blocked: a list of cells, or a function `fun(Center) -> boolean()`. The library calls the function one time for each cell, with the center of the cell. |
| `costs` | `[]` | `[{Cell, Cost}]` or a map: the costs of the open cells. |

A bad option gives the error `{bad_option, {Key, Value}}`.
""".
-spec new(map() | [{atom(), term()}]) -> grid().
new(Opts0) ->
    Opts = boids_boid:to_map(Opts0),
    [error({bad_option, {Key, Value}}) || Key := Value <- Opts, not lists:member(Key, ?OPTIONS)],
    {Cols, Rows} = size_option(maps:get(size, Opts, undefined)),
    Grid = make(Opts, Cols, Rows, binary:copy(<<1.0:64/float>>, Cols * Rows)),
    Blocked = blocked_option(Grid, maps:get(blocked, Opts, [])),
    [error({bad_option, {blocked, Cell}}) || Cell <- Blocked, not inside(Grid, Cell)],
    Costs = cost_list(maps:get(costs, Opts, [])),
    [
        error({bad_option, {costs, Cost}})
     || Cost = {Cell, Value} <- Costs, not (inside(Grid, Cell) andalso is_cost(Value))
    ],
    write(Grid, [{Cell, ?BLOCKED} || Cell <- Blocked] ++ [{Cell, float(Value)} || {Cell, Value} <- Costs]).

size_option({Cols, Rows}) when is_integer(Cols), Cols > 0, is_integer(Rows), Rows > 0 -> {Cols, Rows};
size_option(Size) -> error({bad_option, {size, Size}}).

%% The blocked cells: a list, or the cells whose center a function
%% tells is blocked. Thus a shape that is not made of cells (a circle, a
%% picture) becomes a grid one time, and not at each step of a boid.
blocked_option(_Grid, Blocked) when is_list(Blocked) ->
    Blocked;
blocked_option(Grid = #boids_grid{cols = Cols, rows = Rows}, Blocked) when is_function(Blocked, 1) ->
    [
        {I, J}
     || J <- lists:seq(0, Rows - 1), I <- lists:seq(0, Cols - 1), Blocked(center(Grid, {I, J})) =:= true
    ];
blocked_option(_Grid, Blocked) ->
    error({bad_option, {blocked, Blocked}}).

cost_list(Costs) when is_map(Costs) -> maps:to_list(Costs);
cost_list(Costs) when is_list(Costs) ->
    [error({bad_option, {costs, Cost}}) || Cost <- Costs, not is_tuple(Cost) orelse tuple_size(Cost) =/= 2],
    Costs;
cost_list(Costs) ->
    error({bad_option, {costs, Costs}}).

-doc """
Make a grid from rows of text: a string or a binary for each row, all
of the same length. The first row is the row `J = 0`.

- `#` is a blocked cell.
- `.` and a space are an open cell with the cost 1.
- A digit from `1` to `9` is an open cell with that cost.

The options are `cell_size` and `origin` (see `new/1`).
""".
-spec from_rows([string() | binary()], map() | [{atom(), term()}]) -> grid().
from_rows(Rows0, Opts0) ->
    Opts = boids_boid:to_map(Opts0),
    [error({bad_option, {Key, Value}}) || Key := Value <- Opts, not lists:member(Key, [cell_size, origin])],
    is_list(Rows0) andalso Rows0 =/= [] orelse error({bad_option, {rows, Rows0}}),
    Rows = [row(Row) || Row <- Rows0],
    Cols = length(hd(Rows)),
    [error({bad_option, {rows, Row}}) || Row <- Rows, length(Row) =/= Cols orelse Cols =:= 0],
    count(make(Opts, Cols, length(Rows), <<<<(char(Char)):64/float>> || Row <- Rows, Char <- Row>>)).

row(Row) when is_binary(Row) -> unicode:characters_to_list(Row);
row(Row) when is_list(Row) -> Row;
row(Row) -> error({bad_option, {rows, Row}}).

char($#) -> ?BLOCKED;
char($.) -> 1.0;
char($\s) -> 1.0;
char(Digit) when Digit >= $1, Digit =< $9 -> float(Digit - $0);
char(Char) -> error({bad_option, {rows, [Char]}}).

make(Opts, Cols, Rows, Cells) ->
    Side = maps:get(cell_size, Opts, 1.0),
    boids_vec:is_size(Side) andalso Side > 0 orelse error({bad_option, {cell_size, Side}}),
    {Ox, Oy} = origin_option(maps:get(origin, Opts, {0.0, 0.0})),
    #boids_grid{
        cell_size = float(Side),
        origin = {float(Ox), float(Oy)},
        cols = Cols,
        rows = Rows,
        cells = Cells,
        open = Cols * Rows
    }.

%% Count the open cells.
count(Grid = #boids_grid{cells = Cells}) ->
    Grid#boids_grid{open = length([open || <<Cost:64/float>> <= Cells, Cost > 0])}.

origin_option({Ox, Oy}) when is_number(Ox), is_number(Oy) -> {Ox, Oy};
origin_option(Origin) -> error({bad_option, {origin, Origin}}).

-doc "True for a grid of this module.".
-spec is_grid(term()) -> boolean().
is_grid(Term) -> is_record(Term, boids_grid).

-doc "The number of cells: `{Columns, Rows}`.".
-spec size(grid()) -> {pos_integer(), pos_integer()}.
size(#boids_grid{cols = Cols, rows = Rows}) -> {Cols, Rows}.

-doc "The side of a cell.".
-spec cell_size(grid()) -> float().
cell_size(#boids_grid{cell_size = Side}) -> Side.

-doc "The corner of the cell `{0, 0}`.".
-spec origin(grid()) -> {float(), float()}.
origin(#boids_grid{origin = Origin}) -> Origin.

-doc "The box of the grid: `{Min, Max}`.".
-spec bounds(grid()) -> {vec(), vec()}.
bounds(#boids_grid{cell_size = Side, origin = {Ox, Oy}, cols = Cols, rows = Rows}) ->
    {{Ox, Oy}, {Ox + Cols * Side, Oy + Rows * Side}}.

-doc "The cell of a position. The cell can be outside the grid.".
-spec cell(grid(), vec()) -> cell().
cell(#boids_grid{cell_size = Side, origin = {Ox, Oy}}, {X, Y}) ->
    {floor((X - Ox) / Side), floor((Y - Oy) / Side)}.

-doc "The center of a cell.".
-spec center(grid(), cell()) -> vec().
center(#boids_grid{cell_size = Side, origin = {Ox, Oy}}, {I, J}) ->
    {Ox + (I + 0.5) * Side, Oy + (J + 0.5) * Side}.

-doc "The cost of a cell: a number, or `infinity` for a blocked cell and a cell outside the grid.".
-spec cost(grid(), cell()) -> float() | infinity.
cost(Grid = #boids_grid{cols = Cols, cells = Cells}, Cell = {I, J}) ->
    case inside(Grid, Cell) of
        true ->
            Offset = (J * Cols + I) * 8,
            <<_:Offset/binary, Cost:64/float, _/binary>> = Cells,
            case Cost < 0 of
                true -> infinity;
                false -> Cost
            end;
        false ->
            infinity
    end.

-doc """
The costs of all the cells, row after row: a binary with a float of 64
bits for each cell. A blocked cell has the value -1.0. A function that
reads all the grid (`boids_field:new/2`) uses it.
""".
-spec costs(grid()) -> binary().
costs(#boids_grid{cells = Cells}) -> Cells.

-doc "True for a blocked cell, and for a cell outside the grid.".
-spec blocked(grid(), cell()) -> boolean().
blocked(Grid, Cell) -> cost(Grid, Cell) =:= infinity.

-doc "True when a boid with this grid can be at the position `Pos`.".
-spec walkable(grid(), vec()) -> boolean().
walkable(Grid, Pos) -> not blocked(Grid, cell(Grid, Pos)).

-doc """
Change cells: each one gets the cost `Cost` (a number more than 0), or
is blocked (`blocked`). The result is a new grid. A cell outside the
grid, or a bad cost, gives the error `badarg`.
""".
-spec set_cost(grid(), [cell()], number() | blocked) -> grid().
set_cost(Grid, Cells, Cost) ->
    Good = (Cost =:= blocked orelse is_cost(Cost)) andalso is_list(Cells),
    case Good andalso lists:all(fun(Cell) -> inside(Grid, Cell) end, Cells) of
        true when Cost =:= blocked -> write(Grid, [{Cell, ?BLOCKED} || Cell <- Cells]);
        true -> write(Grid, [{Cell, float(Cost)} || Cell <- Cells]);
        false -> error(badarg)
    end.

is_cost(Cost) -> boids_vec:is_size(Cost) andalso Cost > 0.

inside(#boids_grid{cols = Cols, rows = Rows}, {I, J}) when is_integer(I), is_integer(J) ->
    I >= 0 andalso I < Cols andalso J >= 0 andalso J < Rows;
inside(_Grid, _Cell) ->
    false.

%% Write the values of cells: one new binary, from the parts of the old
%% binary between the cells. The last value of a cell stays.
write(Grid, []) ->
    Grid;
write(Grid = #boids_grid{cols = Cols, cells = Cells}, Changes) ->
    Values = maps:from_list([{(J * Cols + I) * 8, Value} || {{I, J}, Value} <- Changes]),
    {Parts, From} =
        lists:foldl(
            fun(Offset, {Acc, Start}) ->
                {[<<(maps:get(Offset, Values)):64/float>>, binary_part(Cells, Start, Offset - Start) | Acc], Offset + 8}
            end,
            {[], 0},
            lists:sort(maps:keys(Values))
        ),
    Rest = binary_part(Cells, From, byte_size(Cells) - From),
    count(Grid#boids_grid{cells = iolist_to_binary(lists:reverse([Rest | Parts]))}).

-doc """
The steps from a cell to the open cells around it, in 8 directions:
`[{Cell, Cost}]`. A step across a corner needs the two cells beside it
open, so a way does not cut the corner of a blocked cell. The cost of
a step is its length in cells (1, or the square root of 2) multiplied
by the mean of the costs of the two cells: the cost from A to B is the
cost from B to A. A blocked cell has no step.
""".
-spec steps(grid(), cell()) -> [{cell(), float()}].
steps(Grid, Cell = {I, J}) ->
    case cost(Grid, Cell) of
        infinity ->
            [];
        Own ->
            [
                {To, Length * (Own + Cost) / 2}
             || {Di, Dj} <- [{1, 0}, {-1, 0}, {0, 1}, {0, -1}, {1, 1}, {1, -1}, {-1, 1}, {-1, -1}],
                To <- [{I + Di, J + Dj}],
                Cost <- [cost(Grid, To)],
                Cost =/= infinity,
                Di =:= 0 orelse Dj =:= 0 orelse
                    not (blocked(Grid, {I + Di, J}) orelse blocked(Grid, {I, J + Dj})),
                Length <- [span(Di, Dj)]
            ]
    end.

span(Di, Dj) when Di =:= 0; Dj =:= 0 -> 1.0;
span(_Di, _Dj) -> math:sqrt(2).

-doc #{equiv => hit(Grid, From, To, none)}.
-spec hit(grid(), vec(), vec()) -> none | inside | {vec(), vec()}.
hit(Grid, From, To) ->
    hit(Grid, From, To, none).

-doc """
The first contact of the line from `From` to `To` with a blocked cell:
`none`, or `{At, Normal}`. `At` is the last point of the line before the
blocked cell, a very short distance from its edge, and `Normal` is a
vector of length 1 into the edge. At a corner of two blocked cells,
`Normal` is between their edges. The line does not go between two
blocked cells that touch at a corner.

`From` in a blocked cell gives `inside`: see `nearest/2`. With `Box`
(`{Min, Max}`), the sides of the box continue at the opposite sides, as
with `wrap`.
""".
-spec hit(grid(), vec(), vec(), none | {vec(), vec()}) -> none | inside | {vec(), vec()}.
hit(Grid, From, To, Box) ->
    case trace(Grid, From, To, Box) of
        {At, Normal, _Blocked} -> {At, Normal};
        Other -> Other
    end.

%% As hit/4, with the blocked cells of the contact: none, inside, or
%% {At, Normal, Blocked}.
trace(Grid = #boids_grid{cell_size = Side, origin = {Ox, Oy}}, From = {X0, Y0}, To = {X1, Y1}, Box) ->
    Gx = (X0 - Ox) / Side,
    Gy = (Y0 - Oy) / Side,
    Cell = {floor(Gx), floor(Gy)},
    case look(Grid, Cell, Box) of
        true ->
            inside;
        false ->
            case cell(Grid, To) of
                %% The line stays in its cell: most steps of a boid.
                Cell ->
                    none;
                _ ->
                    {Sx, Tx, Ex} = axis(Gx, (X1 - X0) / Side),
                    {Sy, Ty, Ey} = axis(Gy, (Y1 - Y0) / Side),
                    walk(Grid, Box, Cell, {Sx, Sy}, {Tx, Ty}, {Ex, Ey}, {From, To})
            end
    end.

%% For one axis: the direction of the steps from cell to cell (-1, 0 or
%% 1), the part of the line to the first edge, and the part of the line
%% between two edges.
axis(G, D) when D > 0 -> {1, (floor(G) + 1 - G) / D, 1 / D};
axis(G, D) when D < 0 -> {-1, (G - floor(G)) / -D, -1 / D};
axis(_G, _D) -> {0, infinity, infinity}.

%% The cells along the line, in their order (a search of Amanatides and
%% Woo). Tx and Ty are the parts of the line to the next edges.
walk(Grid, Box, Cell = {I, J}, S = {Sx, Sy}, {Tx, Ty}, E = {Ex, Ey}, Line) ->
    T = min(Tx, Ty),
    if
        T > 1 ->
            none;
        Tx < Ty ->
            next(Grid, Box, Cell, {I + Sx, J}, S, {Tx + Ex, Ty}, E, Line, T, {Sx, 0});
        Ty < Tx ->
            next(Grid, Box, Cell, {I, J + Sy}, S, {Tx, Ty + Ey}, E, Line, T, {0, Sy});
        true ->
            %% The line goes through a corner. It does not go between two
            %% cells that touch at that corner.
            {A, B} = {{I + Sx, J}, {I, J + Sy}},
            case {look(Grid, A, Box), look(Grid, B, Box)} of
                {true, true} -> contact(Grid, Cell, Line, T, {Sx, Sy}, [A, B]);
                {true, false} -> contact(Grid, Cell, Line, T, {Sx, 0}, [A]);
                {false, true} -> contact(Grid, Cell, Line, T, {0, Sy}, [B]);
                {false, false} -> next(Grid, Box, Cell, {I + Sx, J + Sy}, S, {Tx + Ex, Ty + Ey}, E, Line, T, {Sx, Sy})
            end
    end.

next(Grid, Box, Cell, Next, S, T, E, Line, At, Normal) ->
    case look(Grid, Next, Box) of
        true -> contact(Grid, Cell, Line, At, Normal, [Next]);
        false -> walk(Grid, Box, Next, S, T, E, Line)
    end.

%% The contact is on an edge of the open cell Cell, where the line was.
%% The point goes a very short distance into that cell from each of its
%% edges: near a corner, a point on the edge can be in a blocked cell.
contact(#boids_grid{cell_size = Side, origin = {Ox, Oy}}, {I, J}, {From, To}, T, Normal, Blocked) ->
    {X, Y} = boids_vec:add(From, boids_vec:scale(boids_vec:sub(To, From), T)),
    Gap = Side * ?GAP,
    At = {within(X, Ox + I * Side, Side, Gap), within(Y, Oy + J * Side, Side, Gap)},
    {At, boids_vec:normalize(Normal), Blocked}.

within(P, Low, Side, Gap) -> min(max(P, Low + Gap), Low + Side - Gap).

%% True for a blocked cell. With a box, a cell outside the grid is the
%% cell at its place in the box.
look(Grid, Cell, none) ->
    blocked(Grid, Cell);
look(Grid, Cell, {Min, Max}) ->
    case inside(Grid, Cell) of
        true -> blocked(Grid, Cell);
        false -> blocked(Grid, cell(Grid, boids_vec:wrap(center(Grid, Cell), Min, Max)))
    end.

-doc #{equiv => nearest(Grid, Pos, none)}.
-spec nearest(grid(), vec()) -> vec() | none.
nearest(Grid, Pos) ->
    nearest(Grid, Pos, none).

-doc """
The walkable place nearest to `Pos`: `Pos` when it is walkable, or the
point of the nearest open cell that is the nearest to `Pos`, a very
short distance into that cell. A grid with no open cell gives `none`.
With `Box`, the sides of the box continue at the opposite sides.

A boid in a cell that became blocked (a door that closes) goes to this
place at its next step.
""".
-spec nearest(grid(), vec(), none | {vec(), vec()}) -> vec() | none.
nearest(#boids_grid{open = 0}, _Pos, _Box) ->
    none;
nearest(Grid = #boids_grid{cols = Cols, rows = Rows}, Pos, Box) ->
    Cell = {I, J} = cell(Grid, Pos),
    case look(Grid, Cell, Box) of
        false ->
            Pos;
        true ->
            %% With no box, the search starts at the cell of the grid that
            %% is the nearest to the position.
            Start =
                case Box of
                    none -> {min(max(I, 0), Cols - 1), min(max(J, 0), Rows - 1)};
                    _ -> Cell
                end,
            {Out, _} = spot(Grid, Pos, Start),
            rings(Grid, Box, Pos, Start, Out * Out, 0, max(Cols, Rows), {infinity, none})
    end.

%% The open cells at R cells from the start cell, ring after ring. Each
%% cell of the next ring is at R cells or more from the start cell, so
%% the search stops when the best place is nearer than that.
rings(Grid = #boids_grid{cell_size = Side}, Box, Pos, Start = {I, J}, Out2, R, Limit, Best0) ->
    Best = lists:min([Best0 | [spot(Grid, Pos, Cell) || Cell <- ring(I, J, R), not look(Grid, Cell, Box)]]),
    case Best of
        {Dist, Point} when Dist * Dist =< Out2 + (R * Side) * (R * Side); R >= Limit -> Point;
        _ -> rings(Grid, Box, Pos, Start, Out2, R + 1, Limit, Best)
    end.

%% The cells at R cells from the cell {I, J}: the sides of a square.
ring(I, J, 0) ->
    [{I, J}];
ring(I, J, R) ->
    [{I + D, J + S} || D <- lists:seq(-R, R), S <- [-R, R]] ++
        [{I + S, J + D} || D <- lists:seq(1 - R, R - 1), S <- [-R, R]].

%% The point of a cell that is the nearest to a position, a very short
%% distance into the cell, after its distance: {Dist, Point}. In the
%% order of the terms, each of them is before {infinity, none}.
spot(#boids_grid{cell_size = Side, origin = {Ox, Oy}}, Pos = {X, Y}, {I, J}) ->
    Gap = Side * ?GAP,
    Point = {within(X, Ox + I * Side, Side, Gap), within(Y, Oy + J * Side, Side, Gap)},
    {boids_vec:dist(Pos, Point), Point}.

-doc #{equiv => walls(Grid, Pos, Distance, none)}.
-spec walls(grid(), vec(), number()) -> [vec()].
walls(Grid, Pos, Distance) ->
    walls(Grid, Pos, Distance, none).

-doc """
The walls near a position: the points of the blocked cells that are the
nearest to `Pos`, at the distance `Distance` or nearer, with no point
two times. A cell outside the grid is blocked. With `Box`, the sides of
the box continue at the opposite sides.

A blocked cell gives its nearest point only when:

- no blocked cell beside it is nearer to `Pos`: a straight wall gives
  one point, the point of the wall nearest to `Pos`, and a cell in the
  middle of a thick wall gives none;
- the line from `Pos` to that point touches no other blocked cell
  first: a wall behind another wall gives none.

Thus a thick wall and a thin wall give the same points. A position in a
blocked cell gives no point.
""".
-spec walls(grid(), vec(), number(), none | {vec(), vec()}) -> [vec()].
walls(Grid, Pos = {X, Y}, Distance, Box) ->
    Own = {Bi, Bj} = cell(Grid, Pos),
    {I0, J0} = cell(Grid, {X - Distance, Y - Distance}),
    {I1, J1} = cell(Grid, {X + Distance, Y + Distance}),
    lists:usort([
        Point
     || not look(Grid, Own, Box),
        I <- lists:seq(I0, I1),
        J <- lists:seq(J0, J1),
        look(Grid, {I, J}, Box),
        {Dist, Point} <- [side(Grid, Pos, {I, J})],
        Dist =< Distance,
        %% The cells beside it, on its sides to the position.
        not nearer(Grid, Box, Pos, {I + sign(Bi - I), J}, Dist),
        not nearer(Grid, Box, Pos, {I, J + sign(Bj - J)}, Dist),
        sees(Grid, Box, Pos, {I, J})
    ]).

%% The point of a cell that is the nearest to a position, after its
%% distance.
side(#boids_grid{cell_size = Side, origin = {Ox, Oy}}, Pos = {X, Y}, {I, J}) ->
    Point = {clamp(X, Ox + I * Side, Side), clamp(Y, Oy + J * Side, Side)},
    {boids_vec:dist(Pos, Point), Point}.

%% True for a blocked cell that is nearer to the position than Dist.
nearer(Grid, Box, Pos, Cell, Dist) ->
    look(Grid, Cell, Box) andalso element(1, side(Grid, Pos, Cell)) < Dist.

%% True when the line from a position to the nearest point of a blocked
%% cell touches that cell first.
sees(Grid, Box, Pos, Cell) ->
    {_, To} = spot(Grid, Pos, Cell),
    Contact = trace(Grid, Pos, To, Box),
    is_tuple(Contact) andalso lists:member(Cell, element(3, Contact)).

sign(N) when N > 0 -> 1;
sign(N) when N < 0 -> -1;
sign(_N) -> 0.

%% The point of [Low, Low + Side] nearest to P.
clamp(P, Low, Side) -> min(max(P, Low), Low + Side).
