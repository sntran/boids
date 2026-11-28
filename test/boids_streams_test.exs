defmodule BoidsStreamsTest do
  # Two streams of boids that go in opposite directions: the option
  # oncoming of separation, with the rule dodge.
  #
  # Each run has steps of 0.1 second with tick => manual, and a seed for
  # each boid: its result is always the same, and it does not change with
  # the load of the computer. Each limit has a margin: the comments give
  # the range of each value for 12 sets of seeds (8 for the box of two
  # dimensions, and 6 for the box of three dimensions).
  #
  # A run of a corridor takes about 0.9 second, and a run of a box 0.5
  # second (two dimensions) or 1.3 second (three dimensions). The runs of
  # a test are done at the same time: the file takes about 5 seconds on a
  # computer with 4 processors.
  #
  # The runs use all the processors. The module is not async, so that
  # they do not slow the tests of the other modules that have a time
  # limit.
  use ExUnit.Case, async: false

  defmodule Goer do
    # A boid that goes from one end of a corridor to the other end, and
    # back. Its group is its direction, its data is the number of its
    # crossings, and its state has its rules for each direction.
    @behaviour :gen_boid

    @impl true
    def init(options), do: {:ok, options}

    @impl true
    def handle_act(%{pos: {x, _}, group: way, data: crossings, state: rules} = boid) do
      cond do
        way == :east and x >= 39.0 -> turn(boid, :west, crossings, rules)
        way == :west and x <= 1.0 -> turn(boid, :east, crossings, rules)
        true -> {:ok, boid}
      end
    end

    defp turn(boid, way, crossings, rules) do
      {:ok, %{:boids_boid.update(boid, %{group: way, rules: rules[way]}) | data: crossings + 1}}
    end
  end

  @separation {:separation, 1.5, %{radius: 0.7}}
  @alone {:separation, 1.5, %{radius: 0.7, oncoming: false}}
  # The two rules for two streams in a narrow way.
  @pair [@alone, {:dodge, 4.0}]
  @body %{tick: :manual, max_speed: 4.0, max_force: 24.0, perception: 2.0}

  # A corridor 40 long and `width` cells wide, with a hard limit at its
  # walls, for 120 seconds. 15 boids go to each end, and back. Each boid
  # has the rule flow for its direction, and the rules `rules`.
  #
  # The result: the crossings (the arrivals at an end), the seconds that
  # boids stood (a speed less than 0.4 for 3 seconds or more), the near
  # pairs (the pairs of boids and steps with a distance less than 0.35)
  # of boids that go the same way and opposite ways, and the lane: the
  # mean side of the boids that go west minus that of the boids that go
  # east, divided by the width. A lane of 0.5 is two streams that each
  # have one half of the way, on the right of their direction.
  defp corridor(width, rules) do
    {:ok, world} = :boids.start_world(%{bounds: {{0.0, 0.0}, {40.0, width * 1.0}}, cell_size: 2.0})
    :ok = :boids.set_grid(world, :way, :boids_grid.new(size: {40, width}))
    :rand.seed(:exsss, {1, 2, 3})

    ways = %{
      east: [{:flow, 1.0, %{field: {1.0, 0.0}}} | rules],
      west: [{:flow, 1.0, %{field: {-1.0, 0.0}}} | rules]
    }

    for n <- 1..30 do
      way = if rem(n, 2) == 0, do: :east, else: :west

      goer = %{
        pos: {1.5 + :rand.uniform() * 37, 0.1 + :rand.uniform() * (width - 0.2)},
        seed: 1000 + n,
        walkable: {:named, :way},
        group: way,
        rules: ways[way],
        data: 0,
        state: ways
      }

      {:ok, _} = :gen_boid.start(world, Goer, Map.merge(@body, goer))
    end

    # A boid that goes east has its right at -y.
    lane = fn rows ->
      mean = fn way ->
        sides = for %{pos: {_, y}, group: ^way} <- rows, do: y
        Enum.sum(sides) / length(sides)
      end

      (mean.(:west) - mean.(:east)) / width
    end

    result = run(world, 120, lane, &:boids_vec.dist/2)
    crossings = Enum.sum(for %{data: crossings} <- :boids.snapshot(world), do: crossings)
    :ok = :boids.stop_world(world)
    result |> Map.put(:crossings, crossings) |> Map.put(:lane, result.value)
  end

  # A box 40 long with sides of 4, where each side continues at the
  # opposite side: two streams with no walls and no ends, for 60
  # seconds. Half of the boids go to +x, and half to -x. The result has
  # the speed: the mean speed of the boids in their direction, as a part
  # of the maximum speed.
  defp box(dim, count, rules) do
    {min, max, east} =
      case dim do
        2 -> {{0.0, 0.0}, {40.0, 4.0}, {1.0, 0.0}}
        3 -> {{0.0, 0.0, 0.0}, {40.0, 4.0, 4.0}, {1.0, 0.0, 0.0}}
      end

    fields = %{east: east, west: :boids_vec.neg(east)}
    {:ok, world} = :boids.start_world(%{bounds: {min, max}, wrap: true, cell_size: 2.0})
    :rand.seed(:exsss, {1, 2, 3})

    for n <- 1..count do
      way = if rem(n, 2) == 0, do: :east, else: :west
      rules = [{:flow, 1.0, %{field: fields[way]}} | rules]
      goer = %{pos: :boids_vec.random_in(min, max), seed: 1000 + n, group: way, rules: rules}
      {:ok, _} = :boids.add(world, Map.merge(@body, goer))
    end

    speed = fn rows ->
      Enum.sum(for %{vel: vel, group: way} <- rows, do: :boids_vec.dot(vel, fields[way])) / (count * 4.0)
    end

    # The distance across a side of the box too.
    dist = fn a, b -> :boids_vec.norm(:boids_vec.shortest(:boids_vec.sub(b, a), min, max)) end
    result = run(world, 60, speed, dist)
    :ok = :boids.stop_world(world)
    Map.put(result, :speed, result.value)
  end

  # The box with separation as now, with the option alone, and with the
  # two rules.
  defp boxes(dim, count) do
    together(
      default: fn -> box(dim, count, [@separation]) end,
      alone: fn -> box(dim, count, [@alone]) end,
      pair: fn -> box(dim, count, @pair) end
    )
  end

  # Steps of 0.1 second. After each step: the boids that stood for 3
  # seconds or more, the near pairs, and a value of the scene.
  defp run(world, seconds, value, dist) do
    steps = seconds * 10
    zero = %{stood: 0, same: 0, opposite: 0, value: 0.0, slow: %{}}

    sums =
      Enum.reduce(1..steps, zero, fn _, sums ->
        :ok = :boids.step(world, 0.1)
        rows = :boids.snapshot(world)

        slow =
          Map.new(rows, fn %{id: id, vel: vel} ->
            {id, if(:boids_vec.norm2(vel) < 0.16, do: Map.get(sums.slow, id, 0) + 1, else: 0)}
          end)

        {same, opposite} = near(for(%{pos: pos, group: way} <- rows, do: {pos, way}), dist, 0, 0)

        %{
          stood: sums.stood + Enum.count(slow, fn {_, count} -> count >= 30 end),
          same: sums.same + same,
          opposite: sums.opposite + opposite,
          value: sums.value + value.(rows),
          slow: slow
        }
      end)

    %{stood: sums.stood / 10, same: sums.same, opposite: sums.opposite, value: sums.value / steps}
  end

  # Does the runs at the same time, each in its process. A run does not
  # read a clock, so its result is the same.
  defp together(runs) do
    runs
    |> Task.async_stream(fn {name, run} -> {name, run.()} end, timeout: :infinity)
    |> Map.new(fn {:ok, result} -> result end)
  end

  defp near([], _dist, same, opposite), do: {same, opposite}

  defp near([{pos, way} | rest], dist, same, opposite) do
    {same, opposite} =
      Enum.reduce(rest, {same, opposite}, fn {other, other_way}, {same, opposite} ->
        cond do
          dist.(pos, other) >= 0.35 -> {same, opposite}
          other_way == way -> {same + 1, opposite}
          true -> {same, opposite + 1}
        end
      end)

    near(rest, dist, same, opposite)
  end

  # The runs of the corridors, one time for all the tests.
  setup_all do
    together(
      # The corridor of 1 cell: with flow only (the boids go through each
      # other), with separation as now, with the option alone, and with
      # the two rules.
      flow: fn -> corridor(1, []) end,
      default: fn -> corridor(1, [@separation]) end,
      alone: fn -> corridor(1, [@alone]) end,
      pair: fn -> corridor(1, @pair) end,
      # The corridor of 2 cells.
      flow2: fn -> corridor(2, []) end,
      pair2: fn -> corridor(2, @pair) end
    )
  end

  describe "two streams in a corridor with walls" do
    test "with separation as now, the two streams stop each other", %{flow: flow, default: default} do
      # For 12 sets of seeds: 320 to 330 crossings with flow only, and
      # 19 to 131 with separation.
      assert flow.crossings >= 320
      assert default.crossings < 0.5 * flow.crossings
      # The boids of the two streams are then in each other more than
      # with no separation: 2,460 to 5,154 near pairs, against 1,609 to
      # 2,476.
      assert default.opposite > flow.opposite
    end

    test "with oncoming => false and dodge, in a way of 1 cell: the flow, no boid that stands, and two lanes",
         %{
           flow: flow,
           pair: pair
         } do
      # 314 to 321 crossings: 95 % of flow only, or more.
      assert pair.crossings >= 0.9 * flow.crossings
      assert pair.stood == 0
      # 18 to 34 near pairs of opposite boids, and 9 to 28 of boids that
      # go the same way.
      assert pair.opposite <= 100
      assert pair.same <= 100
      # 0.77 to 0.82: each stream is at its right wall.
      assert pair.lane >= 0.5
    end

    test "the same in a way of 2 cells", %{flow2: flow, pair2: pair} do
      # 313 to 321 crossings of 320 to 330, 12 to 44 near pairs of
      # opposite boids, and a lane of 0.61 to 0.69.
      assert pair.crossings >= 0.9 * flow.crossings
      assert pair.stood == 0
      assert pair.opposite <= 100
      assert pair.same <= 100
      assert pair.lane >= 0.5
    end

    test "with oncoming => false and no dodge, the two streams go through each other", %{
      flow: flow,
      alone: alone,
      pair: pair
    } do
      # The flow is that of flow only: 320 to 328 crossings.
      assert alone.crossings >= 0.95 * flow.crossings
      assert alone.stood == 0
      # But the boids of the two streams are as near as with no
      # separation: 1,356 to 1,631 near pairs, against 1,609 to 2,476
      # with flow only, and 18 to 34 with dodge. There are no lanes.
      assert alone.opposite > 0.5 * flow.opposite
      assert alone.opposite > 10 * pair.opposite
      assert abs(alone.lane) < 0.1
      # The boids that go the same way keep their space: 236 to 370
      # near pairs, against 841 to 5,985 with flow only.
      assert alone.same < flow.same
    end
  end

  describe "two streams with no walls" do
    test "in two dimensions, oncoming => false alone has more near pairs of opposite boids than the default" do
      %{default: default, alone: alone, pair: pair} = boxes(2, 30)
      # For 8 sets of seeds: 22 to 72 near pairs with separation as now,
      # 196 to 420 with the option alone, and 0 to 3 with dodge too.
      assert alone.opposite >= 3 * default.opposite
      assert alone.opposite >= 100
      assert pair.opposite <= 10
      # The speed with the two rules: 0.97 to 0.98 of the maximum speed.
      assert pair.speed >= 0.95
      for result <- [default, alone, pair], do: assert(result.stood == 0)
    end

    test "in three dimensions, the same" do
      %{default: default, alone: alone, pair: pair} = boxes(3, 60)
      # For 6 sets of seeds: 15 to 47 near pairs with separation as now,
      # 106 to 206 with the option alone, and none with dodge too.
      assert alone.opposite >= 2 * default.opposite
      assert alone.opposite >= 50
      assert pair.opposite <= 5
      # The speed with the two rules: 0.97 to 0.98 of the maximum speed.
      assert pair.speed >= 0.95
      for result <- [default, alone, pair], do: assert(result.stood == 0)
    end
  end
end
