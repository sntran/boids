# Changelog

## 0.1.0

The first version. It needs Erlang/OTP 29.

- A world, where boids are: a supervisor, a process that owns its
  tables, and one process for each boid (`boids:start_world/1`,
  `boids:child_spec/1`, `boids:add/2`, `boids:populate/3`).
- The behavior `gen_boid`: a boid is a process that senses, decides and
  acts on its own clock. A module of yours adds to each of these with a
  callback (`handle_sense/2`, `handle_decide/2`, `handle_act/1`), and
  answers messages (`handle_call/3`, `handle_cast/2`, `handle_info/2`).
  The boid is the state of the callbacks, with a key for your module.
- A boid can be a child of a supervisor of yours, which starts it again
  with its id (`gen_boid:start_link/3`, `gen_boid:child_spec/1`).
- The tables of a world in ETS, with a grid of cells as the index
  (`boids_space`). A box, sides that continue at the opposite sides
  (`wrap`), obstacles, and a scale of the time.
- The rules of a boid: `separation`, `alignment`, `cohesion`, `seek`,
  `flee`, `arrive`, `pursue`, `evade`, `wander`, `avoid`, `contain`,
  `follow`, `cruise`, `leader`, `dodge`, `flow`, `walls`, and a function
  of yours (`boids_boid`, `boids_steer`).
- The walls of a world: a grid with a name is a fact of the world
  (`boids:set_grid/3`, `boids:remove_grid/2`, `boids:grid/2`), and a
  boid with the option `walkable => {named, Name}` can be only in the
  open cells of that grid. The limit is in the movement of each step: a
  boid that goes into a blocked cell slides along the edge, and stops
  only in a corner. A door is a new grid for the same name, and a boid
  in a cell that became blocked goes to the nearest walkable place at
  its next step. `boids:plan/3` and `boids:advance/3` obey the limit,
  and `boids:populate/3` puts boids only in walkable places. The rule
  `walls` moves a boid away from a wall before it touches it. In a
  world on several nodes, a grid is on all the nodes, as the other
  facts of the world.
- The ways of a world: a field of directions with a name is a fact of
  the world (`boids:set_field/3`, `boids:remove_field/2`,
  `boids:field/2`), and the rule `flow` reads it: `{flow, Weight, #{field
  => {named, Name}}}`. One field leads all the boids that go to the
  same goals. A new field for the same name changes the ways from the
  next step of each boid. A boid with three dimensions cannot have a
  field of the world. In a world on several nodes, a field is on all
  the nodes, as the other facts of the world.
- A field of directions from a grid (`boids_field`): `new/2` makes it
  for one goal cell or more, with the costs of the cells of the grid.
  `direction/2` gives the direction of the shortest way at a position,
  `distance/2` the cost of that way, and `path/2` its points. The
  directions are at each angle, not only the 8 directions from cell to
  cell: the library solves the eikonal equation on the grid, in a time
  in proportion to the number of the cells (about 40 ms for 200 x 200
  cells). Near a wall, the direction goes to the center of the next
  cell of the way. In a blocked cell and outside the grid, the
  direction goes to the nearest open cell with a way (at 3 cells or
  less), and `has_way/2` tells if a position has a way.
  `docs/fields.md` has the algorithm, the measurements and the limits.
- The option `margin` of `boids_field:new/3`: the cost of the open
  cells near a wall is multiplied (`[3, 2]`: by 3 at 1 cell from a
  wall, by 2 at 2 cells), so a way keeps away from the walls where it
  has room.
- `boids_grid:costs/1` gives the costs of all the cells of a grid.
- `examples/bridge.exs` gets its ways from `boids_field`, with a margin
  for its water.
- `Seen` has the key `fields`: the fields that the boid uses, by their
  names. A boid keeps the field that it read, as it keeps its grid.
- Two streams of boids that go in opposite directions pass each other
  in a narrow way: the option `oncoming => false` of `separation`,
  `alignment` and `cohesion`, with which a rule does not see a neighbor
  that comes from the front, together with the rule `dodge`. `dodge`
  moves each boid to its right when the two will be at the same point,
  so the streams make two lanes between walls. With `oncoming => false`
  and no `dodge`, the streams go through each other.
  `examples/bridge.exs` has the two rules as its mode `streams`. Its
  result has the near pairs of boids that go opposite ways, and it has
  an argument for the seed.
- `Seen` has the key `grids`: the grids that the boid uses, by their
  names. A boid keeps the grid that it read, and reads it again only
  after a change of a grid of its world (`specs/Kept.tla`).
- A grid of cells (`boids_grid`), in two dimensions: blocked cells and
  a cost for each cell, from a list, from rows of text, or from a
  function of the center of each cell. It gives the first contact of a
  line with a blocked cell, the walkable place nearest to a position,
  the walls near a position, and the steps from a cell for a search of
  ways. The cells are in a binary, so all the processes with one grid
  share one copy of them.
- A boid can have a rule two times, with a name for each one. Rules are
  added and removed one at a time (`boids:add_rule/3`,
  `boids:delete_rule/3`, `boids:which_rules/2`).
- Boids in two or three dimensions, with groups, an angle that a boid
  sees, and a maximum number of neighbors.
- A boid can search its neighbors at one step of N, and read only the
  neighbors that it knows in the other steps (the option `search`).
- Relations between the boids, as a graph with labels (`boids:relate/4`,
  `boids:relations/1`, `boids:related/3`, `boids:related_to/3`), and
  rules that use them (the target `{related, Label}`).
- The flocks of a world: the groups of boids that see each other
  (`boids:flocks/2`). The world as a graph of these boids
  (`boids:graph/2`), for the functions of the module `graph`.
- A world on several nodes: a world with a name is one world on the
  connected nodes that start it. Each node has a part of the tiles of
  the world. A boid shows itself to another node near a border, and its
  process moves to that node across the border, with its state and its
  random numbers (`boids:nodes/1`, the option `tile`). The functions of
  `boids` are about the boids of all the nodes, or of one node with the
  argument `local`. After a split of the network, a boid that has a
  process on two nodes gets one process again. A call to a boid of
  another node that gets no answer in the time limit gives `{error,
  timeout}` (`boids:timeout/0`).
- The id of a boid is a reference, and `boids:whereis/2` gives its
  process, on each node.
- `boids:snapshot/1` gives the boids in the order in which they came to
  the world: two runs that add the same boids give them in the same
  order, also when the ids are references. A boid keeps its place in the
  order when it moves to another node. This is a change: the order was
  not specified before. The world gives a number to each boid that
  comes, with no work at a step, and `snapshot/1` sorts the rows by that
  number (less than 1 microsecond for each boid).
- A world can be saved and loaded. `boids:export/1` gives all that a
  world has as one term, which `term_to_binary/1` writes to a file: the
  boids of all the nodes with all their state, their relations, and the
  facts of the world with their versions. `boids:import/2` starts each
  boid again with its module, its id and its state (`init/1` does not
  run), and gives the facts to all the nodes of the world. With `tick
  => manual` and seeds, 100 steps, a save, a load into a new world and
  100 steps give the same positions as 200 steps. A world on one node
  loads a save of a world on several nodes, and the opposite.
- An export tells what it does not have (`not_saved`: a process of
  yours, a boid below a supervisor of yours) and what can fail after a
  load (`can_fail`). A boid with an anonymous function loads only on a
  node with the same code of the module of that function: use `fun
  Module:Function/Arity` for a rule of a boid that you save. A boid
  with a pid, a port or a reference in its state needs `handle_load/2`.
  `boids:import/2` tells which boids started, and which did not, with
  the reason. An export of another format gives `{error, {format,
  Number}}`.
- The optional callback `handle_load/2` of `gen_boid`. It runs when a
  boid starts again from a save: it changes the state of a save of an
  older version of the module (the attribute `vsn`), and it makes again
  what a save cannot keep, for example a table of ETS.
- `boids_world:merge/2` gives facts with their versions to a world, on
  all its nodes: a world takes the facts of a save as the facts of a
  node that comes to it.
- A process with another behavior as a boid (`boids:join/2`,
  `boids:advance/3`).
- Steps of all the boids from one state of the world (`boids:step/2`),
  for tests and for simulations that do not follow the clock.
- A boid that stops with an error does not start again, so a boid with
  an error at each step cannot stop its world.
- The obstacles are in an index of cells, as the boids. A boid gets only
  the obstacles that it can reach (`boids_boid:reach/1`), so an obstacle
  far from the boids costs almost nothing: with 1,000 boids and 400
  obstacles, a step takes about 14 ms, and it took 128 ms before. This
  is a change: the key `obstacles` of `Seen` has only these obstacles,
  not all the obstacles of the world. `boids:obstacles/1` and
  `boids_space:env/1` continue to give all of them. A read finds an
  obstacle that moves one time (`boids_space:obstacles/3`).
- Only the process of a world writes the obstacles and the scale of the
  time (`boids_world:set/3`): `boids:set_obstacle/4`,
  `boids:remove_obstacle/2` and `boids:set_time_scale/2` send it one
  message, and the boids read with no message. This is a change: with
  the space of a world as the argument, these three functions wrote to
  the tables with no message before. A bad scale of the time now gives
  the error `badarg`.
- In a world on several nodes, the obstacles and the scale of the time
  are on all the nodes. A change is on each node that has a connection
  when its call returns, a node that comes later gets all of them, and
  after a split of the network all the nodes come to one value for each
  of them: the last change wins. The version of a change has a counter
  that is the time of the system, and never less than a counter that
  the node knows: all the nodes get the same value for each clock of
  each computer, and the last change in time when the clocks agree. An
  obstacle that was removed keeps a mark for some time
  (`boids:mark_time/0`, which can be `infinity`), so that an older
  change does not bring it back. The three functions that change them
  can give
  `{error, timeout}` when a node gives no answer.
  `boids_world:facts/1` gives the facts of a node with their versions.
  The specification is `specs/Facts.tla`.
- Specifications of the flows in TLA+ (`specs/`, `docs/specs.md`): the
  members of a world, a write against a read of its space (of the boids
  and of the obstacles), the step in two parts, and the move of a boid
  to another node, on two nodes and on three nodes. The tests check the models and the fault
  models with the native checker of Accord, and replay the process of a
  real world against `specs/Members.tla`.
- The processes of a world and of a boid have a label.
- Games made with the library, in `examples/`: each game is a folder
  with its module, its page and its tests, and a site shows them in
  `/showcases`, with a home page and a playground. The site runs on a
  computer and on Cloudflare Workers. The tests of the examples start
  each game with the library of the same commit.
  - Rock Patrol: a ship in a field of rocks, and drones that hunt it and shoot at it.
  - Long Flight: the rules of a flock are the cards of the person.
  - Last Seen: a thief in a market crowd, and police who know only what the witnesses saw.
  - Flock Lab: puzzles that teach programming to kids with rule blocks, and show
    the same program as Erlang and Elixir code.
  - Quiet Herd: a stealth game, where fear goes from deer to deer.
  - Living Land: species whose rule weights are genes.
  - Night Fold: a sheepdog brings the sheep into the fold before the wolves come.
  - Exit Plan: pillars and signs bring a crowd out of a hall with no crush.
  - Hive Guard: guard bees that each guard a post against waves of beetles.
  - Deep Reef: a predator against a school of fish that confuses it.
  - Duckling Line: a line of ducklings, each one follows the one before it.
  - Ant Trail: ants make a trail to food with a scent.
  - Tag Yard: children play tag, and the child that is "it" changes.
  - Firefly Field: fireflies that see each other come to flash together.
- The examples draw animals (birds, sheep, dogs, wolves, fish, deer,
  foxes, bees, beetles, ants, ducks, fireflies and people) on a ground
  of grass, water, sand, a floor or night.
