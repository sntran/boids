# A flock in the terminal: birds that flock, a hawk that pursues them, and
# two obstacles.
#
#     mix run examples/terminal.exs [SECONDS]
#
# The flock makes 20 steps in a second. This script gets a message after
# each step, reads the flock, and draws it.

defmodule Terminal do
  @width 100
  @height 30
  @arrows {"→", "↗", "↑", "↖", "←", "↙", "↓", "↘"}

  def run(seconds) do
    # One cell of the terminal is 1 unit wide and 2 units high.
    bounds = {{0, 0}, {@width, @height * 2}}
    {:ok, flock} = :boids.start_flock(bounds: bounds, wrap: true)
    :boids.set_obstacle(flock, :left, {30, 30}, 5)
    :boids.set_obstacle(flock, :right, {70, 25}, 4)

    birds = [
      {:avoid, 4.0, lookahead: 1.5},
      {:evade, 3.0, target: {:group, :hawk}, radius: 12},
      {:separation, 1.5, radius: 3},
      {:alignment, 1.0},
      {:cohesion, 1.0}
    ]

    hawk = [{:avoid, 4.0, lookahead: 1.5}, {:pursue, 1.0, target: {:group, :bird}}, {:wander, 0.5}]

    {:ok, _} =
      :boids.populate(flock, 70, group: :bird, rules: birds, min_speed: 6, max_speed: 12, combine: :priority)

    {:ok, _} =
      :boids.populate(flock, 1, group: :hawk, rules: hawk, max_speed: 14, perception: 25, combine: :priority)

    IO.write([IO.ANSI.clear(), "\e[?25l"])
    space = :boids.space(flock)
    :ok = :boids.subscribe(flock)
    for _ <- 1..(seconds * 20), do: frame(space)
    IO.write("\e[?25h")
    :boids.stop_flock(flock)
  end

  defp frame(space) do
    # The message of the flock after a step.
    receive do
      {:boids, _flock, {:step, _count, _dt}} -> :ok
    end

    cells =
      for %{pos: {x, y}, vel: vel, group: group} <- :boids.snapshot(space), into: %{} do
        {{trunc(x), trunc(y / 2)}, glyph(group, vel)}
      end

    rocks =
      for %{pos: {cx, cy}, radius: r} <- :boids.obstacles(space),
          x <- trunc(cx - r)..trunc(cx + r),
          y <- trunc((cy - r) / 2)..trunc((cy + r) / 2),
          :boids_vec.dist({x + 0.5, y * 2 + 1}, {cx, cy}) <= r,
          into: %{},
          do: {{x, y}, [IO.ANSI.light_black(), "#", IO.ANSI.reset()]}

    cells = Map.merge(rocks, cells)

    lines =
      for y <- (@height - 1)..0//-1 do
        [for(x <- 0..(@width - 1), do: Map.get(cells, {x, y}, " ")), "\n"]
      end

    IO.write([IO.ANSI.home(), lines])
  end

  defp glyph(:hawk, _vel), do: [IO.ANSI.red(), "●", IO.ANSI.reset()]

  defp glyph(:bird, {vx, vy}) do
    turn = :math.atan2(vy, vx) / (:math.pi() / 4)
    elem(@arrows, Integer.mod(round(turn), 8))
  end
end

seconds =
  case System.argv() do
    [arg] -> String.to_integer(arg)
    [] -> 30
  end

Terminal.run(seconds)
