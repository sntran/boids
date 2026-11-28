defmodule BoidsWalkTest do
  # The places where a boid can walk: the option walkable, the grids of a
  # world, and the slide along an edge.
  use ExUnit.Case, async: true
  use ExUnitProperties
  import Boids.Helpers

  @diagonal 1 / :math.sqrt(2)

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

  # A wall: the column 10 of a grid of 20 x 20 cells.
  defp wall, do: :boids_grid.new(size: {20, 20}, blocked: for(j <- 0..19, do: {10, j}))

  defp boid(opts),
    do: :boids_boid.new(Map.merge(%{pos: {0, 0}, rules: [], walkable: {:named, :land}}, Map.new(opts)))

  defp step(boid, grid, dt \\ 1.0, more \\ %{}) do
    :boids_boid.step(boid, [], Map.merge(%{grids: %{land: grid}}, more), dt)
  end

  defp world(opts) do
    {:ok, world} = :boids.start_world(opts)
    on_exit(fn -> :boids.stop_world(world) end)
    world
  end

  defp walkable?(world, grid) do
    Enum.all?(:boids.snapshot(world), fn %{pos: pos} -> :boids_grid.walkable(grid, pos) end)
  end

  describe "the option walkable" do
    test "is all the places by default, or the name of a grid of the world" do
      assert :boids_boid.new(pos: {0, 0}).walkable == :all
      assert boid(%{}).walkable == {:named, :land}
      assert :boids_boid.named(:boids_boid.new(pos: {0, 0})) == []
      assert :boids_boid.named(boid(walkable: {:named, {:floor, 2}})) == [grid: {:floor, 2}]
      changed = :boids_boid.update(boid(%{}), walkable: :all)
      assert :boids_boid.named(changed) == []
    end

    test "a value that is not a name is a bad option: a grid and a function too" do
      for bad <- [:none, {:named}, :land, wall(), fn _ -> true end] do
        assert catch_error(boid(walkable: bad)) == {:bad_option, {:walkable, bad}}
      end

      assert {:error, {:bad_option, {:walkable, :no}}} = :boids.start_world(defaults: %{walkable: :no})
    end

    test "a boid with three dimensions cannot have a grid" do
      named = {:named, :land}
      assert catch_error(boid(pos: {0, 0, 0})) == {:bad_option, {:walkable, named}}
      free = :boids_boid.new(pos: {0, 0, 0})
      assert free.walkable == :all
      assert catch_error(:boids_boid.update(free, walkable: named)) == {:bad_option, {:walkable, named}}
      world = world(defaults: %{walkable: named})
      assert :boids.add(world, pos: {0, 0, 0}) == {:error, {:bad_option, {:walkable, named}}}
      assert {:ok, _} = :boids.add(world, pos: {0, 0, 0}, walkable: :all)
    end
  end

  describe "the movement of a step" do
    test "a boid that goes into a wall at 45 degrees slides along it at 0.71 of its speed" do
      moved = step(boid(pos: {9.5, 5.0}, vel: {@diagonal, @diagonal}), wall())
      assert_vec(moved.vel, {0.0, @diagonal})
      assert_in_delta :boids_vec.norm(moved.vel), 0.71, 0.005
      assert_vec(moved.pos, {10.0, 5.0 + @diagonal}, 1.0e-5)
      assert :boids_grid.walkable(wall(), moved.pos)
      # It continues along the wall.
      again = step(moved, wall())
      assert_vec(again.pos, {10.0, 5.0 + 2 * @diagonal}, 1.0e-5)
      assert_vec(again.vel, {0.0, @diagonal})
    end

    test "the slide is exact at each angle and each length of step" do
      for degrees <- [10, 30, 60, 80], speed <- [0.2, 3.0, 12.0], dt <- [0.01, 0.1, 1.0] do
        angle = degrees * :math.pi() / 180
        vel = {speed * :math.cos(angle), speed * :math.sin(angle)}
        moved = step(boid(pos: {9.9999, 5.0}, vel: vel, max_speed: 100.0), wall(), dt)
        # The part of the velocity along the wall stays, and the other goes.
        assert_vec(moved.vel, {0.0, speed * :math.sin(angle)}, 1.0e-9)
        {x, y} = moved.pos
        assert_in_delta x, 10.0, 1.0e-5
        # The movement before the contact, and along the wall after it.
        assert_in_delta y, 5.0 + speed * :math.sin(angle) * dt, 1.0e-9
      end
    end

    test "a boid that moves along a wall, or away from it, does not slow down" do
      along = step(boid(pos: {9.5, 5.0}, vel: {0.0, 1.0}), wall())
      assert_vec(along.vel, {0.0, 1.0})
      assert_vec(along.pos, {9.5, 6.0})
      away = step(boid(pos: {9.99, 5.0}, vel: {-1.0, 1.0}, max_speed: 2.0), wall())
      assert_vec(away.vel, {-1.0, 1.0})
    end

    test "a boid stops in a corner" do
      grid =
        :boids_grid.new(size: {20, 20}, blocked: for(k <- 0..19, do: {10, k}) ++ for(k <- 0..19, do: {k, 10}))

      moved = step(boid(pos: {9.5, 9.2}, vel: {1.0, 1.0}, max_speed: 2.0), grid)
      assert_vec(moved.vel, {0.0, 0.0})
      assert_vec(moved.pos, {10.0, 10.0}, 1.0e-5)
      assert :boids_grid.walkable(grid, moved.pos)
    end

    test "a boid in a way with no exit stops after three contacts" do
      # The cell (1, 1) is open, with blocked cells to its right, above
      # and below. The line goes exactly through the corner of two of them.
      grid = :boids_grid.from_rows(["####", "#.##", "####"], [])
      moved = step(boid(pos: {1.5, 1.75}, vel: {8.0, 4.0}, max_speed: 10.0), grid)
      assert_vec(moved.vel, {0.0, 0.0}, 1.0e-9)
      assert_vec(moved.pos, {2.0, 1.0}, 1.0e-5)
      assert :boids_grid.walkable(grid, moved.pos)
    end

    test "a name with no grid, and a step with no grids, is no limit" do
      boid = boid(pos: {9.5, 5.0}, vel: {1.0, 0.0})
      assert_vec(:boids_boid.step(boid, [], %{grids: %{sea: wall()}}, 1.0).pos, {10.5, 5.0})
      assert_vec(:boids_boid.step(boid, [], %{grids: %{}}, 1.0).pos, {10.5, 5.0})
      assert_vec(:boids_boid.step(boid, [], %{}, 1.0).pos, {10.5, 5.0})
      # A boid with no option walkable does not see the grid.
      bird = :boids_boid.update(boid, walkable: :all)
      assert_vec(step(bird, wall()).pos, {10.5, 5.0})
    end

    test "with wrap, a boid meets the walls across a side of the box" do
      # The column 0 is the wall, and the boid goes to it across the side.
      grid = :boids_grid.new(size: {10, 10}, blocked: for(j <- 0..9, do: {0, j}))
      wrap = %{wrap: true, bounds: {{0.0, 0.0}, {10.0, 10.0}}}
      moved = step(boid(pos: {9.5, 5.0}, vel: {1.0, 0.0}), grid, 1.0, wrap)
      assert_vec(moved.pos, {10.0, 5.0}, 1.0e-5)
      assert_vec(moved.vel, {0.0, 0.0})
      # With no wall there, the boid comes in at the opposite side.
      free = step(boid(pos: {9.5, 5.0}, vel: {3.0, 0.0}), :boids_grid.new(size: {10, 10}), 1.0, wrap)
      assert_vec(free.pos, {2.5, 5.0})
    end
  end

  describe "a boid in a blocked cell" do
    test "goes to the nearest walkable place, and makes its step from there" do
      # In the wall, nearer to its left side.
      moved = step(boid(pos: {10.2, 5.0}, vel: {0.0, 1.0}), wall())
      assert_vec(moved.pos, {10.0, 6.0}, 1.0e-5)
      assert_vec(moved.vel, {0.0, 1.0})
      assert :boids_grid.walkable(wall(), moved.pos)
      # A velocity into the wall: it slides from the walkable place.
      moved = step(boid(pos: {10.2, 5.0}, vel: {1.0, 1.0}, max_speed: 2.0), wall())
      assert_vec(moved.pos, {10.0, 6.0}, 1.0e-5)
      assert_vec(moved.vel, {0.0, 1.0})
      # Nearer to the right side.
      moved = step(boid(pos: {10.8, 5.0}, vel: {0.0, 1.0}), wall())
      assert_vec(moved.pos, {11.0, 6.0}, 1.0e-5)
    end

    test "with no time, it stays: a step of no time changes nothing" do
      boid = boid(pos: {10.2, 5.0}, vel: {0.0, 1.0})
      assert step(boid, wall(), 0) == boid
    end

    test "in a grid with no open cell, it has no limit" do
      closed = :boids_grid.from_rows(["##", "##"], [])
      moved = step(boid(pos: {0.5, 0.5}, vel: {1.0, 0.0}), closed)
      assert_vec(moved.pos, {1.5, 0.5})
      assert_vec(moved.vel, {1.0, 0.0})
    end

    test "with wrap, it goes to a walkable place across a side of the box" do
      grid = :boids_grid.from_rows([".###", "####", "####"], [])
      wrap = %{wrap: true, bounds: {{0.0, 0.0}, {4.0, 3.0}}}
      moved = step(boid(pos: {3.6, 0.5}, vel: {0.0, 0.0}), grid, 1.0, wrap)
      # The cell (0, 0), across the right side.
      assert_vec(moved.pos, {0.0, 0.5}, 1.0e-5)
      assert :boids_grid.walkable(grid, moved.pos)
    end
  end

  describe "a world with a grid" do
    test "its boids do not go into a wall, and slide along it" do
      grid = :boids_grid.new(size: {20, 10}, blocked: for(j <- 0..9, do: {10, j}))
      world = world(bounds: {{0, 0}, {20, 10}}, defaults: %{walkable: {:named, :land}, tick: :manual})
      :ok = :boids.set_grid(world, :land, grid)
      seek = [{:seek, 1.0, target: {19.0, 9.0}}]

      for k <- 0..9 do
        {:ok, _} = :boids.add(world, pos: {2.0 + k * 0.5, 0.5 + k * 0.8}, rules: seek, max_speed: 4.0)
      end

      for _ <- 1..60 do
        :ok = :boids.step(world, 0.1)
        assert walkable?(world, grid)
      end

      # They are at the wall, and they moved along it.
      assert Enum.all?(:boids.snapshot(world), fn %{pos: {x, _}} -> x > 9.0 end)
      assert Enum.any?(:boids.snapshot(world), fn %{pos: {_, y}} -> y > 8.0 end)
    end

    test "a boid gets its grid in what it perceives, and a boid with no name gets none" do
      world = world(bounds: {{0, 0}, {20, 20}})
      :ok = :boids.set_grid(world, :land, wall())
      :ok = :boids.set_grid(world, :sea, :boids_grid.new(size: {2, 2}))
      {:ok, _} = :gen_boid.start(world, Walker, {self(), %{pos: {1, 1}, walkable: {:named, :land}}})
      :ok = :boids.step(world, 0.1)
      assert_receive {:seen, %{grids: grids}}
      assert grids == %{land: wall()}

      {:ok, world2} = :boids.start_world(%{})
      on_exit(fn -> :boids.stop_world(world2) end)
      {:ok, _} = :gen_boid.start(world2, Walker, {self(), %{pos: {1, 1}}})
      :ok = :boids.step(world2, 0.1)
      assert_receive {:seen, %{grids: grids}}
      assert grids == %{}
    end

    test "a door that opens lets the boids through, from their next step" do
      world = world(bounds: {{0, 0}, {20, 20}}, defaults: %{walkable: {:named, :land}, tick: :manual})
      :ok = :boids.set_grid(world, :land, wall())
      {:ok, id} = :boids.add(world, pos: {9.5, 5.5}, vel: {2.0, 0.0}, rules: [{:cruise, 1.0}], max_speed: 2.0)
      x = fn -> elem(elem(:boids.lookup(world, id), 1).pos, 0) end

      for _ <- 1..5, do: :ok = :boids.step(world, 0.1)
      assert_in_delta x.(), 10.0, 1.0e-5
      # The door: the cell of the wall in front of the boid.
      :ok = :boids.set_grid(world, :land, :boids_grid.set_cost(wall(), [{10, 5}], 1))
      :ok = :boids.update(world, id, vel: {2.0, 0.0})
      for _ <- 1..10, do: :ok = :boids.step(world, 0.1)
      assert x.() > 11.0
    end

    test "a door that closes puts a boid in it at the nearest walkable place, at its next step" do
      open = :boids_grid.set_cost(wall(), [{10, 5}], 1)
      world = world(bounds: {{0, 0}, {20, 20}}, defaults: %{walkable: {:named, :land}, tick: :manual})
      :ok = :boids.set_grid(world, :land, open)
      {:ok, id} = :boids.add(world, pos: {10.3, 5.5}, rules: [])
      {:ok, far} = :boids.add(world, pos: {3.0, 3.0}, rules: [])
      :ok = :boids.step(world, 0.1)
      assert {:ok, %{pos: {10.3, 5.5}}} = :boids.lookup(world, id)

      :ok = :boids.set_grid(world, :land, wall())
      # The world does not move a boid: the boid moves at its next step.
      assert {:ok, %{pos: {10.3, 5.5}}} = :boids.lookup(world, id)
      :ok = :boids.step(world, 0.1)
      {:ok, %{pos: pos}} = :boids.lookup(world, id)
      assert_vec(pos, {10.0, 5.5}, 1.0e-5)
      assert :boids_grid.walkable(wall(), pos)
      assert {:ok, %{pos: {3.0, 3.0}}} = :boids.lookup(world, far)
    end

    test "with no grid for its name, a boid has no limit" do
      world = world(bounds: {{0, 0}, {20, 20}}, defaults: %{walkable: {:named, :land}, tick: :manual})
      {:ok, id} = :boids.add(world, pos: {9.5, 5.5}, vel: {2.0, 0.0}, rules: [{:cruise, 1.0}], max_speed: 2.0)
      for _ <- 1..5, do: :ok = :boids.step(world, 0.1)
      assert {:ok, %{pos: {x, _}}} = :boids.lookup(world, id)
      assert_in_delta x, 10.5, 1.0e-9
      # The grid comes, and then goes.
      :ok =
        :boids.set_grid(world, :land, :boids_grid.new(size: {20, 20}, blocked: for(j <- 0..19, do: {12, j})))

      for _ <- 1..15, do: :ok = :boids.step(world, 0.1)
      assert {:ok, %{pos: {x, _}}} = :boids.lookup(world, id)
      assert_in_delta x, 12.0, 1.0e-5
      :ok = :boids.remove_grid(world, :land)
      :ok = :boids.update(world, id, vel: {2.0, 0.0})
      for _ <- 1..5, do: :ok = :boids.step(world, 0.1)
      assert {:ok, %{pos: {x, _}}} = :boids.lookup(world, id)
      assert x > 12.5
    end

    test "walls can be for one kind of boid and not for another" do
      world =
        world(bounds: {{0, 0}, {20, 20}}, defaults: %{tick: :manual, rules: [{:cruise, 1.0}], max_speed: 2.0})

      :ok = :boids.set_grid(world, :land, wall())
      {:ok, person} = :boids.add(world, pos: {9.5, 5.5}, vel: {2.0, 0.0}, walkable: {:named, :land})
      {:ok, bird} = :boids.add(world, pos: {9.5, 6.5}, vel: {2.0, 0.0})
      for _ <- 1..10, do: :ok = :boids.step(world, 0.1)
      assert {:ok, %{pos: {x, _}}} = :boids.lookup(world, person)
      assert_in_delta x, 10.0, 1.0e-5
      assert {:ok, %{pos: {x, _}}} = :boids.lookup(world, bird)
      assert_in_delta x, 11.5, 1.0e-9
    end

    test "the grid that a boid keeps is not in the boid, and not in its row" do
      world = world(bounds: {{0, 0}, {20, 20}})
      :ok = :boids.set_grid(world, :land, wall())
      {:ok, id} = :boids.add(world, pos: {1, 1}, walkable: {:named, :land}, tick: :manual, rules: [])
      :ok = :boids.step(world, 0.1)
      {:ok, boid} = :boids.boid(world, id)
      assert boid.walkable == {:named, :land}
      {:ok, row} = :boids.lookup(world, id)
      refute :erlang.term_to_binary({boid, row}) =~ "boids_grid"
      # The process of the boid keeps it, in its state.
      assert %{kept: {1, [grid: :land], %{grids: %{land: _}}}} = :sys.get_state(:boids.whereis(world, id))
    end

    test "a boid with its own clock obeys the limit too" do
      grid = :boids_grid.new(size: {20, 20}, blocked: for(j <- 0..19, do: {10, j}))
      world = world(bounds: {{0, 0}, {20, 20}}, defaults: %{walkable: {:named, :land}, tick: 5})
      :ok = :boids.set_grid(world, :land, grid)

      {:ok, ids} =
        :boids.populate(world, 20, area: {{5, 0}, {10, 20}}, rules: [{:seek, 1.0, target: {19, 10}}])

      for _ <- 1..20 do
        Process.sleep(10)
        assert walkable?(world, grid)
      end

      assert eventually(fn ->
               Enum.all?(ids, fn id -> elem(elem(:boids.lookup(world, id), 1).pos, 0) > 9.9 end)
             end)
    end
  end

  describe "the rule walls" do
    defp walls_force(grid, opts, rule \\ {:walls, 1.0}, more \\ %{}) do
      boid =
        boid(Map.merge(%{rules: [rule], max_speed: 4.0, perception: 2.0, max_force: 1.0e9}, Map.new(opts)))

      {[{_, force}], _} = :boids_boid.forces(boid, [], Map.merge(%{grids: %{land: grid}}, more))
      force
    end

    test "pushes a boid away from a wall near it, more when the wall is nearer" do
      # The margin is half of the perception: 1.0.
      assert_vec(walls_force(wall(), pos: {9.5, 5.0}), {-2.0, 0.0})
      assert_vec(walls_force(wall(), pos: {9.9, 5.0}), {-3.6, 0.0})
      assert_vec(walls_force(wall(), pos: {11.25, 5.0}), {3.0, 0.0})
      # Far from the wall: no force.
      assert walls_force(wall(), pos: {7.0, 10.0}) == {0.0, 0.0}
      # A larger margin: the boid feels the wall from farther.
      assert_vec(walls_force(wall(), [pos: {7.0, 10.0}], {:walls, 1.0, margin: 6.0}), {-2.0, 0.0})
      # The weight of the rule multiplies the force.
      assert_vec(walls_force(wall(), [pos: {9.5, 5.0}], {:walls, 2.5}), {-5.0, 0.0})
    end

    test "along a straight wall, the force is the same at each place, and at a right angle to the wall" do
      for y <- [5.0, 5.3, 5.5, 5.99, 6.0, 6.01, 11.7] do
        assert_vec(walls_force(wall(), pos: {9.5, y}), {-2.0, 0.0})
      end
    end

    test "a thin wall and a thick wall at the same distance give the same force" do
      thin =
        :boids_grid.from_rows(["........", "........", "########", "........", "........", "........"], [])

      thick =
        :boids_grid.from_rows(["........", "........", "########", "########", "########", "########"], [])

      long =
        :boids_grid.from_rows(["........", "........", "..####..", "........", "........", "........"], [])

      for pos <- [{3.5, 1.5}, {3.1, 1.9}, {4.0, 1.2}, {2.7, 1.05}], margin <- [0.5, 1.0, 2.5] do
        rule = {:walls, 1.0, margin: margin}
        force = walls_force(thin, [pos: pos], rule)
        assert walls_force(thick, [pos: pos], rule) == force
        # A short wall too, when the boid is in front of it.
        if margin <= 1.0, do: assert(walls_force(long, [pos: pos], rule) == force)
      end

      # The force is not zero in these places.
      assert_vec(walls_force(thick, [pos: {3.5, 1.5}], {:walls, 1.0, margin: 1.0}), {0.0, -2.0})
    end

    test "between two walls, the force is to the middle, and no force at the middle" do
      bridge = :boids_grid.from_rows(["#.#", "#.#", "#.#"], [])
      assert_vec(walls_force(bridge, pos: {1.5, 1.5}), {0.0, 0.0})
      {x, y} = walls_force(bridge, pos: {1.4, 1.5})
      assert x > 0 and x < 0.5
      assert_in_delta y, 0.0, 1.0e-12
      {x, _} = walls_force(bridge, pos: {1.9, 1.5})
      assert x < -2.0
    end

    test "in a corner, the force is away from the two walls" do
      corner = :boids_grid.from_rows(["..#", "..#", "###"], [])
      assert_vec(walls_force(corner, pos: {1.5, 1.5}), {-1.0, -1.0})
    end

    test "with no grid, in a blocked cell, and in three dimensions, the rule gives no force" do
      boid = boid(pos: {9.5, 5.0}, rules: [{:walls, 1.0}], perception: 2.0)
      assert {[walls: {+0.0, +0.0}], _} = :boids_boid.forces(boid, [], %{grids: %{}})
      assert {[walls: {+0.0, +0.0}], _} = :boids_boid.forces(boid, [], %{})
      free = :boids_boid.update(boid, walkable: :all)
      assert {[walls: {+0.0, +0.0}], _} = :boids_boid.forces(free, [], %{grids: %{land: wall()}})
      assert walls_force(wall(), pos: {10.5, 5.0}) == {0.0, 0.0}
      bird = :boids_boid.new(pos: {9.5, 5.0, 1.0}, rules: [{:walls, 1.0}])
      assert {[walls: {+0.0, +0.0, +0.0}], _} = :boids_boid.forces(bird, [], %{grids: %{land: wall()}})
    end

    test "with wrap, a wall across a side of the box pushes too" do
      grid = :boids_grid.new(size: {10, 10}, blocked: for(j <- 0..9, do: {0, j}))
      wrap = %{wrap: true, bounds: {{0.0, 0.0}, {10.0, 10.0}}}
      assert_vec(walls_force(grid, [pos: {9.5, 5.0}], {:walls, 1.0}, wrap), {-2.0, 0.0})
      # With no wrap, the side of the grid is a wall at the same place.
      assert_vec(walls_force(:boids_grid.new(size: {10, 10}), pos: {9.5, 5.0}), {-2.0, 0.0})
    end

    test "boids with the rule come near a wall more slowly, and do not stay in contact with it" do
      grid = :boids_grid.new(size: {20, 10}, blocked: for(j <- 0..9, do: {10, j}))

      nearest = fn rules ->
        world = world(bounds: {{0, 0}, {20, 10}}, defaults: %{walkable: {:named, :land}, tick: :manual})
        :ok = :boids.set_grid(world, :land, grid)
        {:ok, id} = :boids.add(world, pos: {5.0, 5.0}, rules: rules, max_speed: 2.0, perception: 4.0)
        for _ <- 1..80, do: :ok = :boids.step(world, 0.1)
        {:ok, %{pos: {x, _}}} = :boids.lookup(world, id)
        10.0 - x
      end

      seek = {:seek, 1.0, target: {15.0, 5.0}}
      # With the limit only, the boid is at the wall.
      assert nearest.([seek]) < 1.0e-5
      # With the rule, it stops where the two forces are equal.
      gap = nearest.([seek, {:walls, 2.0}])
      assert gap > 0.5 and gap < 2.0
    end
  end

  describe "populate/3" do
    test "puts boids only in walkable places, and refuses an area with none" do
      grid = :boids_grid.from_rows(["#####", "#...#", "#####"], cell_size: 2.0)
      world = world(bounds: {{0, 0}, {10, 6}}, defaults: %{walkable: {:named, :land}})
      :ok = :boids.set_grid(world, :land, grid)
      {:ok, ids} = :boids.populate(world, 30, tick: :manual, rules: [])
      assert length(:boids.snapshot(world)) == length(ids)
      assert walkable?(world, grid)
      # With a velocity for all of them too.
      {:ok, _} = :boids.populate(world, 5, tick: :manual, rules: [], vel: {1, 0})
      assert walkable?(world, grid)

      area = {{0, 0}, {2, 2}}
      assert :boids.populate(world, 1, area: area, tick: :manual) == {:error, {:not_walkable, area}}
      assert :boids.count(world) == 35
      # A boid of another kind, and a name with no grid: each place.
      assert {:ok, [_]} = :boids.populate(world, 1, area: area, tick: :manual, walkable: :all)
      assert {:ok, [_]} = :boids.populate(world, 1, area: area, tick: :manual, walkable: {:named, :sea})
    end
  end

  describe "a process with another behavior" do
    test "join/2 and advance/3 obey the same limit" do
      world = world(bounds: {{0, 0}, {20, 20}})
      :ok = :boids.set_grid(world, :land, wall())
      options = [pos: {9.5, 5.0}, vel: {1.0, 0.0}, rules: [], walkable: {:named, :land}]
      {:ok, space, boid} = :boids.join(world, options)
      moved = :boids.advance(space, boid, 1.0)
      assert_vec(moved.pos, {10.0, 5.0}, 1.0e-5)
      assert_vec(moved.vel, {0.0, 0.0})
      assert {:ok, %{pos: {x, _}}} = :boids.lookup(world, moved.id)
      assert x < 10

      # The process keeps the grid, and reads it again after a change.
      key = {:boids_space, :kept, space.facts}
      assert {1, [grid: :land], _} = Process.get(key)
      :ok = :boids.set_grid(world, :land, :boids_grid.set_cost(wall(), [{10, 5}], 1))
      through = :boids.advance(space, %{moved | vel: {1.0, 0.0}}, 1.0)
      assert_vec(through.pos, {11.0, 5.0}, 1.0e-5)
      assert {2, [grid: :land], _} = Process.get(key)

      # A plan with the neighbors of the caller obeys it too.
      :ok = :boids.set_grid(world, :land, wall())
      back = :boids.plan(space, %{through | vel: {-2.0, 0.0}}, [], 1.0)
      assert_vec(back.pos, {11.0, 5.0}, 1.0e-5)

      assert :boids.leave(space, back) == :ok
      assert Process.get(key) == nil
    end
  end

  # --- The properties: no boid in a place that is not walkable ----------

  defp weight, do: float(min: 0.0, max: 5.0)

  # Rules of the library with random weights and targets.
  defp rules do
    list_of(
      one_of([
        tuple({member_of([:separation, :alignment, :cohesion, :wander, :contain, :walls]), weight()}),
        map(tuple({weight(), vec(2, 30.0)}), fn {w, t} -> {:seek, w, %{target: t}} end),
        map(tuple({weight(), vec(2, 30.0)}), fn {w, t} -> {:flee, w, %{target: t}} end),
        map(tuple({weight(), vec(2, 1.0)}), fn {w, f} -> {:flow, w, %{field: f}} end)
      ]),
      max_length: 6
    )
  end

  # A grid with random blocked cells, an open cell, and a position in it.
  defp grid_and_place do
    gen all(
          cols <- integer(3..12),
          rows <- integer(3..12),
          side <- float(min: 0.3, max: 2.0),
          blocked <-
            list_of(tuple({integer(0..(cols - 1)), integer(0..(rows - 1))}), max_length: div(cols * rows, 2)),
          start <- tuple({integer(0..(cols - 1)), integer(0..(rows - 1))}),
          offset <- vec(2, 0.49)
        ) do
      grid =
        :boids_grid.new(size: {cols, rows}, cell_size: side, blocked: Enum.reject(blocked, &(&1 == start)))

      {grid, start, :boids_vec.add(:boids_grid.center(grid, start), :boids_vec.scale(offset, side))}
    end
  end

  # Steps of a boid with random neighbors. After each step, the boid is in
  # a walkable place.
  defp walks?(grid, pos, vel, max_speed, rules, others, dt, more) do
    boid =
      boid(
        pos: pos,
        vel: :boids_vec.limit(vel, max_speed),
        max_speed: max_speed,
        max_force: 50.0,
        rules: rules
      )

    Enum.reduce_while(1..12, boid, fn _, boid ->
      neighbors = for {other, velocity} <- others, do: neighbor(boid.pos, other, velocity)
      moved = step(boid, grid, dt, more)

      if :boids_grid.walkable(grid, moved.pos),
        do: {:cont, moved},
        else: {:halt, {:in_wall, boid, moved, neighbors}}
    end)
    |> is_map()
  end

  property "after each step, a boid with a grid is in an open cell" do
    check all(
            {grid, _start, pos} <- grid_and_place(),
            vel <- vec(2, 30.0),
            max_speed <- float(min: 0.1, max: 30.0),
            rules <- rules(),
            others <- list_of(tuple({vec(2, 12.0), vec(2, 5.0)}), max_length: 6),
            dt <- float(min: 0.01, max: 0.5)
          ) do
      assert walks?(grid, pos, vel, max_speed, rules, others, dt, %{bounds: :boids_grid.bounds(grid)})
    end
  end

  property "the same with wrap" do
    check all(
            {grid, _start, pos} <- grid_and_place(),
            vel <- vec(2, 30.0),
            max_speed <- float(min: 0.1, max: 30.0),
            rules <- rules(),
            dt <- float(min: 0.01, max: 0.5)
          ) do
      assert walks?(grid, pos, vel, max_speed, rules, [], dt, %{wrap: true, bounds: :boids_grid.bounds(grid)})
    end
  end

  property "a boid that starts at each place of the world is in an open cell after one step" do
    check all(
            {grid, _start, _pos} <- grid_and_place(),
            pos <- vec(2, 30.0),
            vel <- vec(2, 30.0),
            dt <- float(min: 0.01, max: 0.5)
          ) do
      moved = step(boid(pos: pos, vel: vel, max_speed: 50.0), grid, dt)
      assert :boids_grid.walkable(grid, moved.pos)
    end
  end

  property "the boids of a world stay in open cells, also when doors close during the run" do
    check all(
            {grid, start, _pos} <- grid_and_place(),
            rules <- rules(),
            max_speed <- float(min: 0.5, max: 20.0),
            seed <- integer(1..1_000_000),
            {cols, rows} = :boids_grid.size(grid),
            doors <-
              list_of(tuple({integer(0..(cols - 1)), integer(0..(rows - 1))}), min_length: 1, max_length: 12),
            close_at <- integer(1..8),
            max_runs: 20
          ) do
      {:ok, world} = :boids.start_world(bounds: :boids_grid.bounds(grid), cell_size: 2.0)
      :ok = :boids.set_grid(world, :land, grid)
      options = [tick: :manual, seed: seed, rules: rules, max_speed: max_speed, walkable: {:named, :land}]

      try do
        {:ok, _} = :boids.populate(world, 12, options)
        assert walkable?(world, grid)
        # The doors: cells that become blocked. One cell stays open.
        closed = :boids_grid.set_cost(grid, Enum.reject(doors, &(&1 == start)), :blocked)

        for step <- 1..12 do
          if step == close_at, do: :ok = :boids.set_grid(world, :land, closed)
          :ok = :boids.step(world, 0.1)
          assert walkable?(world, if(step >= close_at, do: closed, else: grid))
        end
      after
        :boids.stop_world(world)
      end
    end
  end
end
