# The fields of directions

A field of directions (`boids_field`) tells each boid the direction of
the shortest way to a goal, around the walls of a grid. This document
tells how the library makes a field, why it makes it in this way, what
the measurements are, and what a field cannot do.

## What a field is for

Many boids with the same goal need the same answer: at each place, the
direction to the goal. A search of a way for each boid costs more with
each boid. A field costs the same for one boid and for 10,000 boids: it
has the answer for each cell of the grid, and all the boids read it.
Games use this for large crowds ("flow field pathfinding").

The parts are the same in all the sources (see "The sources"):

1. **The costs.** Each cell of a grid is blocked, or open with a cost
   (`boids_grid`).
2. **The values.** From the goals, the cost of the way to the nearest
   goal goes out to each cell.
3. **The directions.** Each cell gets the direction down the values.
4. **The read.** A boid mixes the directions of the cells around its
   position (`boids_field:direction/2`), and the rule `flow` makes a
   force of it.

## The values: the eikonal equation

The simple way to get the values is a search from cell to cell
(Dijkstra), with steps to the 8 cells around a cell. Its values are the
lengths of ways that have only 8 directions. In open land, such a way
is to 8 % longer than the straight line, and the directions down these
values are one of 8: all the boids go on the same 8 lines.

The library solves the eikonal equation instead: `|grad T| = cost`. `T`
is the cost of the way to the nearest goal, and the equation tells that
`T` grows by the cost of the cell for each unit of distance, in each
direction. On the grid, the value of a cell comes from the smaller
neighbor of each axis, `A` and `B`:

    (T - A)^2 + (T - B)^2 = Cost^2

When one of the two is too large for this (or is a wall), the value
comes from the other alone: `T = A + Cost`. This is the method of fast
marching (first order). The values are near the straight distances, so
the directions down the values are at each angle.

A value never comes from a larger value. Fast marching uses this: it
takes the cells in the order of their values, with a heap. A heap is
slow in Erlang, and the library does not use one:

- **Buckets.** A bucket has the cells with a value in one half of the
  least cost of the grid. The buckets go in their order. A cell that
  gets a smaller value goes in the bucket of that value again, so the
  values come to the solution of the equation: the result is the same
  as with a heap.
- **An array that a function can change.** The values are integers in an
  `atomics` (a cost of 1 is 65,536). The costs are in a tuple. The two
  have one more cell on each side of the grid, so the code has no test
  of the sides.
- **A neighbor with a smaller value is not calculated again.**

### The start

The equation has its largest error at a goal, where the values go out
in all the directions from one point: the first cell across a corner
gets 1.71, and the straight distance is 1.41. But near a goal, most
values are known with no equation. Where the straight line from a cell
to the goal is in open cells of one cost, the value is the distance
multiplied by that cost. The cells at 8 cells or less from a goal (the
option `exact`), with such a line, start with that value, and with the
direction straight to the goal. A cell has such a line when all the
cells of the rectangle between it and the goal are open with the cost
of the goal.

With many goals, the start is smaller: its cells are 16,384 at most for
all the goals.

## The directions

- A cell that kept its value of the start goes straight to its goal.
- Each other cell goes down the values: on each axis, the slope to the
  smaller neighbor (when it is smaller than the cell). These are the
  neighbors that gave the cell its value.
- A blocked cell has no value. Thus a direction does not go into a
  wall.
- A direction between two axes goes across a corner of the cell. When
  the cell across that corner is blocked, the direction goes along one
  axis. The equation uses only the 4 cells beside a cell, so a way
  between two blocked cells that touch at a corner does not exist.

## The read

`boids_field:direction/2` gives the direction at a position:

- **In open land** (the 4 cells around the position are open), the mean
  of their directions, each with a weight for its distance. The
  direction is smooth from cell to cell.
- **Near a wall** (one of the 4 cells is blocked, or is across the
  corner of a blocked cell), the direction from the position to the
  center of the next cell of the way.

The second rule is necessary for boids, which have a velocity. The
shortest way goes around a corner with no distance from it. A boid that
follows it touches the corner, and a boid that comes fast goes into the
wall. The center of the next cell is half a cell from the walls, and a
boid that is not in the middle of a narrow way goes back to the middle.
In the example of the bridge (below), the boids of the mode `through`
went into the water in 1,667 steps without this rule, and in 0 steps
with it.

A position is not always in an open cell with a way:

- **In a blocked cell, and outside the grid,** the direction goes to the
  center of the nearest open cell that has a way to a goal. The
  function examines the cells at 3 cells or less on each axis (49
  cells). When none of them has a way, the direction is zero. A field
  does not stop a boid at a wall (see "The limits"), so a boid can be
  in a blocked cell: this direction brings it back to the way.
- **In an open cell with no way to a goal** (a room with no door), the
  direction is zero.
- **In the cell of a goal,** the direction is zero.

`boids_field:has_way/2` tells if a position is in an open cell with a
way.

`boids_field:distance/2` gives the value at a position: the mean of the
values of the cells around it that have a way. It is `infinity` in a
blocked cell, in an open cell with no way, and outside the grid.

`boids_field:path/2` goes down the field in steps of half a cell, and
gives the points where the way turns.

The rule `flow` reads the direction at the place where the boid will be
after the time `predict` (half a second). When that place has no way (a
wall, a place out of the grid) or is the goal, it reads the direction
at the position of the boid.

## The margin

The shortest way goes along the walls and around the corners with no
distance from them. That is bad for a crowd: the boids touch the walls,
and the boids of all the directions come to the same corners. The
option `margin` of `new/3` makes the cells near a wall cost more:

    boids_field:new(Grid, Goals, #{margin => [3, 2]})

The cost of an open cell at 1 cell from a wall is multiplied by 3, and
at 2 cells by 2. A way then keeps away from the walls where it has
room. Where it has no room (a door of one cell), it goes through as
before: each way through the door pays the same.

The decisions:

- **The distance to a wall is in 8 directions:** a cell that touches a
  blocked cell at a side or at a corner is at 1 cell. With 4
  directions, the cell across the corner of a wall is at 2 cells, and
  the ways go around a corner too near to it. The corners are the
  places where the streams meet, so they need the margin most.
- **The sides of the grid are walls.** A place outside the grid is
  blocked (`boids_grid:walkable/2`), and a boid with the option
  `walkable` cannot go there. Thus a way keeps the same distance from a
  side as from a wall.
- **The number multiplies the cost of the grid.** A cell of a swamp near
  a wall costs more than a cell of a road near a wall.
- **A goal cell near a wall keeps its margin.** The value of a goal is 0
  with each cost. Only the cells around the goal cost more, so a way
  comes to a goal at a wall from the open land, and not along the wall.
- **`distance/2` gives the cost with the margin.** It is then more than
  the length of the way. For the length of a way, use `path/2`.

The margin makes the ways longer. In the land of 100 x 100 cells of
the table of the time (10 % of the cells blocked, 361 starts), the ways
with `[3, 2]` are 4.5 % longer on average than with no margin (95 % of
them less than 11.5 % longer, the largest 27 %).

## The measurements

The computer: 4 virtual processors (Intel Xeon, 2.1 GHz), Erlang/OTP 29
with the JIT. The computer had other work during the measurements (a load of
2.6 to 3.7), so the times on a computer with no other work are smaller.

### The quality of the ways

Land of 64 x 64 cells, one goal, 300 starts. An agent follows the
direction of the field in steps of 0.2 of a cell. The table has how
much longer its way is than the shortest way: the mean, and the value
that 95 % of the ways are below. The shortest way is from a search in a
graph of the corners of the blocks that see each other.

| Field | Open land | 14 blocks | Rooms with doors |
|---|---|---|---|
| A search of 8 directions, the mean of 4 cells | +4.6 % (+7.7 %) | +5.1 % (+8.2 %) | +5.9 % (+7.7 %) |
| `boids_field:direction/2` | +0.01 % (+0.02 %) | +1.0 % (+3.2 %) | +1.7 % (+3.3 %) |
| `boids_field:path/2` | 0.0 % (+0.01 %) | +1.1 % (+3.5 %) | +1.9 % (+4.0 %) |

In open land, the angle between the direction and the straight line to
the goal (2,000 places at more than 2 cells from the goal): 0.4 degrees
(mean), 1.1 degrees (95 %), 2.5 degrees (largest). With a search of 8
directions: 21 degrees (mean), 44 degrees (largest).

No agent went into a wall, and each agent came to the goal.

### The distance

`distance/2` against the cost of the shortest way, at the 300 starts:

| Land | Mean | From | To |
|---|---|---|---|
| Open land | +0.7 % | 0.0 % | +1.3 % |
| 14 blocks | +2.5 % | -1.4 % | +7.8 % |
| Rooms with doors | +3.6 % | -1.1 % | +7.3 % |

The value is the solution of the equation on the grid, and not the
cost of the shortest way. Around a corner, it is some percent more. The
mean of 4 cells can make it 1 % less. A search of 8 directions gives 5
to 8 % more.

### The time

`boids_field:new/2`, one goal, 7 to 10 % of the cells blocked:

| Grid | Time | Size of the field |
|---|---|---|
| 200 x 200 cells | 38 to 48 ms | 234 KB |
| 500 x 500 cells | 0.30 to 0.35 s | 1.5 MB |
| 1,000 x 1,000 cells | 1.5 to 2.0 s | 5.9 MB |

For 200 x 200 cells, the calculation is 2.5 million reductions. The
same equation with a heap (`gb_sets`) took 160 ms in a first version,
and a search of 8 directions with a heap and a map took 90 ms.

The option `margin` adds work: with `[3, 2]`, the calculation is 2.9
million reductions for 200 x 200 cells (54 to 57 ms), and 0.38 to 0.43
s for 500 x 500 cells.

The time is in proportion to the number of the cells, and it does not
change much with the number of the goals. A test of the library counts
the reductions, which do not change with the other work of the
computer.

### The read

- One read of `direction/2` takes 0.3 microsecond.
- A field is two binaries: a float of 32 bits for the value of each
  cell, and two bytes for its direction. A binary is not copied from
  process to process.
- A boid keeps the field that it read, and reads it from the table of
  its world again only after a change (`boids_space:named/3`,
  `specs/Kept.tla`). With 1,000 boids and a field of 200 x 200 cells, a
  step has the same number of garbage collections with the field and
  with a vector as the option `field`, and the time of a step is the
  same in the limits of the measurement.
- In a world on several nodes, a field is a fact of the world, as a
  grid: `boids:set_field/3` sends it to each node (234 KB for 200 x 200
  cells), and a node that comes later gets it (`specs/Facts.tla`). A
  boid that moves to another node finds the field there.

### The example of the bridge

`examples/bridge.exs` has 30 boids that go across a river on a bridge,
there and back, for 120 seconds. Before this module, the script had a
search of 8 directions of its own. The script now makes its two fields
with `margin => [3, 2]`.

The scene is chaotic: a change of 0.000000001 in the start of the boids
gives other numbers. So the table has the trips as the mean of 10 runs
with different random numbers. In brackets is the spread of one run
(the standard deviation). A difference between two means that is
smaller than the spread of one run tells nothing.

| Mode | Bridge | Search of the script | `boids_field`, no margin | `boids_field`, `margin => [3, 2]` |
|---|---|---|---|---|
| `through` | 1 cell | 210 | 210 | 210 |
| `through` | 2 cells | 210 | 210 | 210 |
| `spacing` | 1 cell | 62 (5) | 70 (5) | 76 (9) |
| `spacing` | 2 cells | 148 (4) | 140 (4) | 142 (1) |
| `blocked` | 1 cell | 22 (4) | 29 (7) | 27 (6) |
| `blocked` | 2 cells | 134 (6) | 112 (7) | 130 (6) |
| `ways` | 1 cell | 179 (3) | 178 (3) | 185 (1) |
| `ways` | 2 cells | 187 (2) | 189 (2) | 188 (1) |
| `walkable` | 1 cell | 79 (12) | 89 (6) | 103 (10) |
| `walkable` | 2 cells | 146 (2) | 131 (6) | 143 (3) |
| `walls` | 1 cell | 70 (10) | 87 (8) | 92 (8) |
| `walls` | 2 cells | 136 (6) | 124 (3) | 137 (3) |

(The mode `through` has 3 runs. Its boids go through each other, so
each run has the same trips.)

The shortest way between the two ends of the trip is one line, around
one corner at each end of the bridge. With a field and no margin, the
boids of the two directions go on that same line, and they are in the
way of each other: on the bridge of 2 cells, the modes `blocked`,
`walkable` and `walls` have 9 to 16 % fewer trips than with the search
of the script. A search of 8 directions has many ways with the same
cost, so its boids use all the width of the bridge.

The margin moves the ways away from the corners of the water. On the
bridge of 2 cells, the trips are then the same as with the search of
the script. On the bridge of 1 cell, the modes with a hard limit that
lets a boid slide (`walkable`, `walls`) have 30 % more trips than with
the search of the script. See "The limits".

The mode `spacing` has no limit: `separation` pushes boids into the
water. The steps that a boid ended in the water, of 36,000 (the mean of
10 runs):

| Bridge | Search of the script | `boids_field`, no margin | `boids_field`, `margin => [3, 2]` |
|---|---|---|---|
| 1 cell | 9,253 | 8,412 | 7,611 |
| 2 cells | 182 | 930 | 401 |

In the water, the direction of the field leads a boid back to the
nearest land. A first version of the module had no direction in a
blocked cell. Its boids then kept their velocity in the water: on the
bridge of 2 cells, 1,757 steps ended in the water (3 runs), and on the
bridge of 1 cell some boids went across the river with no bridge.

The search of the script led a boid in the water to the open cell
beside it that was nearest to the goal, and its boids were in the water
for fewer steps (182 against 401). The field does not do that: such a
rule pulls a boid through a thin wall to the side of the goal. The
nearest open cell is the cell that the boid came from in most cases.

## The limits

- **Two dimensions.** A field is for a grid, and a grid has two
  dimensions. A boid with three dimensions cannot have a field of the
  world.
- **A step into a cell costs the cost of that cell.** A step of
  `boids_grid:steps/2` costs the mean of the costs of its two cells.
  The cost of a way across a region of high cost is the same with the
  two. In the first cell of such a region, the value of the field is
  more: by half of the difference of the two costs.
- **No way across a corner between two cells of high cost.** The
  equation uses the 4 cells beside a cell. A way across the point where
  4 cells meet goes through one of the 2 cells beside it, and pays its
  cost. A search of 8 directions goes across that point for the cost of
  its two ends.
- **Costs that change much from cell to cell.** This is the result of
  the limit before. The equation is for costs that change slowly, as
  the costs of regions do: a swamp, a road, the margin. With two
  regions of the costs 1 and 9, the values of the field are 0.92 to
  1.27 times the costs of a search of 8 directions (1.0 on average).
  On a checkerboard, where each cell of high cost has cells of low cost
  at its 4 corners, a search of 8 directions goes from corner to corner
  and never pays the high cost. The field cannot do that, and its
  values are much more:

  | Costs of the checkerboard | Value of the field / cost of a search of 8 directions |
  |---|---|
  | 1 and 2 | 1.3 (mean), 1.7 (largest) |
  | 1 and 3 | 1.7 (mean), 2.3 (largest) |
  | 1 and 5 | 2.4 (mean), 3.4 (largest) |
  | 1 and 9 | 3.8 (mean), 5.7 (largest) |

  The directions go down these values, so the ways are not the ways of
  the least cost there. Give costs to regions of some cells, not to
  single cells.
- **The boids of two directions go on the same line** (see the example
  of the bridge). A field does not know where the boids are: it has no
  cost for a place with many boids. The option `margin` moves the line
  away from the walls, but it is one line for the two directions. Use
  the rules for neighbors (`separation`, `dodge`).
- **The margin changes which way costs the least.** With `[3, 2]`, a
  cell of a way that is 1 or 2 cells wide costs 3 times the cost of a
  cell in open land. A way around it in open land that is less than 3
  times as long then costs less, and the field takes that way. Use
  smaller numbers when the map has long narrow ways.
- **A field does not limit a boid.** The direction is a force as the
  other forces are. A boid that another force pushes into a wall is in
  the wall. From there, the direction leads it out, but only when an
  open cell with a way is at 3 cells or less. Use the option `walkable`
  with the same grid: it is the hard limit.
- **A change of the grid needs a new field.** The library does not
  repair a field after a small change: `new/2` calculates all of it.
- **Very large maps.** A field of 1,000 x 1,000 cells takes more than
  one second, and each goal needs its field. Games with such maps cut
  the map into tiles, search a graph of the doors between the tiles,
  and make a field only for the tiles of a way (see the first source).
  The library does not have this.
- **One process.** `new/2` runs in the process that calls it, on one
  processor.

## The sources

- Elijah Emerson, "Crowd Pathfinding and Steering Using Flow Field
  Tiles", Game AI Pro, chapter 23: the three fields (cost,
  integration, flow) of Supreme Commander 2, the line of sight near the
  goal, the tiles, and a cost gradient near the walls.
  <https://www.gameaipro.com/GameAIPro/GameAIPro_Chapter23_Crowd_Pathfinding_and_Steering_Using_Flow_Field_Tiles.pdf>
- Adrien Treuille, Seth Cooper and Zoran Popović, "Continuum Crowds",
  ACM Transactions on Graphics 25(3), 2006: the eikonal equation for a
  crowd, with a cost for the places where the crowd is.
  <https://grail.cs.washington.edu/projects/crowd-flows/78-treuille.pdf>
- J. A. Sethian, "A fast marching level set method for monotonically
  advancing fronts", Proceedings of the National Academy of Sciences
  93(4), 1996: fast marching.
- Javier V. Gómez, David Álvarez, Santiago Garrido and Luis Moreno,
  "Fast Methods for Eikonal Equations: an Experimental Survey", 2015:
  the methods with no heap. <https://arxiv.org/abs/1506.03771>
- Amit Patel, "Flow Field Pathfinding for Tower Defense", Red Blob
  Games. <https://www.redblobgames.com/pathfinding/tower-defense/>
