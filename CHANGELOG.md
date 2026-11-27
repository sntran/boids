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
  `follow`, `cruise`, `leader`, `dodge`, `flow`, and a function of yours
  (`boids_boid`, `boids_steer`).
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
- A process with another behavior as a boid (`boids:join/2`,
  `boids:advance/3`).
- Steps of all the boids from one state of the world (`boids:step/2`),
  for tests and for simulations that do not follow the clock.
- A boid that stops with an error does not start again, so a boid with
  an error at each step cannot stop its world.
- Specifications of the flows in TLA+ (`specs/`, `docs/specs.md`): the
  members of a world, a write against a read of its space, the step in
  two parts, and the move of a boid to another node, on two nodes and
  on three nodes. The tests check the models and the fault
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
