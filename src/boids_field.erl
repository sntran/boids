-module(boids_field).
-moduledoc """
A field of directions: for each place of a grid, the direction of the
shortest way to a goal, and what that way costs. All the boids that go
to the same goals read one field, so the cost of a field does not
change with the number of the boids.

```erlang
Grid = boids_grid:from_rows([
    "..........",
    "....#.....",
    "....#.....",
    "....#....."
], #{}),
Field = boids_field:new(Grid, [{8, 3}]),
%% The way from the left goes up, around the wall.
{_, Dy} = boids_field:direction(Field, {2.5, 3.5}),
true = Dy < 0,
{+0.0, +0.0} = boids_field:direction(Field, {8.5, 3.5}),
Cost = boids_field:distance(Field, {2.5, 3.5}),
true = Cost > 6.0.
```

A world keeps fields by name (`boids:set_field/3`), and the rule `flow`
reads them: `{flow, 1.0, #{field => {named, Name}}}`.

## How a field is made

`new/2` solves the eikonal equation on the grid: the cost to the goals
grows from cell to cell by the cost of the cell, in each direction, not
only in the 8 directions from a cell to the cells around it. Thus the
directions are at each angle, and boids do not all go on the same 8
lines. `docs/fields.md` has the algorithm, its measurements and its
sources.

- The cost of a cell is the cost of the grid (`boids_grid`): a way goes
  around a region with a high cost when that costs less.
- A way does not go into a blocked cell, and it does not go between two
  blocked cells that touch at a corner.
- With more than one goal, each place has the way to the goal that
  costs the least.

`new/2` has no process and no state: call it in a process of your own
when the grid is large, and give the result to `boids:set_field/3`.

## The margin

The shortest way goes around a corner with no distance from it, and
along a wall. Boids that follow it touch the walls, and the boids of
all the directions come to the same corners. With the option `margin`,
the cells near a wall cost more, so a way keeps away from the walls
where it has room, and goes near a wall only where it must: through a
door of one cell, the way is the same.

- The distance to a wall is in cells, in 8 directions: a cell that
  touches a blocked cell at a side or at a corner is at 1 cell. So the
  cell across the corner of a wall costs more too, and a way goes
  around a corner at a distance.
- The sides of the grid are walls for the margin, because a place
  outside the grid is blocked (`boids_grid`).
- The cost of the grid is multiplied: a cell with the cost 2 at 1 cell
  from a wall, with `[3, 2]`, has the cost 6.
- A goal cell near a wall has the margin too. The value of a goal is 0
  with each cost, so only the cells around it change.
- `distance/2` then gives the cost with the margin, which is more than
  the length of the way.

## What the functions give

- `direction/2`: a vector of length 1 down the costs, or zero at a goal
  and in a place with no way to a goal. In a blocked cell, it is the
  direction out of the wall.
- `distance/2`: the cost of the way to the nearest goal, or `infinity`.
  A way across one cell with the cost 1 costs 1: with costs of 1, the
  cost is the length of the way in cells, so multiply it by
  `boids_grid:cell_size/1` for a length. It is not exactly the cost of
  the shortest way: on a grid, it is some percent more
  (`docs/fields.md`).
- `path/2`: the points of the way from a position to a goal.

The data of a field are two binaries, one with the costs and one with
the directions. A binary of more than 64 bytes is not copied from
process to process: all the processes with the same field share one
copy.

**A field has two dimensions**, as a grid has.
""".

-export([new/2, new/3, is_field/1]).
-export([size/1, cell_size/1, origin/1, goals/1]).
-export([direction/2, distance/2, has_way/2, path/2]).

-export_type([field/0]).

-record(boids_field, {
    cell_size :: float(),
    origin :: {float(), float()},
    cols :: pos_integer(),
    rows :: pos_integer(),
    goals :: [boids_grid:cell()],
    %% The least cost of an open cell of the grid.
    least :: float(),
    %% The cost to the nearest goal for each cell, row after row, as a
    %% float of 32 bits. A cell with no way has -1.0.
    costs :: binary(),
    %% The direction of each cell: two signed bytes, a vector of the
    %% length 127. A goal has 0 and 0. A blocked cell has -128 and
    %% -128, and an open cell with no way has -128 and 0.
    dirs :: binary()
}).

-opaque field() :: #boids_field{}.
-type cell() :: boids_grid:cell().
-type vec() :: {number(), number()}.

%% The calculation has integers: a cost of 1 (the least cost of the
%% grid) is 2^16. The values are in an atomics, which is the only array
%% of Erlang that a function can change in constant time.
-define(ONE, 65536).
%% The value of a cell with no way (yet).
-define(FAR, (1 bsl 59)).
%% A bucket has the cells with a value in one half of the least cost.
-define(SHIFT, 15).
%% A change of a value that is smaller than this is not a change.
-define(SAME, 16).
%% The largest number of the cells of the start, for all the goals.
-define(START, 16384).
%% The number of buckets that `next/3` examines one after the other.
-define(NEAR, 64).

%% The first byte of the direction of a cell with no way, in the
%% binary: a blocked cell has it two times.
-define(NONE, -128).
%% The largest distance, in cells on each axis, from a blocked cell to
%% the cell where `direction/2` leads a boid out.
-define(OUT, 3).
%% The length of a step of `path/2`, in cells.
-define(STEP, 0.5).

-doc #{equiv => new(Grid, Goals, #{})}.
-spec new(boids_grid:grid(), [cell()]) -> field().
new(Grid, Goals) ->
    new(Grid, Goals, #{}).

-doc """
Make the field of the ways to the goals: a list of one or more open
cells of the grid. The options (a map, or a list of `{Key, Value}`):

| Option | Default | Description |
|---|---|---|
| `exact` | `8` | The cells at this number of cells or less from a goal, on each axis, start with the exact distance to it, when the straight line to the goal is in open cells of one cost. With `0`, only the goal has its exact cost. With many goals, the number is smaller: the cells of the start are 16,384 at most. |
| `margin` | `[]` | A higher cost for the open cells near a wall: a list of numbers from 1. With `[3, 2]`, the cost of a cell at 1 cell from a blocked cell is multiplied by 3, and at 2 cells by 2. See "The margin". |

A goal that is not an open cell of the grid gives the error
`{bad_option, {goals, Goal}}`. A value that is not a grid gives the
error `badarg`.

The time is in proportion to the number of the cells. A grid of 200 x
200 cells takes about 40 milliseconds, and a grid of 1,000 x 1,000
cells more than 1 second (`docs/fields.md`).
""".
-spec new(boids_grid:grid(), [cell()], map() | [{atom(), term()}]) -> field().
new(Grid, Goals0, Opts0) ->
    boids_grid:is_grid(Grid) orelse error(badarg),
    Opts = boids_boid:to_map(Opts0),
    [error({bad_option, {Key, Value}}) || Key := Value <- Opts, Key =/= exact, Key =/= margin],
    Exact = maps:get(exact, Opts, 8),
    is_integer(Exact) andalso Exact >= 0 orelse error({bad_option, {exact, Exact}}),
    Margin = maps:get(margin, Opts, []),
    is_list(Margin) andalso lists:all(fun(Factor) -> boids_vec:is_size(Factor) andalso Factor >= 1 end, Margin) orelse
        error({bad_option, {margin, Margin}}),
    is_list(Goals0) andalso Goals0 =/= [] orelse error({bad_option, {goals, Goals0}}),
    [error({bad_option, {goals, Goal}}) || Goal <- Goals0, not open(Grid, Goal)],
    Goals = lists:usort(Goals0),
    {Cols, Rows} = boids_grid:size(Grid),
    Width = Cols + 2,
    {Costs0, Least} = costs(Grid, Cols),
    Costs = margin(Costs0, Margin, Width),
    Values = atomics:new(Width * (Rows + 2), [{signed, true}]),
    fill(Values, Width * (Rows + 2)),
    Reach = min(Exact, (trunc(math:sqrt(?START div length(Goals))) - 1) div 2),
    Start = lists:foldl(
        fun nearest/2,
        #{},
        [Cell || {I, J} <- Goals, Cell <- sight((J + 1) * Width + I + 2, Reach, Costs, Width)]
    ),
    march(0, maps:fold(fun(Ix, Cell, Buckets) -> start(Ix, Cell, Buckets, Values) end, #{}, Start), Values, Costs, Width),
    %% The largest value of the start: a cell with a larger value is
    %% not a cell of the start.
    Top = lists:max([Value || {Value, _To} <- maps:values(Start)]),
    {CostsOut, DirsOut} = cells(Width + 2, Cols, Rows, Cols, {Values, Costs, Width, Start, Top, Least}, <<>>, <<>>),
    #boids_field{
        cell_size = boids_grid:cell_size(Grid),
        origin = boids_grid:origin(Grid),
        cols = Cols,
        rows = Rows,
        goals = Goals,
        least = Least,
        costs = CostsOut,
        dirs = DirsOut
    }.

open(Grid, Cell = {I, J}) when is_integer(I), is_integer(J) -> not boids_grid:blocked(Grid, Cell);
open(_Grid, _Cell) -> false.

%% The costs of the cells as a tuple of integers, with one more cell on
%% each side of the grid: a blocked cell and a cell of the border have
%% 0. A function reads a tuple in constant time, and the border removes
%% the test of the sides. The index of the cell {I, J} is
%% (J + 1) * (Cols + 2) + I + 2.
costs(Grid, Cols) ->
    Cells = boids_grid:costs(Grid),
    Least = lists:min([Cost || <<Cost:64/float>> <= Cells, Cost > 0]),
    Border = lists:duplicate(Cols + 2, 0),
    Size = Cols * 8,
    Rows = [[0 | [fixed(Cost, Least) || <<Cost:64/float>> <= Row]] ++ [0] || <<Row:Size/binary>> <= Cells],
    {list_to_tuple(lists:append([Border | Rows] ++ [Border])), Least}.

%% Most grids have one cost: that cost needs no calculation.
fixed(Least, Least) -> ?ONE;
fixed(Cost, Least) when Cost > 0 -> round(Cost / Least * ?ONE);
fixed(_Blocked, _Least) -> 0.

%% The costs with the option margin: the cost of an open cell near a
%% wall is multiplied by the number of its distance. The walls are the
%% cells with the cost 0: the blocked cells, and the border.
margin(Costs, [], _Width) ->
    Costs;
margin(Costs, Margin, Width) ->
    Walls = [Ix || Ix <- lists:seq(1, tuple_size(Costs)), element(Ix, Costs) =:= 0],
    Factors = layers(Walls, Margin, Costs, Width, #{}),
    list_to_tuple([
        round(Cost * maps:get(Ix, Factors, 1))
     || {Ix, Cost} <- lists:enumerate(tuple_to_list(Costs))
    ]).

%% The cells at one more cell from the walls: the open cells around the
%% cells of the last distance (in 8 directions) that have no number
%% yet. They get the next number of the margin. A step from a cell of
%% the border can come to another cell of the border, and to no open
%% cell that is not beside it.
layers(_From, [], _Costs, _Width, Factors) ->
    Factors;
layers(From, [Factor | Margin], Costs, Width, Factors) ->
    Next = lists:usort([
        To
     || Ix <- From,
        Step <- [-Width - 1, -Width, 1 - Width, -1, 1, Width - 1, Width, Width + 1],
        To <- [Ix + Step],
        To >= 1,
        To =< tuple_size(Costs),
        element(To, Costs) =/= 0,
        not is_map_key(To, Factors)
    ]),
    layers(Next, Margin, Costs, Width, maps:merge(Factors, maps:from_keys(Next, Factor))).

fill(_Values, 0) ->
    ok;
fill(Values, Ix) ->
    atomics:put(Values, Ix, ?FAR),
    fill(Values, Ix - 1).

%% The two binaries of a field, cell after cell and row after row: the
%% cost and the direction of each cell. Left is the number of the cells
%% of the row that stay, and Rows the number of the rows that stay. Two
%% cells of the border are between two rows.
cells(_Ix, 0, 1, _Cols, _Field, CostsOut, DirsOut) ->
    {CostsOut, DirsOut};
cells(Ix, 0, Rows, Cols, Field, CostsOut, DirsOut) ->
    cells(Ix + 2, Cols, Rows - 1, Cols, Field, CostsOut, DirsOut);
cells(Ix, Left, Rows, Cols, Field = {Values, Costs, Width, Start, Top, Least}, CostsOut, DirsOut) ->
    Value = atomics:get(Values, Ix),
    {Dx, Dy} = down(Ix, Value, Values, Costs, Width, Start, Top),
    cells(
        Ix + 1,
        Left - 1,
        Rows,
        Cols,
        Field,
        <<CostsOut/binary, (cost(Value, Least)):32/float>>,
        <<DirsOut/binary, Dx:8/signed, Dy:8/signed>>
    ).

%% The value of a cell as a cost of the grid.
cost(?FAR, _Least) -> -1.0;
cost(Value, Least) -> Value / ?ONE * Least.

%% --- The start: the cells near a goal ---------------------------------
%%
%% The equation has its largest error at a goal, where the costs go out
%% in all the directions from one point. Where the straight line from a
%% cell to a goal is in open cells of one cost, the cost of the cell is
%% known: the distance multiplied by that cost. The cells near a goal
%% with such a line start with it.

%% The cells of the start of one goal: [{Ix, {Value, To}}], with the
%% value of the cell, and the direction from the cell to the goal.
sight(Goal, Reach, Costs, Width) ->
    Cost = element(Goal, Costs),
    [
        {Goal + Dj * Width + Di, {round(Cost * math:sqrt(Di * Di + Dj * Dj)), {-Di, -Dj}}}
     || Sx <- [-1, 1], Sy <- [-1, 1], {Di, Dj} <- quarter(Goal, Cost, Sx, Sy, 0, Reach, Reach, Costs, Width)
    ].

%% One quarter of the square around a goal, row after row from the
%% goal: the cells {Di, Dj} where all the cells of the rectangle between
%% the cell and the goal have the cost of the goal. The straight line to
%% the goal is in that rectangle. A cell of the border has the cost 0,
%% so the rows and the cells stop at the sides of the grid.
quarter(_Row, _Cost, _Sx, _Sy, Dj, _Far, Reach, _Costs, _Width) when Dj > Reach ->
    [];
quarter(Row, Cost, Sx, Sy, Dj, Far, Reach, Costs, Width) ->
    case run(Row, Cost, Sx, 0, Far, Costs) of
        0 ->
            [];
        Count ->
            [{Sx * Di, Sy * Dj} || Di <- lists:seq(0, Count - 1)] ++
                quarter(Row + Sy * Width, Cost, Sx, Sy, Dj + 1, Count - 1, Reach, Costs, Width)
    end.

%% The number of the cells of a row with the cost of the goal, from the
%% column of the goal, to the cell Far.
run(Row, Cost, Sx, Di, Far, Costs) when Di =< Far, element(Row + Sx * Di, Costs) =:= Cost ->
    run(Row, Cost, Sx, Di + 1, Far, Costs);
run(_Row, _Cost, _Sx, Di, _Far, _Costs) ->
    Di.

%% Two goals can give a value to the same cell: the smaller value stays.
nearest({Ix, Cell}, Start) ->
    case Start of
        #{Ix := Other} when Other =< Cell -> Start;
        _ -> Start#{Ix => Cell}
    end.

start(Ix, {Value, _To}, Buckets, Values) ->
    atomics:put(Values, Ix, Value),
    push(Value bsr ?SHIFT, Ix, Buckets).

%% --- The march: the values go out from the goals -----------------------
%%
%% The equation is |grad T| = cost. The value of a cell comes from the
%% smaller neighbor of each axis (solve/4), so a value never comes from
%% a larger value, as in the algorithm of Dijkstra. A heap is slow in
%% Erlang. A bucket has the cells with a value in one half of the least
%% cost, and the buckets go in their order. A cell that gets a smaller
%% value goes in the bucket of that value again: the values come to the
%% solution of the equation, the same as fast marching gives.

march(Key, Buckets, Values, Costs, Width) ->
    case Buckets of
        #{Key := Cells} ->
            %% A cell can go in this bucket during the work: do the
            %% bucket again.
            Rest = relax(lists:reverse(Cells), Key, maps:remove(Key, Buckets), Values, Costs, Width),
            march(Key, Rest, Values, Costs, Width);
        _ when map_size(Buckets) =:= 0 ->
            ok;
        _ ->
            march(next(Key + 1, Buckets, ?NEAR), Buckets, Values, Costs, Width)
    end.

%% The next bucket with cells. Most times it is one of the buckets after
%% this one. With costs that are very different, the next bucket can be
%% far: then it is the bucket with the least key.
next(Key, Buckets, _Tries) when is_map_key(Key, Buckets) -> Key;
next(_Key, Buckets, 0) -> lists:min(maps:keys(Buckets));
next(Key, Buckets, Tries) -> next(Key + 1, Buckets, Tries - 1).

relax([Ix | Cells], Key, Buckets0, Values, Costs, Width) ->
    case atomics:get(Values, Ix) of
        Value when Value bsr ?SHIFT =:= Key ->
            Buckets1 = update(Value, Ix + 1, Buckets0, Values, Costs, Width),
            Buckets2 = update(Value, Ix - 1, Buckets1, Values, Costs, Width),
            Buckets3 = update(Value, Ix + Width, Buckets2, Values, Costs, Width),
            Buckets4 = update(Value, Ix - Width, Buckets3, Values, Costs, Width),
            relax(Cells, Key, Buckets4, Values, Costs, Width);
        _Smaller ->
            %% The cell got a smaller value after: it is in the bucket
            %% of that value.
            relax(Cells, Key, Buckets0, Values, Costs, Width)
    end;
relax([], _Key, Buckets, _Values, _Costs, _Width) ->
    Buckets.

%% Calculate the value of a cell beside a cell with the value From. A
%% cell with a value that is not larger than From gets nothing from it.
update(From, Ix, Buckets, Values, Costs, Width) ->
    case element(Ix, Costs) of
        %% A blocked cell.
        0 ->
            Buckets;
        Cost ->
            case atomics:get(Values, Ix) of
                Old when Old =< From -> Buckets;
                Old -> lower(Old, solve(Ix, Cost, Values, Width), Ix, Buckets, Values)
            end
    end.

lower(Old, New, _Ix, Buckets, _Values) when Old - New < ?SAME ->
    Buckets;
lower(_Old, New, Ix, Buckets, Values) ->
    atomics:put(Values, Ix, New),
    push(New bsr ?SHIFT, Ix, Buckets).

push(Key, Ix, Buckets) ->
    case Buckets of
        #{Key := Cells} -> Buckets#{Key := [Ix | Cells]};
        _ -> Buckets#{Key => [Ix]}
    end.

%% The value of a cell from the smaller neighbor of each axis, A and B
%% (A is the smaller of the two): the solution T of
%% (T - A)^2 + (T - B)^2 = Cost^2. When B is too large for that, the
%% value comes from A alone: A + Cost.
solve(Ix, Cost, Values, Width) ->
    X = min(atomics:get(Values, Ix - 1), atomics:get(Values, Ix + 1)),
    Y = min(atomics:get(Values, Ix - Width), atomics:get(Values, Ix + Width)),
    A = min(X, Y),
    case max(X, Y) - A of
        Gap when Gap >= Cost -> A + Cost;
        Gap -> A + (Gap + trunc(math:sqrt(2.0 * Cost * Cost - 1.0 * Gap * Gap))) div 2
    end.

%% --- The directions ---------------------------------------------------

%% The direction of a cell, as it is in the binary.
%%
%% A cell that has its value of the start goes straight to its goal.
%% Each other cell goes down the values: on each axis, the slope to the
%% smaller neighbor, when it is smaller than the cell. These are the
%% neighbors that gave the cell its value (solve/4). A blocked cell has
%% no value, so a direction does not go into a wall.
down(Ix, ?FAR, _Values, Costs, _Width, _Start, _Top) when element(Ix, Costs) =:= 0 ->
    {?NONE, ?NONE};
down(_Ix, ?FAR, _Values, _Costs, _Width, _Start, _Top) ->
    {?NONE, 0};
down(_Ix, 0, _Values, _Costs, _Width, _Start, _Top) ->
    {0, 0};
down(Ix, Value, Values, Costs, Width, Start, Top) ->
    case Value =< Top andalso Start of
        #{Ix := {Value, To}} ->
            bytes(To);
        _ ->
            Gx = slope(Value, atomics:get(Values, Ix - 1), atomics:get(Values, Ix + 1)),
            Gy = slope(Value, atomics:get(Values, Ix - Width), atomics:get(Values, Ix + Width)),
            bytes(corner(Gx, Gy, Ix, Costs, Width))
    end.

%% A direction as two signed bytes: a vector of the length 127.
bytes({Gx, Gy}) ->
    Length = math:sqrt(Gx * Gx + Gy * Gy),
    {round(127 * Gx / Length), round(127 * Gy / Length)}.

%% The slope of one axis: more than 0 when the way is to the neighbor
%% More (the next cell of the axis), less than 0 to the neighbor Less.
slope(Value, Less, More) when Less =< More, Less < Value -> Less - Value;
slope(Value, _Less, More) when More < Value -> Value - More;
slope(_Value, _Less, _More) -> 0.

%% A direction between two axes goes across the corner of the cell at
%% that side. When that cell is blocked, the direction goes along the
%% axis with the larger slope: a way does not cut the corner of a
%% blocked cell.
corner(Gx, Gy, Ix, Costs, Width) when Gx =/= 0, Gy =/= 0 ->
    case element(Ix + sign(Gx) + sign(Gy) * Width, Costs) of
        0 when abs(Gx) >= abs(Gy) -> {Gx, 0};
        0 -> {0, Gy};
        _Open -> {Gx, Gy}
    end;
corner(Gx, Gy, _Ix, _Costs, _Width) ->
    {Gx, Gy}.

sign(N) when N > 0 -> 1;
sign(_N) -> -1.

%% --- What a field is ----------------------------------------------------

-doc "True for a field of this module.".
-spec is_field(term()) -> boolean().
is_field(Term) -> is_record(Term, boids_field).

-doc "The number of cells: `{Columns, Rows}`.".
-spec size(field()) -> {pos_integer(), pos_integer()}.
size(#boids_field{cols = Cols, rows = Rows}) -> {Cols, Rows}.

-doc "The side of a cell.".
-spec cell_size(field()) -> float().
cell_size(#boids_field{cell_size = Side}) -> Side.

-doc "The corner of the cell `{0, 0}`.".
-spec origin(field()) -> {float(), float()}.
origin(#boids_field{origin = Origin}) -> Origin.

-doc "The goals of the field: its cells, in their order.".
-spec goals(field()) -> [cell()].
goals(#boids_field{goals = Goals}) -> Goals.

%% --- The reads ----------------------------------------------------------

-doc """
The direction of the way to the nearest goal at a position: a vector of
length 1, or zero. What it is in each kind of place:

| The position is in | The direction |
|---|---|
| the cell of a goal | Zero: the boid is there. |
| an open cell with a way to a goal | The direction of the way (see below). |
| an open cell with no way to a goal | Zero. |
| a blocked cell | To the center of the nearest open cell with a way to a goal, at 3 cells or less on each axis. Zero when there is no such cell. |
| a place outside the grid | The same as in a blocked cell. |

In an open cell with a way:

- **In open land,** the direction is smooth from cell to cell: it is the
  mean of the directions of the 4 cells around the position, each with
  a weight for its distance.
- **Near a wall** (one of these 4 cells is blocked, or is across the
  corner of a blocked cell), the direction is from the position to the
  center of the next cell of the way. A boid thus keeps half a cell
  from a wall where it can, goes around a corner and not across it, and
  stays in the middle of a narrow way. A move in the direction, to that
  center, does not go into a blocked cell.

A field does not stop a boid at a wall: only the option `walkable` of a
boid does that. A boid with no such limit that other forces push into a
blocked cell, or out of the grid, gets the direction out of it, so it
comes back to the way.
""".
-spec direction(field(), vec()) -> {float(), float()}.
direction(Field = #boids_field{cell_size = Side, origin = {Ox, Oy}}, {X, Y}) ->
    Gx = (X - Ox) / Side,
    Gy = (Y - Oy) / Side,
    I = floor(Gx),
    J = floor(Gy),
    case vector(Field, I, J) of
        wall ->
            out(Field, I, J, Gx, Gy);
        none ->
            {0.0, 0.0};
        {0, 0} ->
            {0.0, 0.0};
        Own ->
            %% The cells beside the cell of the position, on the sides
            %% of the position: one on each axis, and the cell across
            %% the corner. Ax and Ay are their weights, from 0 to 0.5.
            {Si, Ax} = beside(Gx - I),
            {Sj, Ay} = beside(Gy - J),
            Beside = vector(Field, I + Si, J),
            Below = vector(Field, I, J + Sj),
            case across(Beside, Below, vector(Field, I + Si, J + Sj)) of
                none ->
                    to_center(Own, Gx - I, Gy - J);
                Across ->
                    mean(Own, Beside, Below, Across, Ax, Ay)
            end
    end.

%% The mean of the directions of 4 cells, with the weights of the cells
%% beside (Ax and Ay), as a vector of length 1. Between two cells with
%% opposite directions (two goals), the mean can be zero: then the
%% direction is that of the cell of the position.
mean(Own = {Ox, Oy}, {Bx, By}, {Lx, Ly}, {Cx, Cy}, Ax, Ay) ->
    Sx = (Ox * (1 - Ax) + Bx * Ax) * (1 - Ay) + (Lx * (1 - Ax) + Cx * Ax) * Ay,
    Sy = (Oy * (1 - Ax) + By * Ax) * (1 - Ay) + (Ly * (1 - Ax) + Cy * Ax) * Ay,
    case math:sqrt(Sx * Sx + Sy * Sy) of
        Length when Length > 0 -> {Sx / Length, Sy / Length};
        _ -> boids_vec:normalize(Own)
    end.

%% The side of a position in its cell on one axis (-1 or 1), and the
%% weight of the cell at that side.
beside(Part) when Part < 0.5 -> {-1, 0.5 - Part};
beside(Part) -> {1, Part - 0.5}.

%% The cell across the corner has a part only with the two cells beside
%% it open: a way does not cut the corner of a blocked cell. A cell with
%% no way is an atom (none or wall).
across(Beside, Below, _Across) when is_atom(Beside); is_atom(Below) -> none;
across(_Beside, _Below, wall) -> none;
across(_Beside, _Below, Across) -> Across.

%% The direction from a place in a blocked cell, or out of the grid, to
%% the center of the nearest cell with a way to a goal, at ?OUT cells or
%% less on each axis. Zero when there is no such cell.
out(Field, I, J, Gx, Gy) ->
    Cells = [
        {Dx * Dx + Dy * Dy, Dx, Dy}
     || Di <- lists:seq(-?OUT, ?OUT),
        Dj <- lists:seq(-?OUT, ?OUT),
        is_tuple(vector(Field, I + Di, J + Dj)),
        Dx <- [I + Di + 0.5 - Gx],
        Dy <- [J + Dj + 0.5 - Gy]
    ],
    case Cells of
        [] ->
            {0.0, 0.0};
        _ ->
            {Square, Dx, Dy} = lists:min(Cells),
            Length = math:sqrt(Square),
            {Dx / Length, Dy / Length}
    end.

%% The direction from a place in a cell (Px and Py, from 0 to 1) to the
%% center of the next cell of the way: the cell beside or across a
%% corner that the direction of the cell goes to. That cell is open, and
%% with a cell across a corner, the two cells beside it are open too
%% (corner/5).
to_center({Dx, Dy}, Px, Py) ->
    boids_vec:normalize({0.5 + toward(Dx) - Px, 0.5 + toward(Dy) - Py}).

%% One part of a direction as a step of cells: -1, 0 or 1. The limit is
%% the middle between an axis and the line across a corner (22.5
%% degrees).
toward(Part) when Part > 48 -> 1;
toward(Part) when Part < -48 -> -1;
toward(_Part) -> 0.

%% The direction of a cell as it is in the binary: a vector of the
%% length 127 for an open cell with a way (0 and 0 for a goal), none
%% for an open cell with no way, and wall for a blocked cell and for a
%% cell outside the grid.
vector(#boids_field{cols = Cols, rows = Rows, dirs = Dirs}, I, J) when I >= 0, I < Cols, J >= 0, J < Rows ->
    Offset = (J * Cols + I) * 2,
    case Dirs of
        <<_:Offset/binary, ?NONE:8/signed, ?NONE:8/signed, _/binary>> -> wall;
        <<_:Offset/binary, ?NONE:8/signed, _/binary>> -> none;
        <<_:Offset/binary, Dx:8/signed, Dy:8/signed, _/binary>> -> {Dx, Dy}
    end;
vector(_Field, _I, _J) ->
    wall.

-doc """
True when a position is in an open cell with a way to a goal (the cell
of a goal too): `distance/2` gives a number there. It is false in a
blocked cell, in an open cell with no way, and outside the grid.
""".
-spec has_way(field(), vec()) -> boolean().
has_way(Field = #boids_field{cell_size = Side, origin = {Ox, Oy}}, {X, Y}) ->
    is_tuple(vector(Field, floor((X - Ox) / Side), floor((Y - Oy) / Side))).

-doc """
The cost of the way from a position to the nearest goal, or `infinity`
in a blocked cell, in a place with no way to a goal, and outside the
grid. A way across one cell with the cost 1 costs 1 (see the
documentation of the module). The cost is the mean of the costs of the
cells around the position that have a way.
""".
-spec distance(field(), vec()) -> float() | infinity.
distance(Field = #boids_field{cell_size = Side, origin = {Ox, Oy}}, {X, Y}) ->
    Gx = (X - Ox) / Side,
    Gy = (Y - Oy) / Side,
    I = floor(Gx),
    J = floor(Gy),
    case value(Field, I, J) of
        none ->
            infinity;
        Own ->
            {Si, Ax} = beside(Gx - I),
            {Sj, Ay} = beside(Gy - J),
            Beside = value(Field, I + Si, J),
            Below = value(Field, I, J + Sj),
            Across = across(Beside, Below, value(Field, I + Si, J + Sj)),
            %% A cell with no way has no part: the mean is of the cells
            %% with a way, with their weights.
            {Sum1, Weight1} = weigh(Beside, Ax * (1 - Ay), Own * (1 - Ax) * (1 - Ay), (1 - Ax) * (1 - Ay)),
            {Sum2, Weight2} = weigh(Below, (1 - Ax) * Ay, Sum1, Weight1),
            {Sum, Weight} = weigh(Across, Ax * Ay, Sum2, Weight2),
            Sum / Weight
    end.

weigh(none, _Part, Sum, Weight) -> {Sum, Weight};
weigh(Value, Part, Sum, Weight) -> {Sum + Value * Part, Weight + Part}.

%% The cost of a cell to its goal, or none.
value(#boids_field{cols = Cols, rows = Rows, costs = Costs}, I, J) when I >= 0, I < Cols, J >= 0, J < Rows ->
    Offset = (J * Cols + I) * 4,
    case Costs of
        <<_:Offset/binary, Value:32/float, _/binary>> when Value >= 0 -> Value;
        _ -> none
    end;
value(_Field, _I, _J) ->
    none.

-doc """
The way from a position to its goal: a list of points, from the position
to the center of the cell of the goal. A place with no way gives `[]`.

The way goes down the field in steps of half a cell, and the points on
a straight part of it are not in the list: each point of the way is at
a tenth of a cell or less from the lines of the list. Use it for the
rule `follow`, for a picture, or to know the length of a way.
""".
-spec path(field(), vec()) -> [vec()].
path(Field = #boids_field{cell_size = Side, least = Least}, Pos = {X, Y}) ->
    case distance(Field, Pos) of
        infinity ->
            [];
        Cost ->
            Start = {float(X), float(Y)},
            Way = [Last | _] = walk(Field, Start, Cost, Least, [Start]),
            Down = [End | _] = descend(Field, cell(Field, Last), Way),
            %% The way ends at the center of the cell of the goal.
            Goal = center(Field, cell(Field, End)),
            straight(lists:reverse([Goal || Goal =/= End] ++ Down), Side / 10)
    end.

%% Go down the field in steps of half a cell, while each step makes the
%% cost smaller and the goal is not near. Each step makes the cost
%% smaller by a part of the least cost, so the steps have an end.
walk(Field = #boids_field{cell_size = Side}, Pos = {X, Y}, Cost, Least, Way) ->
    {Dx, Dy} = direction(Field, Pos),
    Next = {X + Dx * ?STEP * Side, Y + Dy * ?STEP * Side},
    case Cost > 1.5 * Least andalso distance(Field, Next) of
        Less when is_float(Less), Less =< Cost - Least / 20 -> walk(Field, Next, Less, Least, [Next | Way]);
        _ -> Way
    end.

%% From cell to cell, to the cell around with the least cost, to a
%% goal: the end of a way, where the steps of walk/5 stop.
descend(Field, {I, J}, Way) ->
    Around = [
        {Value, abs(Di) + abs(Dj), {I + Di, J + Dj}}
     || Di <- [-1, 0, 1],
        Dj <- [-1, 0, 1],
        Value <- [value(Field, I + Di, J + Dj)],
        Value =/= none,
        value(Field, I + Di, J) =/= none,
        value(Field, I, J + Dj) =/= none
    ],
    Own = value(Field, I, J),
    %% Of two cells with the same cost, the cell beside is before the
    %% cell across a corner.
    case lists:min(Around) of
        {Value, _Steps, Lower} when Value < Own -> descend(Field, Lower, [center(Field, Lower) | Way]);
        _ -> Way
    end.

cell(#boids_field{cell_size = Side, origin = {Ox, Oy}}, {X, Y}) ->
    {floor((X - Ox) / Side), floor((Y - Oy) / Side)}.

center(#boids_field{cell_size = Side, origin = {Ox, Oy}}, {I, J}) ->
    {Ox + (I + 0.5) * Side, Oy + (J + 0.5) * Side}.

%% Remove the points of a way that are on a straight part of it: the
%% points that stay are those that are farther than Far from the line
%% between two points that stay (the algorithm of Douglas and Peucker).
straight([First | Rest = [_, _ | _]], Far) ->
    Last = lists:last(Rest),
    Middle = lists:droplast(Rest),
    {Distance, Point} = lists:max([{off(Point, First, Last), Point} || Point <- Middle]),
    case Distance > Far of
        true ->
            {Before, [Point | After]} = lists:splitwith(fun(Other) -> Other =/= Point end, [First | Rest]),
            straight(Before ++ [Point], Far) ++ tl(straight([Point | After], Far));
        false ->
            [First, Last]
    end;
straight(Points, _Far) ->
    Points.

%% The distance from a point to the line from A to B. The two are not
%% the same point: the cost of a way is smaller at each of its points.
off(Point, A, B) ->
    Line = boids_vec:sub(B, A),
    To = boids_vec:sub(Point, A),
    Along = min(max(boids_vec:dot(To, Line) / boids_vec:norm2(Line), 0.0), 1.0),
    boids_vec:dist(To, boids_vec:scale(Line, Along)).
