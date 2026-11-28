defmodule BoidsGridTest do
  use ExUnit.Case, async: true
  import Boids.Helpers

  # A river (the rows 3 and 4) with a bridge (the column 4), and a hill of
  # the cost 3.
  @rows [
    "........",
    "...3....",
    "........",
    "####.###",
    "####.###",
    "........"
  ]

  defp river(opts \\ []), do: :boids_grid.from_rows(@rows, opts)

  describe "new/1 and from_rows/2" do
    test "make the same grid" do
      grid =
        :boids_grid.new(
          size: {8, 6},
          blocked: for(j <- [3, 4], i <- 0..7, i != 4, do: {i, j}),
          costs: [{{3, 1}, 3}]
        )

      assert grid == river()
      assert :boids_grid.is_grid(grid)
      refute :boids_grid.is_grid({:boids_grid, 1})
      assert :boids_grid.size(grid) == {8, 6}
      assert :boids_grid.cell_size(grid) == 1.0
      assert :boids_grid.origin(grid) == {0.0, 0.0}
      assert :boids_grid.bounds(grid) == {{0.0, 0.0}, {8.0, 6.0}}
    end

    test "take the size of a cell, the corner, and the costs as a map" do
      grid = :boids_grid.new(%{size: {2, 3}, cell_size: 2, origin: {-1, 1}, costs: %{{1, 2} => 2.5}})
      assert :boids_grid.bounds(grid) == {{-1.0, 1.0}, {3.0, 7.0}}
      assert :boids_grid.cost(grid, {1, 2}) == 2.5
      assert :boids_grid.cell(grid, {0.0, 6.5}) == {0, 2}
      assert :boids_grid.center(grid, {0, 2}) == {0.0, 6.0}

      rows = :boids_grid.from_rows([<<"9 ">>, ~c"#."], cell_size: 0.5, origin: {1, 1})
      assert :boids_grid.cost(rows, {0, 0}) == 9.0
      assert :boids_grid.cost(rows, {1, 0}) == 1.0
      assert :boids_grid.bounds(rows) == {{1.0, 1.0}, {2.0, 2.0}}
      refute :boids_grid.walkable(rows, {1.2, 1.7})
    end

    test "take a function for the blocked cells, and call it with the center of each cell" do
      # A pond: a circle of radius 2 around {4, 4}.
      pond = fn pos -> :boids_vec.dist(pos, {4.0, 4.0}) < 2.0 end
      grid = :boids_grid.new(size: {8, 8}, blocked: pond)
      cells = for j <- 0..7, i <- 0..7, :boids_grid.blocked(grid, {i, j}), do: {i, j}
      assert cells == for(j <- 0..7, i <- 0..7, pond.({i + 0.5, j + 0.5}), do: {i, j})
      assert length(cells) == 12
      # The function gets each center one time, in the units of the grid.
      me = self()

      :boids_grid.new(
        size: {2, 2},
        cell_size: 10,
        origin: {-10, 0},
        blocked: fn pos ->
          send(me, pos)
          :no
        end
      )

      assert Enum.sort(for(_ <- 1..4, do: receive(do: (pos -> pos)))) ==
               [{-5.0, 5.0}, {-5.0, 15.0}, {5.0, 5.0}, {5.0, 15.0}]

      refute_received _
    end

    test "refuse a bad option" do
      bad = fn fun ->
        try do
          fun.()
          :no_error
        catch
          :error, {:bad_option, option} -> option
        end
      end

      assert bad.(fn -> :boids_grid.new(%{}) end) == {:size, :undefined}
      assert bad.(fn -> :boids_grid.new(size: {0, 3}) end) == {:size, {0, 3}}
      assert bad.(fn -> :boids_grid.new(size: {2, 2}, colour: 1) end) == {:colour, 1}
      assert bad.(fn -> :boids_grid.new(size: {2, 2}, cell_size: 0) end) == {:cell_size, 0}
      assert bad.(fn -> :boids_grid.new(size: {2, 2}, origin: {1}) end) == {:origin, {1}}
      assert bad.(fn -> :boids_grid.new(size: {2, 2}, blocked: {1, 1}) end) == {:blocked, {1, 1}}
      assert bad.(fn -> :boids_grid.new(size: {2, 2}, blocked: [{2, 0}]) end) == {:blocked, {2, 0}}
      assert bad.(fn -> :boids_grid.new(size: {2, 2}, costs: [{{0, 0}, 0}]) end) == {:costs, {{0, 0}, 0}}
      assert bad.(fn -> :boids_grid.new(size: {2, 2}, costs: [{{0, 5}, 1}]) end) == {:costs, {{0, 5}, 1}}
      assert bad.(fn -> :boids_grid.new(size: {2, 2}, costs: [:a]) end) == {:costs, :a}
      assert bad.(fn -> :boids_grid.new(size: {2, 2}, costs: :a) end) == {:costs, :a}
      assert bad.(fn -> :boids_grid.from_rows([], []) end) == {:rows, []}
      assert bad.(fn -> :boids_grid.from_rows(["..", "."], []) end) == {:rows, ~c"."}
      assert bad.(fn -> :boids_grid.from_rows([""], []) end) == {:rows, []}
      assert bad.(fn -> :boids_grid.from_rows([:a], []) end) == {:rows, :a}
      assert bad.(fn -> :boids_grid.from_rows(["x"], []) end) == {:rows, ~c"x"}
      assert bad.(fn -> :boids_grid.from_rows(["."], size: {1, 1}) end) == {:size, {1, 1}}
    end
  end

  test "a blocked cell and a place outside the grid have no cost" do
    grid = river()
    assert :boids_grid.cost(grid, {0, 0}) == 1.0
    assert :boids_grid.cost(grid, {3, 1}) == 3.0
    assert :boids_grid.cost(grid, {0, 3}) == :infinity
    assert :boids_grid.cost(grid, {8, 0}) == :infinity
    assert :boids_grid.cost(grid, {0, -1}) == :infinity
    assert :boids_grid.blocked(grid, {0, 3})
    refute :boids_grid.blocked(grid, {4, 3})
    assert :boids_grid.walkable(grid, {4.5, 3.5})
    refute :boids_grid.walkable(grid, {3.5, 3.5})
    refute :boids_grid.walkable(grid, {-0.1, 0.5})
  end

  test "set_cost/3 makes a new grid, and refuses a bad cell or cost" do
    grid = river()
    closed = :boids_grid.set_cost(grid, [{4, 3}, {4, 4}], :blocked)
    assert :boids_grid.blocked(closed, {4, 3}) and :boids_grid.blocked(closed, {4, 4})
    refute :boids_grid.blocked(grid, {4, 3})
    open = :boids_grid.set_cost(closed, [{4, 4}, {0, 0}], 2)
    assert :boids_grid.cost(open, {4, 4}) == 2.0
    assert :boids_grid.cost(open, {0, 0}) == 2.0
    assert :boids_grid.cost(open, {5, 5}) == 1.0
    assert :boids_grid.set_cost(grid, [], 2) == grid
    assert_raise ArgumentError, fn -> :boids_grid.set_cost(grid, [{8, 0}], 2) end
    assert_raise ArgumentError, fn -> :boids_grid.set_cost(grid, [{0, 0}], 0) end
    assert_raise ArgumentError, fn -> :boids_grid.set_cost(grid, {0, 0}, 1) end
    assert_raise ArgumentError, fn -> :boids_grid.set_cost(grid, [{0.5, 0}], 1) end
  end

  test "steps/2 gives the open cells around, with no cut across a corner" do
    grid = river()
    # In the middle of the bridge: up and down only.
    assert Enum.sort(:boids_grid.steps(grid, {4, 3})) == [{{4, 2}, 1.0}, {{4, 4}, 1.0}]
    # At the side of the bridge: no step across the corner of the water.
    steps = Map.new(:boids_grid.steps(grid, {4, 2}))
    assert Map.keys(steps) |> Enum.sort() == [{3, 1}, {3, 2}, {4, 1}, {4, 3}, {5, 1}, {5, 2}]
    # A step to the hill costs the mean of the two costs, and a step
    # across a corner is longer.
    assert steps[{3, 2}] == 1.0
    assert_in_delta steps[{3, 1}], :math.sqrt(2) * 2.0, 1.0e-12
    assert :boids_grid.steps(grid, {0, 3}) == []
    # At a side of the grid, fewer steps.
    assert length(:boids_grid.steps(grid, {0, 0})) == 3
  end

  describe "hit/3" do
    test "a line with no blocked cell" do
      assert :boids_grid.hit(river(), {0.5, 0.5}, {7.5, 2.5}) == :none
      assert :boids_grid.hit(river(), {4.5, 0.5}, {4.5, 5.5}) == :none
      assert :boids_grid.hit(river(), {1.5, 1.5}, {1.5, 1.5}) == :none
    end

    test "the contact with the edge of a blocked cell" do
      {at, normal} = :boids_grid.hit(river(), {1.5, 1.5}, {1.5, 3.5})
      assert normal == {0.0, 1.0}
      assert_vec(at, {1.5, 3.0}, 1.0e-5)
      assert :boids_grid.walkable(river(), at)

      {at, normal} = :boids_grid.hit(river(), {4.5, 3.5}, {3.2, 3.5})
      assert normal == {-1.0, 0.0}
      assert_vec(at, {4.0, 3.5}, 1.0e-5)
      assert :boids_grid.walkable(river(), at)

      # Upward, into the water from below.
      {at, normal} = :boids_grid.hit(river(), {0.5, 5.5}, {0.5, 4.5})
      assert normal == {0.0, -1.0}
      assert_vec(at, {0.5, 5.0}, 1.0e-5)
    end

    test "a line out of the grid touches its side" do
      {at, normal} = :boids_grid.hit(river(), {7.5, 0.5}, {9.0, 0.5})
      assert normal == {1.0, 0.0}
      assert_vec(at, {8.0, 0.5}, 1.0e-5)
    end

    test "at a corner, a line does not go between two cells that touch" do
      diagonal = {:math.sqrt(0.5), :math.sqrt(0.5)}
      # Two cells that touch at the corner: the line does not go across.
      {at, normal} = :boids_grid.hit(:boids_grid.from_rows([".#", "#."], []), {0.5, 0.5}, {1.5, 1.5})
      assert_vec(normal, diagonal)
      assert_vec(at, {1.0, 1.0}, 1.0e-5)
      # One cell beside the corner: the edge of that cell.
      {_at, normal} = :boids_grid.hit(:boids_grid.from_rows([".#", ".."], []), {0.5, 0.5}, {1.5, 1.5})
      assert normal == {1.0, 0.0}
      {_at, normal} = :boids_grid.hit(:boids_grid.from_rows(["..", "#."], []), {0.5, 0.5}, {1.5, 1.5})
      assert normal == {0.0, 1.0}
      # The cell across the corner.
      {_at, normal} = :boids_grid.hit(:boids_grid.from_rows(["..", ".#"], []), {0.5, 0.5}, {1.5, 1.5})
      assert_vec(normal, diagonal)
      # No blocked cell: the line goes across the corner.
      assert :boids_grid.hit(:boids_grid.from_rows(["..", ".."], []), {0.5, 0.5}, {1.5, 1.5}) == :none
    end

    test "a line from a blocked cell is inside" do
      assert :boids_grid.hit(river(), {0.5, 3.5}, {0.5, 5.5}) == :inside
      assert :boids_grid.hit(river(), {-0.5, 0.5}, {0.5, 0.5}) == :inside
    end

    test "with a box, a line continues at the opposite side" do
      grid = :boids_grid.from_rows(["#...", "....", "...."], [])
      box = {{0.0, 0.0}, {4.0, 3.0}}
      # From the right side to the cell (0, 0), across the side.
      {at, normal} = :boids_grid.hit(grid, {3.5, 0.5}, {4.5, 0.5}, box)
      assert normal == {1.0, 0.0}
      assert_vec(at, {4.0, 0.5}, 1.0e-5)
      assert :boids_grid.hit(grid, {3.5, 1.5}, {4.5, 1.5}, box) == :none
      assert :boids_grid.hit(grid, {3.5, 1.5}, {4.5, 1.5}) != :none
    end
  end

  describe "nearest/2" do
    test "a walkable position is the nearest place" do
      assert :boids_grid.nearest(river(), {4.5, 3.5}) == {4.5, 3.5}
    end

    test "in a blocked cell, the nearest point of the nearest open cell" do
      grid = river()
      # In the water near the bridge: the bridge is nearer than the land.
      place = :boids_grid.nearest(grid, {3.9, 3.9})
      assert_vec(place, {4.0, 3.9}, 1.0e-5)
      assert :boids_grid.walkable(grid, place)
      # Far from the bridge: the land above, across one cell of water.
      place = :boids_grid.nearest(grid, {1.2, 3.3})
      assert_vec(place, {1.2, 3.0}, 1.0e-5)
      assert :boids_grid.walkable(grid, place)
      # In the row below: the land below is nearer.
      place = :boids_grid.nearest(grid, {1.2, 4.8})
      assert_vec(place, {1.2, 5.0}, 1.0e-5)
      assert :boids_grid.walkable(grid, place)
    end

    test "the search goes on when a cell of a later ring is nearer" do
      # From the corner of a block of 3 x 3 cells, the open cell across the
      # corner is in the first ring, but the cell above is nearer.
      grid = :boids_grid.from_rows([".....", ".###.", ".###.", ".###.", "....."], [])
      place = :boids_grid.nearest(grid, {2.5, 1.8})
      assert_vec(place, {2.5, 1.0}, 1.0e-5)
      # In the middle, each side is at the same distance: one of them.
      {x, y} = :boids_grid.nearest(grid, {2.5, 2.5})
      assert :boids_grid.walkable(grid, {x, y})
      assert_in_delta :boids_vec.dist({x, y}, {2.5, 2.5}), 1.5, 1.0e-5
    end

    test "out of the grid, the nearest open cell of the grid" do
      grid = river()
      place = :boids_grid.nearest(grid, {-3.0, 1.5})
      assert_vec(place, {0.0, 1.5}, 1.0e-5)
      assert :boids_grid.walkable(grid, place)
      # Out of the grid at the level of the water: not the blocked cell
      # of the side, but the land above it.
      place = :boids_grid.nearest(grid, {-3.0, 3.2})
      assert_vec(place, {0.0, 3.0}, 1.0e-5)
      assert :boids_grid.walkable(grid, place)
    end

    test "a grid with no open cell has no walkable place" do
      grid = :boids_grid.from_rows(["##", "##"], [])
      assert :boids_grid.nearest(grid, {0.5, 0.5}) == :none
      # A cell that opens gives a place again.
      open = :boids_grid.set_cost(grid, [{1, 1}], 1)
      assert_vec(:boids_grid.nearest(open, {0.5, 0.5}), {1.0, 1.0}, 1.0e-5)
      assert :boids_grid.nearest(:boids_grid.set_cost(open, [{1, 1}], :blocked), {0.5, 0.5}) == :none
    end

    test "with a box, an open cell across a side of the box" do
      grid = :boids_grid.from_rows([".###", "####", "####"], [])
      box = {{0.0, 0.0}, {4.0, 3.0}}
      # The cell (3, 0) is beside the cell (0, 0), across the side.
      assert_vec(:boids_grid.nearest(grid, {3.5, 0.5}, box), {4.0, 0.5}, 1.0e-5)
      assert_vec(:boids_grid.nearest(grid, {3.5, 0.5}), {1.0, 0.5}, 1.0e-5)
      # A box that is much larger than the grid: no open cell near.
      far = {{0.0, 0.0}, {400.0, 300.0}}
      assert :boids_grid.nearest(grid, {300.5, 200.5}, far) == :none
    end
  end

  describe "walls/3" do
    test "gives the nearest point of each blocked cell near a position" do
      grid = river()
      walls = :boids_grid.walls(grid, {4.5, 3.5}, 0.6)
      assert Enum.sort(walls) == [{4.0, 3.5}, {5.0, 3.5}]
      assert :boids_grid.walls(grid, {1.5, 1.5}, 1.0) == []
      assert {1.5, 3.0} in :boids_grid.walls(grid, {1.5, 2.5}, 1.0)
      # Out of the grid is a wall.
      assert :boids_grid.walls(grid, {0.2, 0.5}, 0.5) == [{0.0, 0.5}]
      # With a box, the cells across a side.
      assert :boids_grid.walls(grid, {0.2, 0.5}, 0.5, {{0.0, 0.0}, {8.0, 6.0}}) == []
    end

    test "a cell behind another blocked cell is not a wall: a thick wall is as a thin wall" do
      thin = :boids_grid.from_rows(["......", "......", "######", "......", "......", "......"], [])
      thick = :boids_grid.from_rows(["......", "......", "######", "######", "######", "......"], [])

      for pos <- [{2.5, 1.5}, {2.2, 1.9}, {3.0, 0.7}], distance <- [0.8, 1.6, 2.9] do
        assert :boids_grid.walls(thick, pos, distance) == :boids_grid.walls(thin, pos, distance)
      end

      # A straight wall gives one point: its point nearest to the
      # position. The other points are the sides of the grid.
      walls = :boids_grid.walls(thick, {2.5, 1.5}, 2.9)
      assert Enum.sort(walls) == [{0.0, 1.5}, {2.5, 0.0}, {2.5, 2.0}]
      # At the same distance from two cells of the wall: their common
      # corner, one time.
      assert :boids_grid.walls(thick, {3.0, 1.5}, 0.6) == [{3.0, 2.0}]
    end

    test "in a corner, the cell behind the two walls is not a wall" do
      grid = :boids_grid.from_rows(["..#", "..#", "###"], [])
      assert Enum.sort(:boids_grid.walls(grid, {1.5, 1.5}, 1.0)) == [{1.5, 2.0}, {2.0, 1.5}]
      # A block at an outer corner is a wall for a position across the corner.
      block = :boids_grid.from_rows(["...", "...", "..#"], [])
      assert :boids_grid.walls(block, {1.5, 1.5}, 1.0) == [{2.0, 2.0}]
    end

    test "a position in a blocked cell gets no wall" do
      assert :boids_grid.walls(river(), {2.5, 3.5}, 5.0) == []
      assert :boids_grid.walls(river(), {-0.5, 0.5}, 5.0) == []
    end
  end
end
