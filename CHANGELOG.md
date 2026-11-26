# Changelog

## 0.1.0

The first version.

- A flock: a supervisor, a process that owns the space, and one process
  for each boid (`boids:start_flock/1`, `boids:child_spec/1`,
  `boids:add/2`, `boids:populate/3`, `gen_boid`).
- The space of a flock in ETS tables, with a grid of cells as the index
  (`boids_space`). A box, sides that continue at the opposite sides
  (`wrap`), obstacles, and a scale of the time.
- The rules of a boid: `separation`, `alignment`, `cohesion`, `seek`,
  `flee`, `arrive`, `pursue`, `evade`, `wander`, `avoid`, `contain`,
  `follow`, `cruise`, `leader`, `dodge`, `flow`, and a module or a
  function of yours (`boids_boid`, `boids_steer`, `gen_boid`).
- Boids in two or three dimensions, with groups, an angle that a boid
  sees, and a maximum number of neighbors.
- A process of yours as a boid (`boids:join/2`, `boids:advance/3`).
- Steps of all the boids from one state of the flock (`boids:step/2`),
  for tests and for simulations that do not follow the clock.
- Specifications of the flows in TLA+ (`specs/`, `docs/specs.md`): the
  members of a flock, a write against a read of the space, and the step
  in two parts. The tests check the models and the fault models with the
  native checker of Accord, and replay a real flock process against
  `specs/Flock.tla`.
- A boid of `boids:add/2` that stops with an error does not start again,
  so a boid with an error at each step cannot stop its flock.
- `gen_boid`: the process of a boid, and the behavior of its rules, in
  the way of `gen_event`. A rule of yours is a callback module with its
  own state (`init/1`, `handle_step/4`, `handle_call/3`,
  `handle_info/3`, `terminate/2`). A boid gets rules and loses them
  while it runs (`gen_boid:add_rule/2`, `gen_boid:delete_rule/3`,
  `gen_boid:which_rules/1`, `gen_boid:call/3`). A rule that fails does
  not stop its boid.
- A boid can be a child of a supervisor of yours, which starts it again
  with its id (`gen_boid:start_link/2`, `gen_boid:child_spec/1`).
- The processes of a flock and of a boid have a label.
