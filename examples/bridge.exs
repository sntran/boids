# Boids that carry things across a river on a bridge.
#
#     mix run examples/bridge.exs MODE BRIDGE_WIDTH [BOIDS] [SECONDS]
#
# The land is a grid of cells of 1 x 1, 40 cells wide and 36 cells high.
# The river is the rows 14 to 20. The bridge is the columns from 19, as
# wide as BRIDGE_WIDTH. Each boid goes from the nest to the food, and back
# to the nest: that is one trip. A field of directions (a search of the
# grid) leads each boid around the water, to the bridge.
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
open? = fn i, j -> i in 0..(cols - 1) and j in 0..(rows - 1) and not water?.(i, j) end
around = for di <- -1..1, dj <- -1..1, {di, dj} != {0, 0}, do: {di, dj}

# A step to a cell beside, with no cut across the corner of the water.
step? = fn {i, j}, {di, dj} ->
  open?.(i + di, j + dj) and (di == 0 or dj == 0 or (open?.(i + di, j) and open?.(i, j + dj)))
end

# The distances from the target to each open cell, and a field of directions.
field = fn goal ->
  spread = fn spread, edge, dist ->
    {next, dist} =
      for cell = {i, j} <- edge, d = {di, dj} <- around, step?.(cell, d), reduce: {[], dist} do
        {next, dist} ->
          cost = dist[cell] + if(di != 0 and dj != 0, do: :math.sqrt(2), else: 1.0)

          if cost < Map.get(dist, {i + di, j + dj}, :infinity),
            do: {[{i + di, j + dj} | next], Map.put(dist, {i + di, j + dj}, cost)},
            else: {next, dist}
      end

    if next == [], do: dist, else: spread.(spread, Enum.uniq(next), dist)
  end

  dist = spread.(spread, [goal], %{goal => 0.0})
  {gi, gj} = goal

  fn {x, y} ->
    cell = {floor(x), floor(y)}
    {i, j} = cell

    {tx, ty} =
      case for(d = {di, dj} <- around, step?.(cell, d), do: {dist[{i + di, j + dj}], {i + di, j + dj}}) do
        [] ->
          {gi, gj}

        near ->
          with {d, best} <- Enum.min(near),
               true <- d < Map.get(dist, cell, :infinity),
               do: best,
               else: (_ -> {gi, gj})
      end

    {dx, dy} = {tx + 0.5 - x, ty + 0.5 - y}
    length = :math.sqrt(dx * dx + dy * dy)
    if length == 0, do: {0.0, 0.0}, else: {dx / length, dy / length}
  end
end

{nest, food} = {{20, 4}, {12, 29}}

# The land as a grid: the library asks one time for each cell if it is
# water.
land = :boids_grid.new(size: {cols, rows}, blocked: fn {x, y} -> water?.(floor(x), floor(y)) end)

:persistent_term.put(:bridge, %{
  mode: mode,
  water?: water?,
  ends: %{food: food, nest: nest},
  fields: %{food: field.(food), nest: field.(nest)}
})

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

  # The rules to go to the end Goal (food or nest).
  def rules(goal) do
    %{mode: mode, fields: fields} = :persistent_term.get(:bridge)
    flow = [{:flow, 1.0, %{field: fields[goal]}}]

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
