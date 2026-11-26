# Changelog

## 0.1.0

The first version.

- A flock: a supervisor, a process that owns the space, a clock, and a
  small number of workers that make the steps of the boids on all the
  processors (`boids:start_flock/1`, `boids:child_spec/1`).
- A boid is a value in a worker of the flock, with no process of its
  own (`boids:add/2`, `boids:populate/3`, `boids:update/3`,
  `boids:remove/2`).
- The space of a flock in ETS tables, with a grid of cells as the index
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
- The clock of a flock: a step each `tick` milliseconds, in two parts.
  All the boids calculate from the same state of the flock, then they
  all move. A message after each step (`boids:subscribe/1`).
- Steps without the clock (`tick => manual`, `boids:step/2`), for tests
  and for simulations that are faster than the clock. With a seed for
  each boid, a run always gives the same result.
- The behavior `gen_boid`: a boid that is a process, with a module of
  yours that gives its options, decides at each step (`handle_step/3`),
  and answers messages (`handle_call/4`, `handle_cast/3`,
  `handle_info/3`). It can be a child of a supervisor of yours, which
  starts it again with its id (`gen_boid:start_link/3`,
  `gen_boid:child_spec/1`).
- A process with another behavior as a boid (`boids:join/2`,
  `boids:advance/3`).
- A boid whose rule has an error goes from its flock, and the other
  boids continue.
- Specifications of the flows in TLA+ (`specs/`, `docs/specs.md`): the
  members of a flock, a write against a read of the space, and the step
  in two parts. The tests check the models and the fault models with the
  native checker of Accord, and replay a real flock process against
  `specs/Flock.tla`.
- The processes of a flock have a label.
