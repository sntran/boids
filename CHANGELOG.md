# Changelog

## 0.1.0

The first version.

- A flock: a supervisor, a process that owns the space, and one process
  for each boid (`boids:start_flock/1`, `boids:child_spec/1`,
  `boids:add/2`, `boids:populate/3`).
- The space of a flock in ETS tables, with a grid of cells as the index
  (`boids_space`). A box, sides that continue at the opposite sides
  (`wrap`), obstacles, and a scale of the time.
- The rules of a boid: `separation`, `alignment`, `cohesion`, `seek`,
  `flee`, `arrive`, `pursue`, `evade`, `wander`, `avoid`, `contain`,
  `follow`, and a function of yours (`boids_boid`, `boids_steer`).
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
