defmodule BoidsFieldTest do
  # A field of directions: the costs to the goals, the directions, and
  # the ways.
  use ExUnit.Case, async: true
  use ExUnitProperties
  import Boids.Helpers

  # A wall with a door at its top, and a goal at the right of the wall.
  @rows [
    "..........",
    "....#.....",
    "....#.....",
    "....#....."
  ]

  # Land of 64 x 64 cells with blocks: {X0, Y0, X1, Y1}, the cells from
  # {X0, Y0} to {X1 - 1, Y1 - 1}. No block touches another block or a
  # side of the land.
  @blocks [
    {27, 43, 35, 48},
    {54, 36, 57, 40},
    {39, 5, 43, 13},
    {4, 7, 15, 13},
    {29, 5, 33, 16},
    {38, 39, 50, 42},
    {20, 28, 31, 33},
    {9, 38, 14, 49},
    {54, 45, 61, 56},
    {33, 23, 40, 34},
    {44, 24, 51, 33},
    {24, 12, 27, 22},
    {10, 54, 21, 61},
    {44, 16, 49, 22}
  ]

  defp wall(opts \\ []), do: :boids_grid.from_rows(@rows, opts)
  defp open(size), do: :boids_grid.new(size: {size, size})

  defp blocks do
    :boids_grid.new(
      size: {64, 64},
      blocked: for({x0, y0, x1, y1} <- @blocks, i <- x0..(x1 - 1), j <- y0..(y1 - 1), do: {i, j})
    )
  end

  defp angle({ax, ay}, {bx, by}), do: :math.acos(max(-1.0, min(1.0, ax * bx + ay * by))) * 180 / :math.pi()

  defp length_of(points) do
    points
    |> Enum.chunk_every(2, 1, :discard)
    |> Enum.map(fn [a, b] -> :boids_vec.dist(a, b) end)
    |> Enum.sum()
  end

  # The costs from the goals with a simple search of 8 directions (the
  # algorithm of Dijkstra with `boids_grid:steps/2`): a map of the cells.
  defp search(grid, goals) do
    search(grid, :gb_sets.from_list(for goal <- goals, do: {0.0, goal}), Map.new(goals, &{&1, 0.0}))
  end

  defp search(grid, queue, costs) do
    if :gb_sets.is_empty(queue) do
      costs
    else
      {{cost, cell}, queue} = :gb_sets.take_smallest(queue)

      {queue, costs} =
        for {to, step} <- :boids_grid.steps(grid, cell),
            cost + step < Map.get(costs, to, :infinity),
            reduce: {queue, costs} do
          {queue, costs} -> {:gb_sets.add({cost + step, to}, queue), Map.put(costs, to, cost + step)}
        end

      search(grid, queue, costs)
    end
  end

  # The shortest way from each place to a point, around blocks: the
  # result is a function of a place. The shortest way is a line of
  # straight parts from corner to corner of the blocks, so the search is
  # in a graph of the corners that see each other.
  defp shortest(goal) do
    corners = for {x0, y0, x1, y1} <- @blocks, corner <- [{x0, y0}, {x1, y0}, {x0, y1}, {x1, y1}], do: corner
    costs = shortest(%{goal => 0.0}, [goal | corners])

    fn place ->
      Enum.min(for {corner, cost} <- costs, sees?(place, corner), do: cost + :boids_vec.dist(place, corner))
    end
  end

  defp shortest(costs, corners) do
    next =
      for a <- corners, from = costs[a], b <- corners, a != b, sees?(a, b), reduce: costs do
        costs -> Map.update(costs, b, from + :boids_vec.dist(a, b), &min(&1, from + :boids_vec.dist(a, b)))
      end

    if next == costs, do: costs, else: shortest(next, corners)
  end

  # True when the line from A to B does not go through the inner part of
  # a block.
  defp sees?(a, b), do: not Enum.any?(@blocks, &through?(a, b, &1))

  defp through?({ax, ay}, {bx, by}, {x0, y0, x1, y1}) do
    sides = [{ax - bx, ax - x0}, {bx - ax, x1 - ax}, {ay - by, ay - y0}, {by - ay, y1 - ay}]

    part =
      Enum.reduce_while(sides, {0.0, 1.0}, fn
        {change, inside}, _part when change == 0 and inside <= 1.0e-9 -> {:halt, :out}
        {change, _inside}, part when change == 0 -> {:cont, part}
        {change, inside}, {from, to} when change < 0 -> {:cont, {max(from, inside / change), to}}
        {change, inside}, {from, to} -> {:cont, {from, min(to, inside / change)}}
      end)

    part != :out and elem(part, 1) - elem(part, 0) > 1.0e-7
  end

  describe "new/2" do
    test "makes the field of the example of the module" do
      field = :boids_field.new(wall(), [{8, 3}])
      # The way from the left goes up, around the wall.
      assert {_, dy} = :boids_field.direction(field, {2.5, 3.5})
      assert dy < 0
      assert :boids_field.direction(field, {8.5, 3.5}) == {0.0, 0.0}
      assert :boids_field.distance(field, {2.5, 3.5}) > 6.0
    end

    test "tells what it is: its size, its cells, and its goals" do
      field = :boids_field.new(wall(cell_size: 2, origin: {-4, 6}), [{8, 3}, {0, 0}, {8, 3}])
      assert :boids_field.is_field(field)
      refute :boids_field.is_field(wall())
      refute :boids_field.is_field({:boids_field, 1})
      assert :boids_field.size(field) == {10, 4}
      assert :boids_field.cell_size(field) == 2.0
      assert :boids_field.origin(field) == {-4.0, 6.0}
      # The goals in their order, each one time.
      assert :boids_field.goals(field) == [{0, 0}, {8, 3}]
      # The positions are in the units of the grid.
      assert :boids_field.distance(field, {13.0, 13.0}) == 0.0
      assert :boids_field.distance(field, {-3.0, 7.0}) == 0.0
      assert {dx, dy} = :boids_field.direction(field, {9.0, 13.0})
      assert_vec({dx, dy}, {1.0, 0.0}, 0.02)
    end

    test "refuses a value that is not a grid, bad goals, and bad options" do
      assert_raise ArgumentError, fn -> :boids_field.new(:land, [{0, 0}]) end

      for goals <- [[], {0, 0}, :none] do
        assert_raise ErlangError, ~r/bad_option.*goals/, fn -> :boids_field.new(wall(), goals) end
      end

      # A goal is an open cell of the grid.
      for goal <- [{4, 1}, {10, 0}, {0, -1}, {0.5, 1}, :here, {1, 2, 3}] do
        assert catch_error(:boids_field.new(wall(), [{0, 0}, goal])) == {:bad_option, {:goals, goal}}
      end

      assert catch_error(:boids_field.new(wall(), [{0, 0}], speed: 2)) == {:bad_option, {:speed, 2}}
      assert catch_error(:boids_field.new(wall(), [{0, 0}], exact: -1)) == {:bad_option, {:exact, -1}}
      assert catch_error(:boids_field.new(wall(), [{0, 0}], exact: 1.5)) == {:bad_option, {:exact, 1.5}}
      assert catch_error(:boids_field.new(wall(), [{0, 0}], :exact)) == {:bad_option, :exact}
      assert :boids_field.is_field(:boids_field.new(wall(), [{0, 0}], %{exact: 0}))
    end
  end

  describe "in open land" do
    test "the direction is the straight line to the goal, at each angle" do
      goal = {12, 20}
      field = :boids_field.new(open(64), [goal])
      :rand.seed(:exsss, {4, 5, 6})

      angles =
        for _ <- 1..200 do
          place = {:rand.uniform() * 63 + 0.5, :rand.uniform() * 63 + 0.5}
          straight = :boids_vec.normalize(:boids_vec.sub({12.5, 20.5}, place))
          {place, angle(:boids_field.direction(field, place), straight)}
        end

      # With a search of 8 directions, the angle is to 22.5 degrees.
      assert Enum.all?(angles, fn {_place, angle} -> angle < 5.0 end)
      assert Enum.sum(for {_, angle} <- angles, do: angle) / 200 < 1.0
    end

    test "the distance is the straight distance: 4 % more at most, and never less" do
      field = :boids_field.new(open(64), [{12, 20}])
      :rand.seed(:exsss, {7, 8, 9})

      for _ <- 1..200 do
        place = {:rand.uniform() * 63 + 0.5, :rand.uniform() * 63 + 0.5}
        straight = :boids_vec.dist(place, {12.5, 20.5})
        cost = :boids_field.distance(field, place)
        assert cost >= straight * (1 - 1.0e-5)
        assert cost <= straight * 1.04 + 0.5
      end

      # At the center of each cell.
      for i <- 0..63, j <- 0..63, straight = :boids_vec.dist({i, j}, {12, 20}) do
        cost = :boids_field.distance(field, {i + 0.5, j + 0.5})
        assert cost >= straight * (1 - 1.0e-5)
        assert cost <= straight * 1.04
      end
    end

    test "a way is a straight line from the start to the goal" do
      field = :boids_field.new(open(64), [{12, 20}])

      for start <- [{50.5, 40.5}, {60.5, 60.5}, {1.5, 62.5}, {30.2, 1.1}] do
        way = :boids_field.path(field, start)
        assert hd(way) == start and List.last(way) == {12.5, 20.5}
        # A point of the way is a tenth of a cell from the straight line at most.
        assert length(way) <= 5
        assert_in_delta length_of(way) / :boids_vec.dist(start, {12.5, 20.5}), 1.0, 0.001
      end

      assert [{12.5, 3.0}, {12.5, 20.5}] = :boids_field.path(field, {12.5, 3})
      # In the cell of the goal, and at its center.
      assert :boids_field.path(field, {12.9, 20.1}) == [{12.9, 20.1}, {12.5, 20.5}]
      assert :boids_field.path(field, {12.5, 20.5}) == [{12.5, 20.5}]
    end

    test "the cells near a goal start with the exact distance, when the option permits" do
      near = for i <- 6..18, j <- 14..26, {i, j} != {12, 20}, do: {i, j}

      error = fn field ->
        Enum.max(
          for {i, j} <- near, straight = :boids_vec.dist({i, j}, {12, 20}) do
            abs(:boids_field.distance(field, {i + 0.5, j + 0.5}) - straight) / straight
          end
        )
      end

      # With no exact start, the cost across a corner is 20 % too much.
      assert error.(:boids_field.new(open(64), [{12, 20}], exact: 0)) > 0.15
      assert error.(:boids_field.new(open(64), [{12, 20}], exact: 2)) < 0.10
      assert error.(:boids_field.new(open(64), [{12, 20}])) < 0.02
      # The directions near the goal are exact too.
      field = :boids_field.new(open(64), [{12, 20}])

      for {i, j} <- near, :boids_vec.dist({i, j}, {12, 20}) <= 8 do
        assert angle(
                 :boids_field.direction(field, {i + 0.5, j + 0.5}),
                 :boids_vec.normalize({12 - i, 20 - j})
               ) < 0.5
      end
    end

    test "near a side or a wall, the cells that see the goal in a straight line start with the exact distance" do
      # A wall with a door, at 4 cells from the goal.
      grid = :boids_grid.new(size: {30, 30}, blocked: for(j <- 0..29, j != 15, do: {6, j}))
      field = :boids_field.new(grid, [{2, 15}])
      assert_in_delta :boids_field.distance(field, {4.5, 17.5}), :math.sqrt(8), 1.0e-4
      assert_in_delta :boids_field.distance(field, {5.5, 18.5}), :math.sqrt(18), 1.0e-4
      assert_in_delta :boids_field.distance(field, {0.5, 22.5}), :math.sqrt(4 + 49), 1.0e-4
      # Through the door: a straight line.
      assert_in_delta :boids_field.distance(field, {8.5, 15.5}), 6.0, 1.0e-4
      assert :boids_field.direction(field, {8.5, 15.5}) == {-1.0, 0.0}
      # Behind the wall, the way is not straight: the equation gives more
      # than the straight distance.
      assert :boids_field.distance(field, {8.5, 16.5}) > :boids_vec.dist({8, 16}, {2, 15}) + 0.3
      assert :boids_field.distance(field, {8.5, 18.5}) > :boids_vec.dist({8, 18}, {2, 15}) + 1.0
      # A goal in a corner of the land.
      corner = :boids_field.new(grid, [{0, 0}])
      assert_in_delta :boids_field.distance(corner, {1.5, 1.5}), :math.sqrt(2), 1.0e-4
      assert_in_delta :boids_field.distance(corner, {5.5, 3.5}), :math.sqrt(34), 1.0e-4
    end

    test "with many goals, the exact start is smaller" do
      # 300 goals: 16,384 / 300 is 54, so the start is 3 cells on each axis.
      goals = for i <- 0..59, j <- 40..44, do: {i, j}
      field = :boids_field.new(open(64), goals)
      assert length(:boids_field.goals(field)) == 300
      assert field == :boids_field.new(open(64), goals, exact: 3)
      assert field != :boids_field.new(open(64), goals, exact: 2)
      # At 3 cells from the goal {59, 40}, across its corner: exact.
      assert_in_delta :boids_field.distance(field, {61.5, 37.5}), :math.sqrt(13), 1.0e-4
      # Above the goals, the cost is the distance to their first row.
      assert_in_delta :boids_field.distance(field, {30.5, 10.5}), 30.0, 1.0e-3
    end
  end

  describe "with walls" do
    test "the distance is near the cost of a search of 8 directions, and not less than the straight distance" do
      for {grid, goals} <- [
            {blocks(), [{12, 20}]},
            {wall(), [{8, 3}]},
            {blocks(), [{1, 1}, {62, 62}, {40, 20}]}
          ] do
        field = :boids_field.new(grid, goals)
        costs = search(grid, goals)
        {cols, rows} = :boids_grid.size(grid)

        for i <- 0..(cols - 1),
            j <- 0..(rows - 1),
            not :boids_grid.blocked(grid, {i, j}),
            {i, j} not in goals do
          cost = :boids_field.distance(field, {i + 0.5, j + 0.5})
          assert_in_delta cost / costs[{i, j}], 1.0, 0.15
          straight = Enum.min(for {gi, gj} <- goals, do: :boids_vec.dist({i, j}, {gi, gj}))
          assert cost >= straight * (1 - 1.0e-5)
        end
      end
    end

    test "the ways are near the shortest ways: 3 % longer on average at most" do
      field = :boids_field.new(blocks(), [{12, 20}])
      best = shortest({12.5, 20.5})
      :rand.seed(:exsss, {1, 2, 3})

      places =
        Stream.repeatedly(fn -> {:rand.uniform() * 63 + 0.5, :rand.uniform() * 63 + 0.5} end)
        |> Stream.filter(&(:boids_grid.walkable(blocks(), &1) and :boids_vec.dist(&1, {12.5, 20.5}) > 6))
        |> Enum.take(100)

      ratios =
        for place <- places do
          way = :boids_field.path(field, place)
          assert hd(way) == place and List.last(way) == {12.5, 20.5}
          length_of(way) / best.(place)
        end

      # A search of 8 directions gives ways that are 5 % longer.
      assert Enum.sum(ratios) / 100 < 1.03
      assert Enum.max(ratios) < 1.10
      assert Enum.min(ratios) > 0.999
    end

    test "a direction does not go into a blocked cell, and not across the corner of one" do
      grid = blocks()
      field = :boids_field.new(grid, [{12, 20}])
      :rand.seed(:exsss, {3, 2, 1})
      centers = for i <- 0..63, j <- 0..63, do: {i + 0.5, j + 0.5}
      places = for _ <- 1..3000, do: {:rand.uniform() * 64, :rand.uniform() * 64}

      for {x, y} = place <- centers ++ places,
          :boids_grid.walkable(grid, place),
          {12, 20} != :boids_grid.cell(grid, place) do
        {dx, dy} = :boids_field.direction(field, place)
        assert_in_delta :boids_vec.norm({dx, dy}), 1.0, 1.0e-9
        # A move of half a cell, and all the cells that it touches.
        assert :boids_grid.hit(grid, place, {x + dx * 0.5, y + dy * 0.5}) == :none
      end
    end

    test "near a wall, the direction goes to the center of the next cell of the way" do
      # The way from the cell {3, 1} to the goal goes up, around the wall.
      field = :boids_field.new(wall(), [{8, 3}])
      assert :boids_field.direction(field, {3.5, 1.5}) == {0.0, -1.0}
      # Near the corner of the wall, the mean of the directions goes
      # into the wall. The direction is to the center of the cell above,
      # so the boid goes around the corner.
      to_center = :boids_vec.normalize({3.5 - 3.95, 0.5 - 1.05})
      assert_vec(:boids_field.direction(field, {3.95, 1.05}), to_center)
      # Away from the wall, the direction is the mean of the cells.
      assert {dx, dy} = :boids_field.direction(field, {3.2, 1.05})
      assert dx > 0.3 and dy < -0.3
    end

    test "in a narrow way, the direction brings a boid back to the middle" do
      # A way of one cell between two walls, and a goal at its right end.
      grid = :boids_grid.from_rows(["########", "........", "########"], [])
      field = :boids_field.new(grid, [{7, 1}])
      assert :boids_field.direction(field, {2.5, 1.5}) == {1.0, 0.0}
      assert {dx, dy} = :boids_field.direction(field, {2.5, 1.1})
      assert dx > 0.9 and dy > 0.3
      assert {dx, dy} = :boids_field.direction(field, {2.9, 1.95})
      assert dx > 0.7 and dy < -0.5
      # A boid that follows the direction comes to the middle line.
      {_x, y} =
        Enum.reduce(1..20, {0.5, 1.9}, fn _, {x, y} ->
          {dx, dy} = :boids_field.direction(field, {x, y})
          {x + dx * 0.2, y + dy * 0.2}
        end)

      assert_in_delta y, 1.5, 0.05
    end

    test "a cell across the corner of a blocked cell has no part in the mean" do
      # Two rooms that touch at a corner, with no way between them there.
      grid = :boids_grid.from_rows(["..#", "..#", "##."], [])
      field = :boids_field.new(grid, [{0, 0}])
      assert :boids_field.distance(field, {2.5, 2.5}) == :infinity
      assert_in_delta :boids_field.distance(field, {1.99, 1.99}), :math.sqrt(2), 1.0e-4
      assert {dx, dy} = :boids_field.direction(field, {1.99, 1.99})
      assert_vec({dx, dy}, {-:math.sqrt(0.5), -:math.sqrt(0.5)}, 0.01)
    end

    test "between two goals, the direction is to the goal of the cell" do
      field = :boids_field.new(:boids_grid.new(size: {4, 1}), [{0, 0}, {3, 0}], exact: 0)
      assert :boids_field.direction(field, {1.5, 0.5}) == {-1.0, 0.0}
      assert :boids_field.direction(field, {2.5, 0.5}) == {1.0, 0.0}
      assert :boids_field.direction(field, {2.0, 0.5}) == {1.0, 0.0}
      assert_in_delta :boids_field.distance(field, {2.0, 0.5}), 1.0, 1.0e-6
      # In open land, at the side between the two cells, the mean of
      # their directions is zero: the direction is that of the cell.
      wide = :boids_field.new(:boids_grid.new(size: {4, 3}), [{0, 1}, {3, 1}], exact: 0)
      assert :boids_field.direction(wide, {2.0, 1.5}) == {1.0, 0.0}
      assert :boids_field.direction(wide, {1.999, 1.5}) == {-1.0, 0.0}
    end
  end

  describe "with costs" do
    test "a way goes around a region of high cost when that costs less" do
      # A swamp between the start and the goal, and a way around it.
      swamp = for i <- 8..11, j <- 0..14, do: {{i, j}, 5}
      grid = :boids_grid.new(size: {20, 20}, costs: swamp)
      field = :boids_field.new(grid, [{17, 5}])
      way = :boids_field.path(field, {2.5, 5.5})
      assert List.last(way) == {17.5, 5.5}
      refute Enum.any?(way, fn place -> :boids_grid.cost(grid, :boids_grid.cell(grid, place)) == 5.0 end)
      assert Enum.any?(way, fn {_x, y} -> y > 15.0 end)
      # The cost is less than the cost through the swamp.
      assert :boids_field.distance(field, {2.5, 5.5}) < 6 + 4 * 5 + 5

      # A swamp with no way around it: the way goes through.
      band = for i <- 8..11, j <- 0..19, do: {{i, j}, 5}
      through = :boids_field.new(:boids_grid.new(size: {20, 20}, costs: band), [{17, 5}])
      assert [{2.5, 5.5}, {17.5, 5.5}] = :boids_field.path(through, {2.5, 5.5})
      assert_in_delta :boids_field.distance(through, {2.5, 5.5}), 11 + 4 * 5, 0.5
    end

    test "the cost of a cell multiplies the distance" do
      for cost <- [0.01, 3, 250.0] do
        grid = :boids_grid.new(size: {30, 30}, costs: for(i <- 0..29, j <- 0..29, do: {{i, j}, cost}))
        field = :boids_field.new(grid, [{5, 5}])
        assert_in_delta :boids_field.distance(field, {25.5, 5.5}), 20 * cost, 1.0e-3 * cost
        assert_in_delta :boids_field.distance(field, {8.5, 9.5}), 5 * cost, 1.0e-3 * cost
        way = :boids_field.path(field, {25.5, 20.5})
        assert_in_delta length_of(way), 25.0, 0.01
      end
    end

    test "a goal in a region of high cost near a goal of low cost gives its cells to the other goal" do
      # The left half has the cost 9. The goal {9, 10} is in it, 2 cells
      # from the goal {12, 10} of the right half.
      costs = for i <- 0..10, j <- 0..20, do: {{i, j}, 9}
      grid = :boids_grid.new(size: {22, 21}, costs: costs)
      field = :boids_field.new(grid, [{4, 10}, {12, 10}])
      # The cell {9, 10} is in the clear square of the first goal, at 5
      # cells of the cost 9. The other goal is nearer in cost.
      assert :boids_field.distance(field, {9.5, 10.5}) < 3 * 9
      assert {dx, _dy} = :boids_field.direction(field, {9.5, 10.5})
      assert dx > 0.9
      # A cell near the first goal goes to it.
      assert_in_delta :boids_field.distance(field, {5.5, 10.5}), 9.0, 1.0e-3
      assert :boids_field.direction(field, {5.5, 10.5}) == {-1.0, 0.0}
    end

    test "costs that are very different give the same result as costs that are near" do
      # A way with one cell of a very high cost: the next values are in
      # a bucket that is far.
      rows = fn high -> ["...#...", "...#...", "..." <> high <> "...", "...#..."] end
      near = :boids_field.new(:boids_grid.from_rows(rows.("9"), []), [{0, 0}])
      blocked = for j <- [0, 1, 3], do: {3, j}

      far =
        :boids_field.new(:boids_grid.new(size: {7, 4}, blocked: blocked, costs: [{{3, 2}, 2000}]), [{0, 0}])

      # A step into a cell costs the cost of that cell.
      to_door = :math.sqrt(8)
      assert_in_delta :boids_field.distance(near, {3.5, 2.5}), to_door + 9, 1.0e-3
      assert_in_delta :boids_field.distance(far, {3.5, 2.5}), to_door + 2000, 1.0e-2
      assert_in_delta :boids_field.distance(far, {4.5, 2.5}), to_door + 2001, 1.0e-2

      for place <- [{4.5, 2.5}, {5.5, 1.5}, {6.5, 0.5}, {6.5, 3.5}] do
        assert_in_delta :boids_field.distance(far, place) - 2000,
                        :boids_field.distance(near, place) - 9,
                        1.0e-2

        assert_vec(:boids_field.direction(far, place), :boids_field.direction(near, place), 0.02)
      end

      assert :boids_field.direction(far, {4.5, 2.5}) == {-1.0, 0.0}
    end
  end

  describe "with more than one goal" do
    test "each place goes to the goal that costs the least" do
      goals = [{5, 5}, {40, 40}, {50, 8}]
      field = :boids_field.new(open(64), goals)
      :rand.seed(:exsss, {5, 5, 5})

      for _ <- 1..200 do
        place = {:rand.uniform() * 63 + 0.5, :rand.uniform() * 63 + 0.5}

        [{nearest, goal}, {second, _} | _] =
          Enum.sort(for {i, j} <- goals, do: {:boids_vec.dist(place, {i + 0.5, j + 0.5}), {i, j}})

        assert_in_delta :boids_field.distance(field, place), nearest, 0.04 * nearest + 0.5

        # Not at the line between two goals: the way ends at the nearest goal.
        if second - nearest > 3 do
          {i, j} = goal
          assert List.last(:boids_field.path(field, place)) == {i + 0.5, j + 0.5}
        end
      end
    end

    test "a region of goals: the distance is to its nearest cell" do
      # The goals are the right side of the land.
      goals = for j <- 0..19, do: {19, j}
      field = :boids_field.new(open(20), goals)

      for i <- 0..18, j <- 0..19 do
        assert_in_delta :boids_field.distance(field, {i + 0.5, j + 0.5}), 19 - i, 0.02
        assert_vec(:boids_field.direction(field, {i + 0.5, j + 0.5}), {1.0, 0.0}, 0.02)
      end

      assert :boids_field.direction(field, {19.5, 7.5}) == {0.0, 0.0}
      assert [{3.5, 7.5}, {19.5, 7.5}] = :boids_field.path(field, {3.5, 7.5})
      # Two goals beside each other: the way ends at the first that it touches.
      pair = :boids_field.new(open(20), [{10, 10}, {11, 10}])
      assert List.last(:boids_field.path(pair, {2.5, 10.5})) == {10.5, 10.5}
      assert List.last(:boids_field.path(pair, {18.5, 10.5})) == {11.5, 10.5}
    end
  end

  describe "a place with no way" do
    # A room with no door, and the land around it.
    @room [".......", ".#####.", ".#...#.", ".#...#.", ".#####.", "......."]

    test "an open cell with no way has no direction, a distance of infinity, and an empty way" do
      grid = :boids_grid.from_rows(@room, [])
      field = :boids_field.new(grid, [{0, 0}])

      for place <- [{3.5, 2.5}, {2.1, 3.9}, {4.9, 2.1}] do
        assert :boids_grid.walkable(grid, place)
        refute :boids_field.has_way(field, place)
        assert :boids_field.direction(field, place) == {0.0, 0.0}
        assert :boids_field.distance(field, place) == :infinity
        assert :boids_field.path(field, place) == []
      end

      # The land around the room has ways.
      assert :boids_field.has_way(field, {6.5, 5.5})
      assert :boids_field.has_way(field, {0.5, 0.5})
      assert :boids_field.distance(field, {6.5, 5.5}) < 12
      assert List.last(:boids_field.path(field, {6.5, 5.5})) == {0.5, 0.5}
      # A goal in the room: the land has no way.
      room = :boids_field.new(grid, [{3, 3}])
      assert :boids_field.distance(room, {0.5, 0.5}) == :infinity
      assert :boids_field.direction(room, {0.5, 0.5}) == {0.0, 0.0}
      assert_in_delta :boids_field.distance(room, {2.5, 2.5}), :math.sqrt(2), 1.0e-4
    end

    test "a blocked cell has the direction out of it, to the nearest open cell with a way" do
      grid = :boids_grid.from_rows(@room, [])
      field = :boids_field.new(grid, [{0, 0}])

      # In the wall of the room: out to the land, not into the room,
      # which has no way.
      for {place, to} <- [
            {{1.5, 1.4}, {1.5, 0.5}},
            {{1.2, 2.5}, {0.5, 2.5}},
            {{5.6, 3.5}, {6.5, 3.5}},
            {{3.5, 4.6}, {3.5, 5.5}}
          ] do
        refute :boids_grid.walkable(grid, place)
        refute :boids_field.has_way(field, place)
        assert_vec(:boids_field.direction(field, place), :boids_vec.normalize(:boids_vec.sub(to, place)))
        assert :boids_field.distance(field, place) == :infinity
        assert :boids_field.path(field, place) == []
      end

      # At the same distance from two cells: one of them, the same each time.
      assert :boids_field.direction(field, {1.5, 1.5}) == {-1.0, 0.0}
      # The cell of a goal is such a cell too.
      door = :boids_field.new(:boids_grid.from_rows(["..#.."], []), [{3, 0}])
      assert :boids_field.direction(door, {2.9, 0.5}) == {1.0, 0.0}
    end

    test "a place outside the grid has the direction to the grid, at 3 cells or less" do
      grid = :boids_grid.from_rows(@room, [])
      field = :boids_field.new(grid, [{0, 0}])
      assert_vec(:boids_field.direction(field, {-0.5, 0.5}), {1.0, 0.0})
      assert_vec(:boids_field.direction(field, {3.5, 6.2}), {0.0, -1.0})
      assert_vec(:boids_field.direction(field, {7.5, -0.5}), {-:math.sqrt(0.5), :math.sqrt(0.5)})
      assert_vec(:boids_field.direction(field, {-2.5, 2.5}), {1.0, 0.0})
      # At more than 3 cells: no direction.
      assert :boids_field.direction(field, {-3.5, 2.5}) == {0.0, 0.0}
      assert :boids_field.direction(field, {3.5, 9.5}) == {0.0, 0.0}

      for place <- [{-0.5, 0.5}, {3.5, 6.2}, {-3.5, 2.5}] do
        refute :boids_field.has_way(field, place)
        assert :boids_field.distance(field, place) == :infinity
        assert :boids_field.path(field, place) == []
      end
    end

    test "a blocked cell at more than 3 cells from each open cell with a way has no direction" do
      # A block of 9 x 9 cells in a land of 11 x 11.
      grid = :boids_grid.new(size: {11, 11}, blocked: for(i <- 1..9, j <- 1..9, do: {i, j}))
      field = :boids_field.new(grid, [{0, 0}])
      assert :boids_field.direction(field, {5.5, 5.5}) == {0.0, 0.0}
      assert :boids_field.direction(field, {4.5, 6.5}) == {0.0, 0.0}
      # At 3 cells from the land at its left.
      assert_vec(:boids_field.direction(field, {3.5, 5.5}), {-1.0, 0.0})
      assert_vec(:boids_field.direction(field, {2.2, 8.5}), :boids_vec.normalize({0.5 - 2.2, 0.0}))
    end
  end

  describe "path/2" do
    test "gives the points where the way turns, and no point on a straight part" do
      field = :boids_field.new(wall(), [{8, 3}])
      way = :boids_field.path(field, {0.5, 3.5})
      assert hd(way) == {0.5, 3.5} and List.last(way) == {8.5, 3.5}
      assert length(way) in 3..8
      # The way goes over the wall, and each point is in an open cell.
      assert Enum.any?(way, fn {_x, y} -> y < 1.0 end)
      assert Enum.all?(way, &:boids_grid.walkable(wall(), &1))
      # The cost goes down along the way.
      costs = Enum.map(way, &:boids_field.distance(field, &1))
      assert costs == Enum.sort(costs, :desc)
      # The cost is near the length of the way, and not less.
      assert_in_delta :boids_field.distance(field, {0.5, 3.5}) / length_of(way), 1.08, 0.08
    end

    test "the lines of the way are in open cells, a tenth of a cell from a wall at most" do
      grid = blocks()
      field = :boids_field.new(grid, [{12, 20}])
      :rand.seed(:exsss, {6, 6, 6})

      for _ <- 1..60,
          place = {:rand.uniform() * 64, :rand.uniform() * 64},
          :boids_grid.walkable(grid, place) do
        way = :boids_field.path(field, place)

        for [{ax, ay}, {bx, by}] <- Enum.chunk_every(way, 2, 1, :discard), part <- 0..20 do
          on = {ax + (bx - ax) * part / 20, ay + (by - ay) * part / 20}

          assert :boids_grid.walkable(grid, on) or
                   :boids_vec.dist(on, :boids_grid.nearest(grid, on)) <= 0.1 + 1.0e-6
        end
      end
    end

    test "is for the rule follow" do
      grid = wall(cell_size: 2)
      field = :boids_field.new(grid, [{8, 3}])
      way = :boids_field.path(field, {1.0, 7.0})

      boid =
        :boids_boid.new(
          pos: {1.0, 7.0},
          max_speed: 4.0,
          rules: [{:follow, 1.0, path: way, ahead: 1.5}],
          walkable: {:named, :land}
        )

      arrived =
        Enum.reduce(1..150, boid, fn _, boid -> :boids_boid.step(boid, [], %{grids: %{land: grid}}, 0.1) end)

      assert :boids_vec.dist(arrived.pos, {17.0, 7.0}) < 2.0
    end
  end

  describe "the time" do
    test "is in proportion to the number of the cells" do
      # The reductions of the process are the work of the calculation:
      # they do not change with the other work of the computer.
      work = fn size ->
        blocked = fn {x, y} -> rem(floor(x), 16) == 7 and rem(floor(y), 11) != 3 end
        grid = :boids_grid.new(size: {size, size}, blocked: blocked)
        {:reductions, before} = Process.info(self(), :reductions)
        {time, field} = :timer.tc(fn -> :boids_field.new(grid, [{div(size, 5), div(size, 5)}]) end)
        {:reductions, later} = Process.info(self(), :reductions)
        assert :boids_field.distance(field, {size - 1.5, size - 1.5}) != :infinity
        {later - before, time}
      end

      {small, _} = work.(100)
      {large, time} = work.(200)
      # 200 x 200 cells: 3 million reductions, and 35 milliseconds on a
      # computer with no other work. A heap needs 4 times that.
      assert large < 6_000_000
      assert large < 5 * small
      assert time < 2_000_000
    end
  end

  describe "the rule flow with a field of a world" do
    defp walker(opts) do
      rules = [{:flow, 1.0, field: {:named, :exit}}]
      :boids_boid.new(Map.merge(%{pos: {0.5, 3.5}, max_speed: 4.0, rules: rules}, Map.new(opts)))
    end

    defp flow(boid, seen) do
      {[{:flow, force}], _boid} = :boids_boid.forces(boid, [], Map.merge(%{dt: 0.1}, seen))
      force
    end

    test "has the name of a field as its option: a fact of the world that the boid uses" do
      assert :boids_boid.named(walker(%{})) == [field: :exit]
      assert :boids_boid.named(walker(walkable: {:named, :land})) == [grid: :land, field: :exit]

      rules = [
        {{:flow, :out}, 1.0, field: {:named, :exit}},
        {:separation, 1.5},
        {{:flow, :eat}, 2.0, field: {:named, {:food, 2}}, predict: 1},
        {{:flow, :wind}, 0.5, field: {1.0, 0.0}}
      ]

      assert :boids_boid.named(walker(rules: rules)) == [field: :exit, field: {:food, 2}]
      # A change of the rules changes the facts.
      assert :boids_boid.named(:boids_boid.update(walker(%{}), %{rules: [{:cruise, 1.0}]})) == []

      for bad <- [:exit, {:named}, {:name, :exit}, {:named, :exit, 2}, wall()] do
        rule = {:flow, 1.0, %{field: bad}}
        assert catch_error(walker(rules: [rule])) == {:bad_option, {:rules, rule}}
      end
    end

    test "a boid with three dimensions cannot have a field of a world" do
      rule = {:flow, 1.0, %{field: {:named, :exit}}}
      assert catch_error(:boids_boid.new(pos: {0, 0, 0}, rules: [rule])) == {:bad_option, {:rules, rule}}
      # A vector and a function are fields for three dimensions too.
      assert %{} = :boids_boid.new(pos: {0, 0, 0}, rules: [{:flow, 1.0, field: {0, 0, 1}}])
      assert %{} = :boids_boid.new(pos: {0, 0, 0}, rules: [{:flow, 1.0, field: fn _pos -> {0, 0, 1} end}])
    end

    test "gives the force to the direction of the field at the place ahead of the boid" do
      field = :boids_field.new(wall(), [{8, 3}])
      seen = %{fields: %{exit: field}}
      # A boid that does not move: the place ahead is its position.
      still = walker(pos: {2.5, 3.5})
      assert flow(still, seen) == :boids_steer.flow(still, :boids_field.direction(field, {2.5, 3.5}))
      assert elem(flow(still, seen), 1) < -2.0
      # The place ahead is where the boid is after half a second.
      moving = walker(pos: {2.5, 2.5}, vel: {0.0, -4.0})
      assert flow(moving, seen) == :boids_steer.flow(moving, :boids_field.direction(field, {2.5, 0.5}))
      refute flow(moving, seen) == :boids_steer.flow(moving, :boids_field.direction(field, {2.5, 2.5}))
      # The option predict changes that time.
      now =
        walker(pos: {2.5, 2.5}, vel: {0.0, -4.0}, rules: [{:flow, 1.0, field: {:named, :exit}, predict: 0}])

      assert flow(now, seen) == :boids_steer.flow(now, :boids_field.direction(field, {2.5, 2.5}))
      # The weight of the rule multiplies the force.
      double = walker(pos: {2.5, 3.5}, rules: [{:flow, 2.0, field: {:named, :exit}}])
      assert_vec(flow(double, seen), :boids_vec.scale(flow(still, seen), 2.0))
    end

    test "uses the place of the boid when the place ahead has no direction" do
      field = :boids_field.new(wall(), [{8, 3}])
      seen = %{fields: %{exit: field}}
      up = {0.0, -1.0}
      assert :boids_field.direction(field, {3.5, 2.5}) == up
      # Ahead is the wall.
      at_wall = walker(pos: {3.5, 2.5}, vel: {2.0, 0.0})
      refute :boids_field.has_way(field, {4.5, 2.5})
      assert flow(at_wall, seen) == :boids_steer.flow(at_wall, up)
      # Ahead is out of the grid.
      out = walker(pos: {3.5, 2.5}, vel: {0.0, 4.0})
      assert flow(out, seen) == :boids_steer.flow(out, up)
      # Ahead is the goal: the boid continues to it.
      near = walker(pos: {6.6, 3.5}, vel: {4.0, 0.0})
      assert :boids_field.direction(field, {8.6, 3.5}) == {0.0, 0.0}
      assert flow(near, seen) == :boids_steer.flow(near, {1.0, 0.0})
      # At the goal: no force.
      assert flow(walker(pos: {8.5, 3.5}), seen) == {0.0, 0.0}
      assert flow(walker(pos: {8.5, 3.5}, vel: {0.5, 0.0}), seen) == {0.0, 0.0}
      # A boid in the wall gets the direction out of it.
      in_wall = walker(pos: {4.3, 2.5})
      assert flow(in_wall, seen) == :boids_steer.flow(in_wall, {-1.0, 0.0})
      # Far out of the grid: no force.
      assert flow(walker(pos: {4.5, -9.5}), seen) == {0.0, 0.0}
      # A boid that goes through the goal: the place ahead brings it back.
      through = walker(pos: {8.5, 3.5}, vel: {2.0, 0.0})
      assert flow(through, seen) == :boids_steer.flow(through, {-1.0, 0.0})
    end

    test "a name with no field, and a step with no fields, give no force" do
      field = :boids_field.new(wall(), [{8, 3}])
      boid = walker(pos: {2.5, 3.5}, vel: {1.0, 0.0})
      assert flow(boid, %{fields: %{food: field}}) == {0.0, 0.0}
      assert flow(boid, %{fields: %{}}) == {0.0, 0.0}
      assert flow(boid, %{}) == {0.0, 0.0}
      # A step moves the boid with its velocity only.
      assert %{pos: {2.6, 3.5}} = :boids_boid.step(boid, [], %{}, 0.1)
      assert %{pos: {x, y}} = :boids_boid.step(boid, [], %{fields: %{exit: field}}, 0.1)
      assert y < 3.5 and x > 2.5
    end
  end

  describe "a world with a field" do
    defmodule Walker do
      # A boid that sends what it perceives to the process of its argument.
      @behaviour :gen_boid

      @impl true
      def init({test, options}),
        do: {:ok, Map.merge(%{rules: [], tick: :manual, state: test}, Map.new(options))}

      @impl true
      def handle_sense(seen, %{state: test} = boid) do
        send(test, {:seen, seen})
        {:ok, seen, boid}
      end
    end

    # A maze of 12 x 9 cells. The goal is in its center.
    @maze [
      "............",
      ".##########.",
      ".#..........",
      ".#.########.",
      ".#.#......#.",
      ".#.#.####.#.",
      ".#...#....#.",
      ".#####.####.",
      "............"
    ]

    defp world(opts) do
      {:ok, world} = :boids.start_world(opts)
      on_exit(fn -> :boids.stop_world(world) end)
      world
    end

    defp goer(more) do
      Map.merge(
        %{rules: [{:flow, 1.0, field: {:named, :exit}}], max_speed: 4.0, max_force: 40.0, tick: :manual},
        more
      )
    end

    test "has fields with a name: set_field/3, field/2 and remove_field/2" do
      world = world(%{})
      grid = wall()
      field = :boids_field.new(grid, [{8, 3}])
      assert :boids.field(world, :exit) == :error
      assert :boids.set_field(world, :exit, field) == :ok
      assert :boids.field(world, :exit) == {:ok, field}
      assert :boids.set_field(world, {:food, 2}, :boids_field.new(grid, [{0, 0}])) == :ok
      # A value that is not a field is an error of the caller, and the world continues.
      assert_raise ArgumentError, fn -> :boids.set_field(world, :exit, grid) end
      assert_raise ArgumentError, fn -> :boids.set_field(world, :exit, {:boids_field, 1}) end
      assert :boids.field(world, :exit) == {:ok, field}
      assert :boids.remove_field(world, :exit) == :ok
      assert :boids.field(world, :exit) == :error
      assert {:ok, _} = :boids.field(world, {:food, 2})
      # A field with the name of a grid: the two are different facts.
      :ok = :boids.set_grid(world, {:food, 2}, grid)
      assert {:ok, ^grid} = :boids.grid(world, {:food, 2})
      assert {:ok, food} = :boids.field(world, {:food, 2})
      assert :boids_field.goals(food) == [{0, 0}]
    end

    test "a boid in a maze gets to the goal" do
      grid = :boids_grid.from_rows(@maze, cell_size: 2)
      world = world(bounds: {{0, 0}, {24, 18}}, defaults: %{walkable: {:named, :maze}})
      :ok = :boids.set_grid(world, :maze, grid)
      :ok = :boids.set_field(world, :exit, :boids_field.new(grid, [{6, 6}]))
      # From the maze, from its two ends, and from two corners of the land.
      starts = [{9.0, 9.0}, {5.0, 5.0}, {21.0, 5.0}, {1.0, 17.0}, {23.0, 1.0}]
      ids = for pos <- starts, do: elem(:boids.add(world, goer(%{pos: pos})), 1)
      for _ <- 1..600, do: :ok = :boids.step(world, 0.1)

      for id <- ids do
        {:ok, %{pos: pos}} = :boids.lookup(world, id)
        assert :boids_vec.dist(pos, {13.0, 13.0}) < 2.0
      end
    end

    test "boids with a field, a grid and neighbors go around a wall to a door" do
      # A wall with a door of two cells. The boids start at its left, and the goal is at its right.
      grid = :boids_grid.new(size: {40, 30}, blocked: for(j <- 0..29, j not in [14, 15], do: {20, j}))
      world = world(bounds: {{0, 0}, {40, 30}}, defaults: %{walkable: {:named, :land}})
      :ok = :boids.set_grid(world, :land, grid)
      :ok = :boids.set_field(world, :exit, :boids_field.new(grid, [{35, 5}]))
      rules = [{:flow, 1.0, field: {:named, :exit}}, {:separation, 1.5, radius: 0.7}]

      {:ok, ids} =
        :boids.populate(world, 30, goer(%{area: {{2, 2}, {15, 28}}, rules: rules, perception: 2.0}))

      for _ <- 1..400 do
        :ok = :boids.step(world, 0.1)
        assert Enum.all?(:boids.snapshot(world), fn %{pos: pos} -> :boids_grid.walkable(grid, pos) end)
      end

      # All the boids are through the door, near the goal.
      for id <- ids do
        {:ok, %{pos: pos}} = :boids.lookup(world, id)
        assert :boids_vec.dist(pos, {35.5, 5.5}) < 6.0
      end
    end

    test "a boid with no limit that is in a wall comes out, and goes on to the goal" do
      # A wall of 3 cells with a door. The boid has no option walkable.
      grid =
        :boids_grid.new(size: {30, 20}, blocked: for(i <- 14..16, j <- 0..19, j not in [9, 10], do: {i, j}))

      world = world(bounds: {{0, 0}, {30, 20}})
      :ok = :boids.set_field(world, :exit, :boids_field.new(grid, [{25, 15}]))
      {:ok, id} = :boids.add(world, goer(%{pos: {15.2, 3.5}}))
      place = fn -> elem(:boids.lookup(world, id), 1).pos end
      refute :boids_grid.walkable(grid, place.())
      for _ <- 1..20, do: :ok = :boids.step(world, 0.1)
      # It came out at the side of the wall that was the nearest: the left.
      assert :boids_grid.walkable(grid, place.())
      assert elem(place.(), 0) < 14.0
      for _ <- 1..300, do: :ok = :boids.step(world, 0.1)
      assert :boids_vec.dist(place.(), {25.5, 15.5}) < 2.5
    end

    test "a boid gets its fields in what it perceives, and a boid with no name gets none" do
      world = world(bounds: {{0, 0}, {10, 4}})
      field = :boids_field.new(wall(), [{8, 3}])
      :ok = :boids.set_field(world, :exit, field)
      :ok = :boids.set_field(world, :food, :boids_field.new(wall(), [{0, 0}]))
      {:ok, _} = :gen_boid.start(world, Walker, {self(), goer(%{pos: {1, 1}})})
      :ok = :boids.step(world, 0.1)
      assert_receive {:seen, %{fields: fields, grids: grids}}
      assert fields == %{exit: field}
      assert grids == %{}

      world2 = world(%{})
      {:ok, _} = :gen_boid.start(world2, Walker, {self(), %{pos: {1, 1}}})
      :ok = :boids.step(world2, 0.1)
      assert_receive {:seen, %{fields: fields}}
      assert fields == %{}
    end

    test "after a change of the field, the boids take the new way at their next step" do
      grid = open(20)
      world = world(bounds: {{0, 0}, {20, 20}})
      :ok = :boids.set_field(world, :exit, :boids_field.new(grid, [{0, 10}]))
      # With this mass, a boid has the velocity of its rule after one step.
      {:ok, id} = :boids.add(world, goer(%{pos: {10.5, 10.5}, mass: 0.1}))
      velocity = fn -> elem(:boids.lookup(world, id), 1).vel end
      :ok = :boids.step(world, 0.1)
      assert_vec(velocity.(), {-4.0, 0.0}, 0.05)
      # The goal is now at the other side.
      :ok = :boids.set_field(world, :exit, :boids_field.new(grid, [{19, 10}]))
      :ok = :boids.step(world, 0.1)
      assert_vec(velocity.(), {4.0, 0.0}, 0.05)
      # With no field for its name, the boid has no force: it keeps its velocity.
      :ok = :boids.remove_field(world, :exit)
      for _ <- 1..5, do: :ok = :boids.step(world, 0.1)
      assert_vec(velocity.(), {4.0, 0.0}, 0.05)
    end

    test "a boid keeps the field that it read: it is not in the boid, and not in its row" do
      world = world(bounds: {{0, 0}, {10, 4}})
      field = :boids_field.new(wall(), [{8, 3}])
      :ok = :boids.set_field(world, :exit, field)
      {:ok, id} = :boids.add(world, goer(%{pos: {1, 1}}))
      :ok = :boids.step(world, 0.1)
      {:ok, boid} = :boids.boid(world, id)
      {:ok, row} = :boids.lookup(world, id)
      refute :erlang.term_to_binary({boid, row}) =~ "boids_field"
      # The process of the boid keeps it in its state, with the number of
      # the changes of the world at that read.
      pid = :boids.whereis(world, id)
      assert %{kept: {1, [field: :exit], %{fields: %{exit: ^field}}} = kept} = :sys.get_state(pid)
      # With no change, the boid does not read the table again.
      for _ <- 1..5, do: :ok = :boids.step(world, 0.1)
      assert :sys.get_state(pid).kept == kept
      # A change of another fact of the world: the boid reads its field again.
      :ok = :boids.set_field(world, :food, field)
      :ok = :boids.step(world, 0.1)
      assert %{kept: {2, [field: :exit], %{fields: %{exit: ^field}}}} = :sys.get_state(pid)
    end

    test "a boid with its own clock goes down the field too" do
      # A wall with a door, in a small land. The time of the world is 4
      # times as fast, so the test is short.
      grid = :boids_grid.new(size: {12, 8}, blocked: for(j <- 0..7, j not in [3, 4], do: {6, j}))
      world = world(bounds: {{0, 0}, {12, 8}}, defaults: %{walkable: {:named, :land}})
      :ok = :boids.set_grid(world, :land, grid)
      :ok = :boids.set_field(world, :exit, :boids_field.new(grid, [{10, 1}]))
      :ok = :boids.set_time_scale(world, 4.0)
      {:ok, ids} = :boids.populate(world, 5, goer(%{area: {{1, 1}, {5, 7}}, mass: 0.2, tick: 5}))

      assert eventually(fn ->
               Enum.all?(ids, fn id ->
                 :boids_vec.dist(elem(:boids.lookup(world, id), 1).pos, {10.5, 1.5}) < 1.5
               end)
             end)
    end
  end

  describe "a process with another behavior" do
    test "plan/3 and advance/3 use the fields of the world, and the process keeps them" do
      {:ok, world} = :boids.start_world(%{bounds: {{0, 0}, {10, 4}}})
      on_exit(fn -> :boids.stop_world(world) end)
      field = :boids_field.new(wall(), [{8, 3}])
      :ok = :boids.set_field(world, :exit, field)
      # The grid keeps the boid in the land: out of the grid, a field has
      # no direction.
      :ok = :boids.set_grid(world, :land, wall())
      rules = [{:flow, 1.0, field: {:named, :exit}}]
      options = [pos: {1.5, 3.5}, max_speed: 4.0, mass: 0.2, rules: rules, walkable: {:named, :land}]
      {:ok, space, boid} = :boids.join(world, options)
      planned = :boids.plan(space, boid, 0.1)
      # The way is up, around the wall.
      assert elem(planned.vel, 1) < -0.2

      assert {2, [grid: :land, field: :exit], %{fields: %{exit: ^field}}} =
               Process.get({:boids_space, :kept, space.facts})

      arrived = Enum.reduce(1..100, boid, fn _, boid -> :boids.advance(space, boid, 0.1) end)
      assert :boids_vec.dist(arrived.pos, {8.5, 3.5}) < 1.0
      assert :boids.leave(space, arrived) == :ok
      assert Process.get({:boids_space, :kept, space.facts}) == nil
    end
  end

  property "each open cell with a way to a goal has a direction, and its way ends at a goal" do
    check all(
            cols <- integer(2..12),
            rows <- integer(2..12),
            cells <- list_of(member_of([:open, :open, :open, :blocked, :high]), length: cols * rows),
            goal_at <- integer(0..(cols * rows - 1)),
            exact <- member_of([0, 2, 8]),
            uniform <- boolean(),
            max_runs: 150
          ) do
      # In a half of the runs, all the open cells have one cost.
      kinds =
        cells
        |> List.replace_at(goal_at, :open)
        |> Enum.map(fn kind -> if uniform and kind == :high, do: :open, else: kind end)
        |> Enum.with_index(fn kind, at -> {{rem(at, cols), div(at, cols)}, kind} end)

      goal = {rem(goal_at, cols), div(goal_at, cols)}

      grid =
        :boids_grid.new(
          size: {cols, rows},
          blocked: for({cell, :blocked} <- kinds, do: cell),
          costs: for({cell, :high} <- kinds, do: {cell, 4})
        )

      field = :boids_field.new(grid, [goal], exact: exact)
      reached = search(grid, [goal])

      for {{i, j} = cell, _kind} <- kinds, center = {i + 0.5, j + 0.5} do
        way = :boids_field.path(field, center)

        cond do
          cell == goal ->
            assert :boids_field.direction(field, center) == {0.0, 0.0}
            assert way == [center]

          is_map_key(reached, cell) ->
            # A search of 8 directions with no cut of a corner gets to
            # the same cells as the field.
            {dx, dy} = :boids_field.direction(field, center)
            assert_in_delta :boids_vec.norm({dx, dy}), 1.0, 1.0e-9
            assert :boids_grid.hit(grid, center, {i + 0.5 + dx * 0.5, j + 0.5 + dy * 0.5}) == :none
            cost = :boids_field.distance(field, center)
            assert cost > 0
            # With one cost, the cost of the field is near the cost of
            # the search. With cells of high cost, the two are different:
            # the search goes across a corner between two such cells
            # for the cost of its two ends, and the field does not.
            assert not uniform or abs(cost - reached[cell]) <= 0.22 * reached[cell] + 0.01
            assert hd(way) == center and List.last(way) == :boids_grid.center(grid, goal)
            costs = Enum.map(way, &:boids_field.distance(field, &1))
            assert costs == Enum.sort(costs, :desc)

          true ->
            # An open cell with no way has no direction. A blocked cell has
            # the direction to an open cell with a way, or none.
            refute :boids_field.has_way(field, center)
            {dx, dy} = :boids_field.direction(field, center)

            assert {dx, dy} == {0.0, 0.0} or
                     (:boids_grid.blocked(grid, cell) and abs(:boids_vec.norm({dx, dy}) - 1) < 1.0e-9)

            assert :boids_field.distance(field, center) == :infinity
            assert way == []
        end
      end
    end
  end
end
