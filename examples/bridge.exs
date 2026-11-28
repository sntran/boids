# Boids that carry things across a river on a bridge.
#
#     mix run examples/bridge.exs MODE BRIDGE_WIDTH [BOIDS] [SECONDS]
#
# The land is a grid of cells of 1 x 1, 40 cells wide and 36 cells high.
# The river is the rows 14 to 20. The bridge is the columns from 19, as
# wide as BRIDGE_WIDTH. Each boid goes from the nest to the food, and back
# to the nest: that is one trip. Two fields of directions of the world
# (boids_field, one for each end) lead each boid around the water, to
# the bridge.
#
# MODE:
#   through  - flow only. The boids go through each other.
#   spacing  - flow and separation.
#   blocked  - flow and separation. In handle_act/1, a boid that is in the
#              water goes back to its last position (a hard limit).
#   ways     - as "blocked", but separation sees only the boids that go
#              in the same direction (the group changes at each end).
#   walkable - flow and separation, with the option walkable: the land is
#              a grid of the world (boids:set_grid/3), and the water is
#              its blocked cells. A boid slides along the water.
#   walls    - as "walkable", with the rule walls: a boid moves away from
#              the water before it touches it.
#
# The result: the trips, the steps that a boid ended in the water, and
# the seconds that boids stood (a speed less than 0.4 for 3 s or more).
[mode, width | rest] = System.argv()
width = String.to_integer(width)
[count, seconds] = Enum.map(rest ++ Enum.drop(["30", "120"], length(rest)), &String.to_integer/1)
{cols, rows, bridge} = {40, 36, 19}
water? = fn i, j -> j in 14..20 and not (i >= bridge and i < bridge + width) end
{nest, food} = {{20, 4}, {12, 29}}

# The land as a grid: the library asks one time for each cell if it is
# water. A cell near the water costs more (3 beside it, 2 at two cells):
# the ways keep away from the water where they can, and the boids do
# not all go around the same corner at the ends of the bridge.
near = fn i, j ->
  Enum.min([3 | for(di <- -2..2, dj <- -2..2, water?.(i + di, j + dj), do: max(abs(di), abs(dj)))])
end

costs =
  for i <- 0..(cols - 1),
      j <- 0..(rows - 1),
      not water?.(i, j),
      near.(i, j) < 3,
      do: {{i, j}, 4 - near.(i, j)}

land =
  :boids_grid.new(size: {cols, rows}, blocked: fn {x, y} -> water?.(floor(x), floor(y)) end, costs: costs)

:persistent_term.put(:bridge, %{mode: mode, water?: water?, ends: %{food: food, nest: nest}})

defmodule Carrier do
  @behaviour :gen_boid

  def init({pos, seed}) do
    %{mode: mode} = :persistent_term.get(:bridge)

    {:ok,
     %{
       pos: pos,
       tick: :manual,
       seed: seed,
       max_speed: 4.0,
       max_force: 24.0,
       perception: 2.0,
       walkable: if(mode in ["walkable", "walls"], do: {:named, :land}, else: :all),
       group: :food,
       rules: rules(:food),
       data: %{trips: 0},
       state: %{last: pos}
     }}
  end

  # The rules to go to the end Goal (food or nest): the field of the
  # world with the name of that end.
  def rules(goal) do
    %{mode: mode} = :persistent_term.get(:bridge)
    flow = [{:flow, 1.0, %{field: {:named, goal}}}]

    case mode do
      "through" -> flow
      "ways" -> flow ++ [{:separation, 1.5, %{radius: 0.7, groups: [goal]}}]
      "walls" -> flow ++ [{:separation, 1.5, %{radius: 0.7}}, {:walls, 1.0}]
      _ -> flow ++ [{:separation, 1.5, %{radius: 0.7}}]
    end
  end

  def handle_act(boid = %{pos: {x, y}, group: goal, data: %{trips: trips}, state: %{last: last}}) do
    %{mode: mode, water?: water?, ends: ends} = :persistent_term.get(:bridge)

    boid =
      if mode in ["blocked", "ways"] and water?.(floor(x), floor(y)),
        do: %{boid | pos: last, vel: {0.0, 0.0}},
        else: boid

    {px, py} = boid.pos
    {ex, ey} = ends[goal]

    if :math.sqrt((ex + 0.5 - px) ** 2 + (ey + 0.5 - py) ** 2) < 1.0 do
      next = if goal == :food, do: :nest, else: :food
      trips = if goal == :nest, do: trips + 1, else: trips
      boid = :boids_boid.update(boid, %{group: next, rules: rules(next)})
      {:ok, %{boid | data: %{trips: trips}, state: %{last: boid.pos}}}
    else
      {:ok, %{boid | state: %{last: boid.pos}}}
    end
  end
end

:rand.seed(:exsss, {1, 2, 3})
{:ok, world} = :boids.start_world(%{bounds: {{0.0, 0.0}, {cols * 1.0, rows * 1.0}}, cell_size: 2.0})
:ok = :boids.set_grid(world, :land, land)
# The ways to each end: one field for all the boids that go there.
:ok = :boids.set_field(world, :food, :boids_field.new(land, [food]))
:ok = :boids.set_field(world, :nest, :boids_field.new(land, [nest]))

for seed <- 1..count do
  {:ok, _} = :gen_boid.start(world, Carrier, {{16 + :rand.uniform() * 8, 2 + :rand.uniform() * 5}, seed})
end

dt = 0.1

{wet, stood, _} =
  Enum.reduce(1..round(seconds / dt), {0, 0, %{}}, fn _, {wet, stood, slow} ->
    :ok = :boids.step(world, dt)
    rows = :boids.snapshot(world)
    wet = wet + Enum.count(rows, fn %{pos: {x, y}} -> water?.(floor(x), floor(y)) end)

    slow =
      Map.new(rows, fn %{id: id, vel: {vx, vy}} ->
        {id, if(vx * vx + vy * vy < 0.16, do: Map.get(slow, id, 0) + 1, else: 0)}
      end)

    {wet, stood + Enum.count(slow, fn {_, steps} -> steps >= 30 end), slow}
  end)

trips = Enum.sum(for %{data: %{trips: trips}} <- :boids.snapshot(world), do: trips)

IO.puts(
  "#{mode}, bridge #{width} wide, #{count} boids, #{seconds} s: #{trips} trips, " <>
    "#{wet} steps in the water, #{Float.round(stood * dt, 1)} s stood"
)
