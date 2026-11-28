defmodule BoidsSpaceTest do
  use ExUnit.Case, async: true
  use ExUnitProperties
  import Boids.Helpers

  defp entry(id, pos, more \\ %{}) do
    Map.merge(%{id: id, pos: pos, vel: :boids_vec.zero(tuple_size(pos))}, more)
  end

  # The boids in the radius, with a read of each row.
  defp brute(space, entries, pos, radius) do
    for %{id: id, pos: other} <- entries,
        :boids_vec.norm(:boids_space.offset(space, pos, other)) <= radius,
        do: id
  end

  describe "new/1" do
    test "gives the defaults" do
      assert %{bounds: :undefined, wrap: false} = :boids_space.new(%{bounds: :undefined, wrap: false})
      space = :boids_space.new(%{})
      assert %{cell_size: 10.0, bounds: :undefined, wrap: false, defaults: %{}} = space
      assert space.owner == self()

      for table <- [space.rows, space.grid, space.meta, space.links, space.facts, space.obstacle_cells],
          do: assert(:ets.info(table, :owner) == self())

      assert :boids_space.count(space) == 0
      assert :boids_space.all(space) == []
    end

    test "keeps the options" do
      space = :boids_space.new(%{cell_size: 5, bounds: {{0, 0}, {10, 20}}, wrap: true, defaults: %{mass: 2}})
      assert %{cell_size: 5, bounds: {{0, 0}, {10, 20}}, wrap: true, defaults: %{mass: 2}} = space
    end

    test "refuses a bad option" do
      for {key, value} <- [
            cell_size: 0,
            cell_size: :big,
            bounds: {{0, 0}, {0, 10}},
            bounds: {{0, 0}, {10, 1.0e200}},
            bounds: :box,
            cell_size: 1.0e200,
            bounds: {{0, 0}, {10, 10, 10}},
            bounds: {{:a, :b}, {:c, :d}},
            bounds: {{0, 0, 0}, {10, 10, 0}},
            wrap: :yes,
            defaults: [],
            color: :red
          ] do
        assert_raise ErlangError, ~r/bad_option/, fn -> :boids_space.new(%{key => value}) end
      end

      assert catch_error(:boids_space.new(%{wrap: true})) == {:bad_option, {:wrap, true}}
      assert catch_error(:boids_space.new(wrap: false)) == {:bad_option, [wrap: false]}
    end

    test "delete/1 removes the tables" do
      space = :boids_space.new(%{})
      assert :boids_space.delete(space) == :ok
      assert :ets.info(space.rows) == :undefined
      assert :ets.info(space.grid) == :undefined
      assert :ets.info(space.meta) == :undefined
    end
  end

  describe "the rows" do
    setup do
      %{space: :boids_space.new(%{})}
    end

    test "insert_new/2 adds a row one time", %{space: space} do
      assert :boids_space.insert_new(space, entry(:a, {1, 2}))
      refute :boids_space.insert_new(space, entry(:a, {50, 50}))
      assert :boids_space.count(space) == 1

      assert :boids_space.lookup(space, :a) ==
               {:ok,
                %{id: :a, pos: {1, 2}, vel: {0.0, 0.0}, group: :default, data: :undefined, pid: :undefined}}

      assert [%{id: :a, pos: {1, 2}}] = :boids_space.near(space, {50, 50}, 100)
    end

    test "a row keeps its group, its data and its process", %{space: space} do
      :boids_space.insert_new(space, entry(:a, {1, 2}, %{group: :fish, data: %{size: 3}, pid: self()}))
      assert {:ok, %{group: :fish, data: %{size: 3}, pid: pid}} = :boids_space.lookup(space, :a)
      assert pid == self()
      assert [%{id: :a, group: :fish, data: %{size: 3}}] = :boids_space.all(space)
    end

    test "lookup/2 of an id that is not in the space", %{space: space} do
      assert :boids_space.lookup(space, :nobody) == :error
    end

    test "owner/2 tells which process has a boid", %{space: space} do
      :boids_space.insert_new(space, entry(:a, {1, 2}, %{pid: self(), kind: :server}))
      :boids_space.insert_new(space, entry(:b, {1, 2}, %{pid: self()}))
      assert :boids_space.owner(space, :a) == {:server, self()}
      assert :boids_space.owner(space, :b) == {:process, self()}
      assert :boids_space.owner(space, :nobody) == :error
      # A write keeps the owner.
      assert :boids_space.put(space, %{id: :a, pos: {5, 5}, vel: {0, 0}, group: :g, data: nil})
      assert :boids_space.owner(space, :a) == {:server, self()}
    end

    test "servers/1 gives the processes of the boids that are a gen_boid", %{space: space} do
      assert :boids_space.servers(space) == []
      other = spawn(fn -> :ok end)
      :boids_space.insert_new(space, entry(:a, {1, 2}, %{pid: self(), kind: :server}))
      :boids_space.insert_new(space, entry(:b, {1, 2}, %{pid: other, kind: :process}))
      :boids_space.insert_new(space, entry(:c, {1, 2}, %{pid: other, kind: :server}))
      assert Enum.sort(:boids_space.servers(space)) == Enum.sort([self(), other])
      :boids_space.remove(space, :c)
      assert :boids_space.servers(space) == [self()]
    end

    test "the first boid gives the size of the vectors of the space", %{space: space} do
      assert :boids_space.dim(space) == :undefined
      assert :boids_space.insert_new(space, entry(:a, {1, 2}))
      assert :boids_space.dim(space) == 2
      assert :boids_space.fit(space, {5, 5})
      refute :boids_space.fit(space, {5, 5, 5})
      refute :boids_space.insert_new(space, entry(:b, {1, 2, 3}))
      assert :boids_space.count(space) == 1
      # The size stays when the space has no boid.
      :boids_space.remove(space, :a)
      assert :boids_space.dim(space) == 2
      refute :boids_space.fit(space, {5, 5, 5})
    end

    test "fit/2 gives the size of a position to a space with no size", %{space: space} do
      assert :boids_space.fit(space, {1, 2, 3})
      assert :boids_space.dim(space) == 3
      assert :boids_space.fit(space, {4, 5, 6})
      refute :boids_space.fit(space, {4, 5})
    end

    test "a space with a box has the size of its box" do
      space = :boids_space.new(%{bounds: {{0, 0, 0}, {9, 9, 9}}})
      assert :boids_space.dim(space) == 3
      assert :boids_space.fit(space, {1, 1, 1})
      refute :boids_space.fit(space, {1, 1})
      refute :boids_space.insert_new(space, entry(:a, {1, 1}))
    end

    test "a row is in the cell of its position" do
      # The cell of a new row at a position.
      cell = fn space, pos ->
        id = make_ref()
        true = :boids_space.insert_new(space, entry(id, pos))
        [{^id, ^pos, _vel, _group, _data, cell, _pid, _kind, _last}] = :ets.lookup(space.rows, id)
        assert [{^cell, ^id, ^pos, _, _, _}] = :ets.lookup(space.grid, cell)
        cell
      end

      assert cell.(:boids_space.new(%{cell_size: 10}), {25, -1}) == {2, -1}
      assert cell.(:boids_space.new(%{cell_size: 10}), {25.0, -0.5, 100.0}) == {2, -1, 10}
      flat = :boids_space.new(%{cell_size: 10, bounds: {{-5, -5}, {20, 20}}, wrap: true})
      assert cell.(flat, {-5, 14.9}) == {0, 1}
      # A point out of the box is in the cell of its point in the box.
      assert cell.(flat, {21, -6}) == {0, 2}
      deep = :boids_space.new(%{cell_size: 10, bounds: {{0, 0, 0}, {30, 30, 25}}, wrap: true})
      assert cell.(deep, {29.9, 0, 24.0}) == {2, 0, 2}
      assert cell.(deep, {31, -1, 26}) == {0, 2, 0}
    end

    test "put/2 writes the position, the velocity, the group and the data", %{space: space} do
      :boids_space.insert_new(space, entry(:a, {1, 2}, %{pid: self()}))
      assert :boids_space.put(space, %{id: :a, pos: {3, 4}, vel: {1, 0}, group: :bird, data: 7})

      assert :boids_space.lookup(space, :a) ==
               {:ok, %{id: :a, pos: {3, 4}, vel: {1, 0}, group: :bird, data: 7, pid: self()}}
    end

    test "put/2 moves the row to the cell of its new position", %{space: space} do
      :boids_space.insert_new(space, entry(:a, {1, 2}))
      assert :boids_space.put(space, %{id: :a, pos: {95, -42}, vel: {0, 0}, group: :default, data: nil})
      assert :ets.tab2list(space.grid) == [{{9, -5}, :a, {95, -42}, {0, 0}, :default, nil}]
      assert [%{id: :a}] = :boids_space.near(space, {95, -42}, 1)
      assert :boids_space.near(space, {1, 2}, 1) == []
    end

    test "put/2 with no change writes nothing", %{space: space} do
      :boids_space.insert_new(space, entry(:a, {1, 2}, %{group: :g, data: 1}))
      before = {:ets.tab2list(space.rows), :ets.tab2list(space.grid)}
      assert :boids_space.put(space, %{id: :a, pos: {1, 2}, vel: {0.0, 0.0}, group: :g, data: 1})
      assert {:ets.tab2list(space.rows), :ets.tab2list(space.grid)} == before
    end

    test "put/2 in the same cell changes the copy of the row in the grid", %{space: space} do
      :boids_space.insert_new(space, entry(:a, {1, 2}))
      assert :boids_space.put(space, %{id: :a, pos: {2, 3}, vel: {1, 1}, group: :g, data: 1})
      assert :ets.tab2list(space.grid) == [{{0, 0}, :a, {2, 3}, {1, 1}, :g, 1}]
      assert [%{id: :a, pos: {2, 3}, vel: {1, 1}, group: :g, data: 1}] = :boids_space.near(space, {2, 3}, 1)
    end

    test "put/2 of an id that is not in the space changes nothing", %{space: space} do
      refute :boids_space.put(space, %{id: :a, pos: {3, 4}, vel: {1, 0}, group: :bird, data: 7})
      assert :boids_space.count(space) == 0
      assert :ets.tab2list(space.grid) == []
    end

    test "remove/2 removes the copies of a boid that stopped in the middle of a write", %{space: space} do
      new = %{id: :a, pos: {55, 5}, vel: {1, 0}, group: :default, data: nil}
      old = {{0, 0}, :a, {1, 2}, {0.0, 0.0}, :default, :undefined}
      # The process stopped after the write of the row.
      :boids_space.insert_new(space, entry(:a, {1, 2}))
      assert :boids_space.put(space, new)
      [copy] = :ets.tab2list(space.grid)
      :ets.delete_object(space.grid, copy)
      :ets.insert(space.grid, old)
      assert :boids_space.remove(space, :a) == :ok
      assert :ets.tab2list(space.grid) == []
      # The process stopped after the write of the new copy.
      :boids_space.insert_new(space, entry(:a, {1, 2}))
      assert :boids_space.put(space, new)
      :ets.insert(space.grid, old)
      assert :boids_space.remove(space, :a) == :ok
      assert :ets.tab2list(space.grid) == []
      assert :ets.tab2list(space.rows) == []
    end

    test "remove/2 removes the row and its cell", %{space: space} do
      :boids_space.insert_new(space, entry(:a, {1, 2}))
      :boids_space.insert_new(space, entry(:b, {1, 3}))
      assert :boids_space.remove(space, :a) == :ok
      assert :boids_space.remove(space, :a) == :ok
      assert :boids_space.lookup(space, :a) == :error
      assert :ets.tab2list(space.grid) == [{{0, 0}, :b, {1, 3}, {0.0, 0.0}, :default, :undefined}]
      assert [%{id: :b}] = :boids_space.near(space, {1, 2}, 5)
    end
  end

  describe "near/3" do
    test "gives each boid with its offset and its distance, the nearest first" do
      space = :boids_space.new(%{})
      :boids_space.insert_new(space, entry(:far, {4, 0}, %{vel: {1, 1}, group: :fish, data: :x}))
      :boids_space.insert_new(space, entry(:near, {0, -3}))
      :boids_space.insert_new(space, entry(:out, {30, 0}))

      assert :boids_space.near(space, {0, 0}, 5) == [
               %{
                 id: :near,
                 pos: {0, -3},
                 vel: {0.0, 0.0},
                 group: :default,
                 data: :undefined,
                 offset: {0, -3},
                 dist: 3.0
               },
               %{id: :far, pos: {4, 0}, vel: {1, 1}, group: :fish, data: :x, offset: {4, 0}, dist: 4.0}
             ]
    end

    test "the limit of the radius is in the result" do
      space = :boids_space.new(%{})
      :boids_space.insert_new(space, entry(:a, {3, 4}))
      assert [%{id: :a}] = :boids_space.near(space, {0, 0}, 5)
      assert :boids_space.near(space, {0, 0}, 4.999) == []
      assert [%{id: :a, dist: +0.0}] = :boids_space.near(space, {3, 4}, 0)
    end

    test "a distance a little more than the radius is not in the result" do
      space = :boids_space.new(%{})
      :boids_space.insert_new(space, entry(:a, {1.0000001, 0.0}))
      :boids_space.insert_new(space, entry(:b, {0.0, 0.0, 1.0000001}))
      assert :boids_space.near(space, {0.0, 0.0}, 1.0) == []
      assert [%{id: :a}] = :boids_space.near(space, {0.0, 0.0}, 1.0000001)
    end

    test "a boid that is in two cells during the read is in the result one time" do
      space = :boids_space.new(%{})
      :boids_space.insert_new(space, entry(:a, {9, 9}))
      :boids_space.insert_new(space, entry(:b, {9, 8}))
      # The copy of a boid that goes from a cell to the next cell.
      :ets.insert(space.grid, {{1, 0}, :a, {11, 9}, {0, 0}, :default, :undefined})
      assert [:a, :b] = Enum.sort(Enum.map(:boids_space.near(space, {10, 9}, 5), & &1.id))
    end

    test "in three dimensions" do
      space = :boids_space.new(%{bounds: {{0, 0, 0}, {30, 30, 30}}, wrap: true})
      :boids_space.insert_new(space, entry(:a, {1, 1, 29}))
      :boids_space.insert_new(space, entry(:b, {1, 1, 15}))

      assert [%{id: :a, pos: {1.0, 1.0, -1.0}, offset: {+0.0, +0.0, -3.0}, dist: 3.0}] =
               :boids_space.near(space, {1, 1, 2}, 5)

      assert [%{id: :b}, %{id: :a}] = :boids_space.near(space, {1, 1, 14}, 20)
      free = :boids_space.new(%{})
      :boids_space.insert_new(free, entry(:a, {1, 1, 29}))
      assert [%{id: :a, pos: {1, 1, 29}, offset: {+0.0, +0.0, 3.0}}] = :boids_space.near(free, {1, 1, 26}, 5)
      # Numbers of the two kinds give the same result.
      assert [%{id: :a, pos: {1, 1, 29}, offset: {+0.0, +0.0, 3.0}}] =
               :boids_space.near(free, {1.0, 1.0, 26.0}, 5.0)
    end

    test "the ids 1 and 1.0 are two boids" do
      space = :boids_space.new(%{})
      :boids_space.insert_new(space, entry(1, {1, 1}))
      :boids_space.insert_new(space, entry(1.0, {2, 2}))
      assert [%{id: 1, pos: {1, 1}}, %{id: 1.0, pos: {2, 2}}] = :boids_space.near(space, {0, 0}, 5)
    end

    test "with wrap, a point at a side of the box is in a cell that a reader reads" do
      # The precision gives a number a little less than the minimum.
      space = :boids_space.new(%{bounds: {{0.1, 0.1}, {100.1, 100.1}}, wrap: true})
      :boids_space.insert_new(space, entry(:a, {100.1, 50}))
      assert [%{id: :a}] = :boids_space.near(space, {0.5, 50}, 1.0)
      assert [%{id: :a}] = :boids_space.near(space, {99.9, 50}, 1.0)
      # A point very near the maximum is at the width of the box for the precision.
      space = :boids_space.new(%{bounds: {{-100, -100}, {0, 0}}, wrap: true})
      :boids_space.insert_new(space, entry(:b, {-1.0e-20, -50}))
      assert :ets.tab2list(space.grid) |> hd() |> elem(0) == {9, 5}
      assert [%{id: :b, dist: 0.5}] = :boids_space.near(space, {-99.5, -50}, 1.0)
      assert [%{id: :b, dist: 0.5}] = :boids_space.near(space, {-0.5, -50}, 1.0)
    end

    test "boids at the same distance are in the order of their ids" do
      space = :boids_space.new(%{})
      for id <- [:c, :a, :b], do: :boids_space.insert_new(space, entry(id, {1, 1}))
      assert Enum.map(:boids_space.near(space, {0, 0}, 5), & &1.id) == [:a, :b, :c]
    end

    test "a large radius reads all the rows" do
      space = :boids_space.new(%{})
      :boids_space.insert_new(space, entry(:a, {1.0e6, 1.0e6}))
      :boids_space.insert_new(space, entry(:b, {-1.0e6, 0}))
      assert Enum.map(:boids_space.near(space, {0, 0}, 1.0e9), & &1.id) == [:b, :a]
      assert :boids_space.near(space, {0, 0}, 1.0e5) == []
    end

    test "with wrap, a boid across a side is near, at its nearest position" do
      space = :boids_space.new(%{bounds: {{0, 0}, {100, 100}}, wrap: true})
      :boids_space.insert_new(space, entry(:a, {99, 50}))
      :boids_space.insert_new(space, entry(:b, {50, 2}))

      assert [%{id: :a, pos: {-1.0, 50.0}, offset: {-2.0, +0.0}, dist: 2.0}] =
               :boids_space.near(space, {1, 50}, 5)

      assert [%{id: :b, pos: {50.0, 102.0}, dist: 3.0}] = :boids_space.near(space, {50, 99}, 5)
      assert [%{id: :a}] = :boids_space.near(space, {101, 50}, 5)
    end

    test "with wrap, a radius of half of the box reads all the cells" do
      space = :boids_space.new(%{bounds: {{0, 0}, {100, 100}}, wrap: true})
      for n <- 1..200, do: :boids_space.insert_new(space, entry(n, {rem(n * 37, 100), rem(n * 53, 100)}))
      assert length(:boids_space.near(space, {10, 10}, 80)) == 200
    end

    test "without wrap, the bounds change nothing" do
      space = :boids_space.new(%{bounds: {{0, 0}, {100, 100}}})
      :boids_space.insert_new(space, entry(:a, {99, 50}))
      assert :boids_space.near(space, {1, 50}, 5) == []
      assert :boids_space.offset(space, {1, 50}, {99, 50}) == {98, 0}
    end

    property "gives the same boids as a read of each row" do
      check all(
              d <- dim(),
              cell_size <- float(min: 1.0, max: 60.0),
              points <- list_of(vec(d, 100.0), max_length: 40),
              moves <- list_of(tuple({integer(0..39), vec(d, 100.0)}), max_length: 20),
              pos <- vec(d, 120.0),
              radius <- float(min: 0.0, max: 150.0)
            ) do
        space = :boids_space.new(%{cell_size: cell_size})
        check_near(space, points, moves, pos, radius)
      end
    end

    property "with wrap, gives the same boids as a read of each row" do
      check all(
              d <- dim(),
              cell_size <- float(min: 1.0, max: 60.0),
              width <- float(min: 5.0, max: 150.0),
              points <- list_of(vec(d, 200.0), max_length: 40),
              moves <- list_of(tuple({integer(0..39), vec(d, 200.0)}), max_length: 20),
              pos <- vec(d, 200.0),
              radius <- float(min: 0.0, max: 100.0)
            ) do
        min = if d == 2, do: {-10.0, 5.0}, else: {-10.0, 5.0, 0.0}
        max = :boids_vec.add(min, if(d == 2, do: {width, width * 1.5}, else: {width, width * 1.5, width / 2}))
        space = :boids_space.new(%{cell_size: cell_size, bounds: {min, max}, wrap: true})
        found = check_near(space, points, moves, pos, radius)

        for %{pos: seen, offset: offset, dist: dist} <- found do
          assert_vec(seen, :boids_vec.add(pos, offset), 1.0e-6)
          assert_in_delta dist, :boids_vec.norm(offset), 1.0e-9
        end
      end
    end
  end

  # Add the points, move some of them, and compare near/3 with a read of
  # each row.
  defp check_near(space, points, moves, pos, radius) do
    for {point, id} <- Enum.with_index(points), do: :boids_space.insert_new(space, entry(id, point))

    for {id, point} <- moves, id < length(points) do
      assert :boids_space.put(space, %{id: id, pos: point, vel: point, group: :default, data: nil})
    end

    entries = :boids_space.all(space)
    assert length(entries) == length(points)
    assert length(:ets.tab2list(space.grid)) == length(points)
    found = :boids_space.near(space, pos, radius)
    assert Enum.sort(Enum.map(found, & &1.id)) == Enum.sort(brute(space, entries, pos, radius))
    assert found == Enum.sort_by(found, &{&1.dist, &1.id})
    # A read of the rows of these boids gives the same, also with ids that
    # are not in the space, and with the ids of the boids that are too far.
    ids = [:nobody | Enum.map(entries, & &1.id)]
    assert :boids_space.seen(space, pos, radius, ids) == found
    assert :boids_space.seen(space, pos, radius, Enum.map(found, & &1.id)) == found
    :boids_space.delete(space)
    found
  end

  describe "seen/4" do
    test "gives the boids of a list of ids in the radius, the nearest first" do
      space = :boids_space.new(%{})
      :boids_space.insert_new(space, entry(:a, {4, 0}, %{group: :g, data: 1}))
      :boids_space.insert_new(space, entry(:b, {0, 2}))
      :boids_space.insert_new(space, entry(:c, {0, 9}))
      :boids_space.insert_new(space, entry(:d, {1, 0}))

      assert [
               %{id: :b, pos: {0, 2}, offset: {+0.0, 2.0}, dist: 2.0},
               %{id: :a, pos: {4, 0}, vel: {+0.0, +0.0}, group: :g, data: 1, offset: {4.0, +0.0}, dist: 4.0}
             ] = :boids_space.seen(space, {0, 0}, 5, [:a, :b, :c, :nobody])

      # The read gives the rows as they are now.
      :boids_space.put(space, %{id: :a, pos: {1, 0}, vel: {0, 0}, group: :g, data: 2})
      assert [%{id: :a, pos: {1, 0}, data: 2}] = :boids_space.seen(space, {0, 0}, 5, [:a])
      :boids_space.remove(space, :a)
      assert :boids_space.seen(space, {0, 0}, 5, [:a]) == []
      assert :boids_space.seen(space, {0, 0}, 5, []) == []
      assert_raise FunctionClauseError, fn -> :boids_space.seen(space, {0, 0}, -1, [:b]) end
    end

    test "with wrap, gives a boid across a side at its nearest position" do
      space = :boids_space.new(%{bounds: {{0, 0}, {100, 100}}, wrap: true})
      :boids_space.insert_new(space, entry(:a, {99, 50}))

      assert [%{id: :a, pos: {-1.0, 50.0}, offset: {-2.0, +0.0}, dist: 2.0}] =
               :boids_space.seen(space, {1, 50}, 5, [:a])

      assert :boids_space.seen(space, {1, 50}, 1, [:a]) == []
    end

    test "in three dimensions" do
      space = :boids_space.new(%{})
      :boids_space.insert_new(space, entry(:a, {1, 1, 4}))
      assert [%{id: :a, offset: {+0.0, +0.0, 3.0}, dist: 3.0}] = :boids_space.seen(space, {1, 1, 1}, 5, [:a])
    end
  end

  describe "the relations" do
    test "relate/4 writes the boids of a relation, and the reads give them" do
      space = :boids_space.new(%{})
      assert :boids_space.related(space, :a, :follows) == []
      assert :boids_space.related_to(space, :b, :follows) == []
      assert :boids_space.relate(space, :out, {:a, :follows}, [:b, :c]) == :ok
      assert :boids_space.relate(space, :in, {:b, :follows}, [:a]) == :ok
      assert :boids_space.related(space, :a, :follows) == [:b, :c]
      assert :boids_space.related_to(space, :b, :follows) == [:a]
      # The label and the direction are parts of the key.
      assert :boids_space.related(space, :a, :fears) == []
      assert :boids_space.related_to(space, :a, :follows) == []
      assert :boids_space.related(space, :b, :follows) == []
      # An empty list removes the row.
      assert :boids_space.relate(space, :out, {:a, :follows}, []) == :ok
      assert :boids_space.related(space, :a, :follows) == []
      assert :ets.tab2list(space.links) == [{{:in, :b, :follows}, [:a]}]
    end

    test "only the owner of the space writes the relations" do
      space = :boids_space.new(%{})
      task = Task.async(fn -> catch_error(:boids_space.relate(space, :out, {:a, :follows}, [:b])) end)
      assert Task.await(task) == :badarg
      assert :boids_space.related(space, :a, :follows) == []
    end
  end

  describe "the world" do
    setup do
      %{space: :boids_space.new(%{bounds: {{0, 0}, {50, 50}}})}
    end

    test "env/1 gives the box, the obstacles and the scale of the time", %{space: space} do
      assert :boids_space.env(space) == %{
               bounds: {{0, 0}, {50, 50}},
               wrap: false,
               obstacles: [],
               time_scale: 1.0
             }
    end

    test "the obstacles are in the order of their ids", %{space: space} do
      assert :boids_space.set_obstacle(space, :rock, {10, 10}, 3) == :ok
      assert :boids_space.set_obstacle(space, :pole, {20, 5}, 0.5) == :ok

      assert :boids_space.obstacles(space) == [
               %{id: :pole, pos: {20, 5}, radius: 0.5},
               %{id: :rock, pos: {10, 10}, radius: 3}
             ]

      assert :boids_space.env(space).obstacles == :boids_space.obstacles(space)
    end

    test "set_obstacle/4 moves an obstacle", %{space: space} do
      :boids_space.set_obstacle(space, :rock, {10, 10}, 3)
      :boids_space.set_obstacle(space, :rock, {11, 10}, 4)
      assert :boids_space.obstacles(space) == [%{id: :rock, pos: {11, 10}, radius: 4}]
    end

    test "remove_obstacle/2 removes an obstacle", %{space: space} do
      :boids_space.set_obstacle(space, :rock, {10, 10}, 3)
      assert :boids_space.remove_obstacle(space, :rock) == :ok
      assert :boids_space.remove_obstacle(space, :rock) == :ok
      assert :boids_space.obstacles(space) == []
    end

    test "set_obstacle/4 refuses a bad obstacle", %{space: space} do
      for {pos, radius} <- [
            {{10, 10}, -1},
            {{10, 10}, :big},
            {{10, 10}, 1.0e200},
            {:here, 1},
            {{1}, 1},
            {{:a, :b}, 1},
            {{1.0e200, 0}, 1},
            {{10, 10, 10}, 1}
          ] do
        assert_raise ArgumentError, fn -> :boids_space.set_obstacle(space, :rock, pos, radius) end
      end

      assert :boids_space.obstacles(space) == []
    end

    test "env/3 gives the obstacles near a point, and env/1 all the obstacles", %{space: space} do
      :boids_space.set_obstacle(space, :near, {12, 10}, 1)
      :boids_space.set_obstacle(space, :far, {40, 40}, 1)

      assert %{obstacles: [%{id: :near}], bounds: {{0, 0}, {50, 50}}, time_scale: 1.0} =
               :boids_space.env(space, {10, 10}, 3)

      assert [%{id: :far}, %{id: :near}] = :boids_space.env(space).obstacles
    end

    test "set_time_scale/2 sets the scale of the time", %{space: space} do
      assert :boids_space.set_time_scale(space, 0) == :ok
      assert :boids_space.env(space).time_scale == 0
      assert :boids_space.set_time_scale(space, 86_400.0) == :ok
      assert :boids_space.env(space).time_scale == 86_400.0
      assert_raise ArgumentError, fn -> :boids_space.set_time_scale(space, -1) end
      assert_raise ArgumentError, fn -> :boids_space.set_time_scale(space, 1.0e200) end
      assert_raise ArgumentError, fn -> :boids_space.set_time_scale(space, :fast) end
      assert :boids_space.env(space).time_scale == 86_400.0
    end
  end

  describe "the obstacles near a point" do
    # The obstacles to the distance, with a read of all the obstacles.
    defp brute_obstacles(space, pos, reach) do
      for o = %{pos: at, radius: radius} <- :boids_space.obstacles(space),
          tuple_size(at) == tuple_size(pos),
          :boids_vec.norm(:boids_space.offset(space, pos, at)) <= reach + radius,
          do: o
    end

    # The rows of the index of an obstacle: its cells, or [:large]. Its
    # coarse cells are apart.
    defp cells(space, id),
      do:
        Enum.sort(
          for {cell, ^id} <- :ets.tab2list(space.obstacle_cells), not match?({:coarse, _}, cell), do: cell
        )

    defp coarse(space, id),
      do: Enum.sort(for {{:coarse, cell}, ^id} <- :ets.tab2list(space.obstacle_cells), do: cell)

    test "gives the obstacles to the distance, also one with its center in a far cell" do
      space = :boids_space.new(%{cell_size: 2})
      # The center is 20 away, and the edge 5 away.
      :boids_space.set_obstacle(space, :hill, {20, 0}, 15)
      :boids_space.set_obstacle(space, :rock, {1, 1}, 0.5)
      :boids_space.set_obstacle(space, :far, {100, 100}, 1)
      assert [%{id: :hill}, %{id: :rock}] = :boids_space.obstacles(space, {0, 0}, 6)
      assert [%{id: :rock}] = :boids_space.obstacles(space, {0, 0}, 4)
      assert :boids_space.obstacles(space, {-50, -50}, 4) == []
      # The obstacles are in the order of their ids, as in obstacles/1.
      assert :boids_space.obstacles(space, {0, 0}, 1000) == :boids_space.obstacles(space)
    end

    test "an obstacle larger than a cell is in each cell that it touches" do
      space = :boids_space.new(%{cell_size: 1})
      :boids_space.set_obstacle(space, :pond, {0.5, 0.5}, 10)
      assert length(cells(space, :pond)) == 21 * 21
      assert [%{id: :pond}] = :boids_space.obstacles(space, {10.4, 0.5}, 0.1)
      assert :boids_space.obstacles(space, {11, 0.5}, 0.1) == []
    end

    test "an obstacle larger than 1,024 cells is a large obstacle, which each read gets" do
      space = :boids_space.new(%{cell_size: 1})
      :boids_space.set_obstacle(space, :sea, {0, 0}, 100)
      for id <- 1..50, do: :boids_space.set_obstacle(space, id, {id * 10, 500}, 1)
      assert cells(space, :sea) == [:large]
      assert [%{id: :sea}] = :boids_space.obstacles(space, {0, 101}, 2)
      assert :boids_space.obstacles(space, {0, 104}, 2) == []
      # A large obstacle that becomes small goes into its cells.
      :boids_space.set_obstacle(space, :sea, {0, 0}, 1)
      assert length(cells(space, :sea)) == 9
      assert :ets.lookup(space.obstacle_cells, :large) == []
    end

    test "an obstacle that moves goes to its new cells, and leaves its old cells" do
      space = :boids_space.new(%{cell_size: 10})
      :boids_space.set_obstacle(space, :rock, {5, 5}, 1)
      assert cells(space, :rock) == [{0, 0}]
      :boids_space.set_obstacle(space, :rock, {15, 5}, 6)
      # From {9, -1} to {21, 11}.
      assert cells(space, :rock) == for(x <- 0..2, y <- -1..1, do: {x, y})
      # A coarse cell is 8 cells long on each side.
      assert coarse(space, :rock) == [{0, -1}, {0, 0}]
      :boids_space.set_obstacle(space, :rock, {55, 55}, 1)
      assert cells(space, :rock) == [{5, 5}]
      assert coarse(space, :rock) == [{0, 0}]
      assert :boids_space.obstacles(space, {5, 5}, 5) == []
      assert [%{id: :rock, pos: {55, 55}}] = :boids_space.obstacles(space, {50, 50}, 7)
      :boids_space.remove_obstacle(space, :rock)
      assert :ets.tab2list(space.obstacle_cells) == []
      assert :boids_space.obstacles(space, {50, 50}, 7) == []
    end

    test "with wrap, a point gets an obstacle across a side" do
      space = :boids_space.new(%{cell_size: 5, bounds: {{0, 0}, {100, 100}}, wrap: true})
      :boids_space.set_obstacle(space, :rock, {98, 50}, 1)
      :boids_space.set_obstacle(space, :pole, {50, 1}, 2)
      assert [%{id: :rock}] = :boids_space.obstacles(space, {1, 50}, 3)
      assert [%{id: :pole}] = :boids_space.obstacles(space, {50, 98}, 2)
      assert :boids_space.obstacles(space, {50, 50}, 10) == []
      # An obstacle that crosses a side is in the cells of the two sides.
      assert cells(space, :pole) == [{9, 0}, {9, 19}, {10, 0}, {10, 19}]
    end

    test "an obstacle with a center of another size is not in the result" do
      space = :boids_space.new(%{})
      :boids_space.set_obstacle(space, :ball, {1, 1, 1}, 1)
      :boids_space.set_obstacle(space, :rock, {1, 1}, 1)
      assert [%{id: :rock}] = :boids_space.obstacles(space, {0, 0}, 5)
      # With few obstacles, a read of all the rows costs less than a read
      # of the cells: the result is the same.
      assert [%{id: :rock}] = :boids_space.obstacles(space, {0, 0}, 50)
    end

    property "gives the obstacles that a read of all the obstacles gives" do
      check all(
              wrap <- boolean(),
              cell_size <- one_of([constant(1), constant(4), float(min: 0.5, max: 20)]),
              obstacles <-
                list_of(tuple({float(min: 0, max: 99), float(min: 0, max: 99), float(min: 0, max: 30)}),
                  max_length: 40
                ),
              moves <-
                list_of(tuple({integer(0..39), float(min: 0, max: 99), float(min: 0, max: 99)}),
                  max_length: 10
                ),
              points <-
                list_of(tuple({float(min: -10, max: 110), float(min: -10, max: 110), float(min: 0, max: 40)}),
                  length: 5
                )
            ) do
        space = :boids_space.new(%{cell_size: cell_size, bounds: {{0, 0}, {100, 100}}, wrap: wrap})
        for {{x, y, r}, id} <- Enum.with_index(obstacles), do: :boids_space.set_obstacle(space, id, {x, y}, r)
        for {id, x, y} <- moves, id < length(obstacles), do: :boids_space.set_obstacle(space, id, {x, y}, 2)

        for {x, y, reach} <- points,
            do: assert(:boids_space.obstacles(space, {x, y}, reach) == brute_obstacles(space, {x, y}, reach))

        :boids_space.delete(space)
      end
    end

    test "a read finds an obstacle that moves one time: not two times, and not zero times" do
      space = :boids_space.new(%{cell_size: 1})
      # Many obstacles far away: a read uses the cells (49 cells here).
      for id <- 1..100, do: :boids_space.set_obstacle(space, id, {id * 1.0, -20.0}, 0.4)
      :boids_space.set_obstacle(space, :rock, {0.5, 0.5}, 0.4)

      # Another process reads, as a boid does.
      reader =
        Task.async(fn ->
          Enum.frequencies(
            for _ <- 1..20_000, do: Enum.count(:boids_space.obstacles(space, {2, 2}, 3), &(&1.id == :rock))
          )
        end)

      # The owner moves the rock from cell to cell, near the point of the
      # reads. A read can see a write in its middle: then it reads all
      # the rows.
      moves =
        Stream.cycle([{0.5, 0.5}, {3.5, 0.5}, {3.5, 3.5}, {0.5, 3.5}])
        |> Enum.reduce_while(0, fn pos, moves ->
          :boids_space.set_obstacle(space, :rock, pos, 0.4)
          if Process.alive?(reader.pid), do: {:cont, moves + 1}, else: {:halt, moves + 1}
        end)

      assert Task.await(reader) == %{1 => 20_000}
      assert moves > 100
    end

    test "a read during a write reads all the rows, and not the cells" do
      space = :boids_space.new(%{cell_size: 1})
      for id <- 1..100, do: :boids_space.set_obstacle(space, id, {id * 1.0, -20.0}, 0.4)
      :boids_space.set_obstacle(space, :rock, {5, 5}, 1)
      # The state in the middle of a write: an odd version, and an index
      # that does not have the cells of the rock.
      :ets.update_counter(space.facts, :obstacle_version, 1)

      for row = {_cell, :rock} <- :ets.tab2list(space.obstacle_cells),
          do: :ets.delete_object(space.obstacle_cells, row)

      assert [%{id: :rock}] = :boids_space.obstacles(space, {5, 5}, 1)
      # With an even version, a read uses the cells.
      :ets.update_counter(space.facts, :obstacle_version, 1)
      assert :boids_space.obstacles(space, {5, 5}, 1) == []
    end

    test "only the owner of the space writes the obstacles and the scale of the time" do
      space = :boids_space.new(%{cell_size: 1})
      :boids_space.set_obstacle(space, :rock, {5, 5}, 1)

      tables = fn ->
        {Enum.sort(:ets.tab2list(space.facts)), Enum.sort(:ets.tab2list(space.obstacle_cells))}
      end

      before = tables.()

      Task.await(
        Task.async(fn ->
          assert_raise ArgumentError, fn -> :boids_space.set_obstacle(space, :rock, {50, 50}, 1) end
          assert_raise ArgumentError, fn -> :boids_space.set_obstacle(space, :pole, {1, 1}, 1) end
          assert_raise ArgumentError, fn -> :boids_space.remove_obstacle(space, :rock) end
          assert_raise ArgumentError, fn -> :boids_space.set_time_scale(space, 2) end
          # A read needs no message, from each process.
          assert [%{id: :rock, pos: {5, 5}}] = :boids_space.obstacles(space, {5, 5}, 1)
          assert :boids_space.env(space).time_scale == 1.0
        end)
      )

      # Nothing changed: the version is even, as before.
      assert tables.() == before
      assert rem(:ets.lookup_element(space.facts, :obstacle_version, 2), 2) == 0
    end
  end

  describe "the grids" do
    setup do
      %{space: :boids_space.new(%{}), grid: :boids_grid.from_rows(["..#", "..."], [])}
    end

    test "set_grid/3 gives a name to a grid, and remove_grid/2 removes it", %{space: space, grid: grid} do
      assert :boids_space.grid(space, :land) == :error
      assert :boids_space.set_grid(space, :land, grid) == :ok
      assert :boids_space.grid(space, :land) == {:ok, grid}
      door = :boids_grid.set_cost(grid, [{2, 0}], 1)
      assert :boids_space.set_grid(space, :land, door) == :ok
      assert :boids_space.grid(space, :land) == {:ok, door}
      assert :boids_space.set_grid(space, {:room, 2}, grid) == :ok
      assert :boids_space.remove_grid(space, :land) == :ok
      assert :boids_space.grid(space, :land) == :error
      assert :boids_space.grid(space, {:room, 2}) == {:ok, grid}
      # Each change adds 1 to the number of the changes.
      assert :atomics.get(space.changes, 1) == 4
    end

    test "set_grid/3 refuses a value that is not a grid, with no change", %{space: space} do
      assert_raise ArgumentError, fn -> :boids_space.set_grid(space, :land, :walls) end
      assert_raise ArgumentError, fn -> :boids_space.set_grid(space, :land, {:boids_grid, 1}) end
      assert :boids_space.grid(space, :land) == :error
      assert :atomics.get(space.changes, 1) == 0
    end

    test "only the owner of the space writes the grids", %{space: space, grid: grid} do
      :boids_space.set_grid(space, :land, grid)

      Task.await(
        Task.async(fn ->
          assert_raise ArgumentError, fn -> :boids_space.set_grid(space, :land, grid) end
          assert_raise ArgumentError, fn -> :boids_space.set_grid(space, :sea, grid) end
          assert_raise ArgumentError, fn -> :boids_space.remove_grid(space, :land) end
          # A read needs no message, from each process.
          assert :boids_space.grid(space, :land) == {:ok, grid}
        end)
      )

      # Nothing changed, and the number of the changes is the same.
      assert :boids_space.grid(space, :sea) == :error
      assert :atomics.get(space.changes, 1) == 1
    end

    test "named/3 gives the grids of the keys, and a name with no grid is absent", %{space: space, grid: grid} do
      :boids_space.set_grid(space, :land, grid)

      assert {%{grids: %{land: ^grid} = grids}, _} =
               :boids_space.named(space, [grid: :land, grid: :sea], :undefined)

      assert map_size(grids) == 1
      # A boid with no name reads nothing, and keeps nothing.
      assert :boids_space.named(space, [], :undefined) == {%{grids: %{}}, :undefined}
    end

    test "named/3 reads the rows again only after a change", %{space: space, grid: grid} do
      :boids_space.set_grid(space, :land, grid)
      keys = [grid: :land]
      {named, kept} = :boids_space.named(space, keys, :undefined)
      assert :boids_space.named(space, keys, kept) == {named, kept}
      # A row that changes with no new number of changes (not a write of
      # the library) shows that the read uses what the process kept.
      door = :boids_grid.set_cost(grid, [{2, 0}], 1)
      :ets.insert(space.facts, {{:grid, :land}, door})
      assert :boids_space.named(space, keys, kept) == {named, kept}
      # A write of the library: the next read gets the new grid.
      :boids_space.set_grid(space, :land, door)
      assert {%{grids: %{land: ^door}}, kept2} = :boids_space.named(space, keys, kept)
      assert kept2 != kept
      # A grid that goes.
      :boids_space.remove_grid(space, :land)
      assert {%{grids: grids}, _} = :boids_space.named(space, keys, kept2)
      assert grids == %{}
      # Other keys: the read does not use what it kept for the old keys.
      :boids_space.set_grid(space, :sea, grid)
      {_, kept3} = :boids_space.named(space, keys, :undefined)
      assert {%{grids: %{sea: ^grid}}, _} = :boids_space.named(space, [grid: :sea], kept3)
    end

    test "named/2 keeps the grids in the process that calls, and forget/1 removes them", %{
      space: space,
      grid: grid
    } do
      :boids_space.set_grid(space, :land, grid)
      key = {:boids_space, :kept, space.facts}
      assert :boids_space.named(space, []) == %{grids: %{}}
      assert Process.get(key) == nil
      assert :boids_space.named(space, grid: :land) == %{grids: %{land: grid}}
      assert {1, [grid: :land], %{grids: %{land: ^grid}}} = kept = Process.get(key)
      # No change: the process keeps the same term.
      assert :boids_space.named(space, grid: :land) == %{grids: %{land: grid}}
      assert Process.get(key) === kept
      :boids_space.remove_grid(space, :land)
      assert :boids_space.named(space, grid: :land) == %{grids: %{}}
      assert {2, _, _} = Process.get(key)
      assert :boids_space.forget(space) == :ok
      assert Process.get(key) == nil
      # Another process has its own.
      Task.await(Task.async(fn -> assert Process.get(key) == nil end))
    end
  end

  describe "the processes" do
    test "another process reads and writes the tables" do
      space = :boids_space.new(%{})
      :boids_space.insert_new(space, entry(:a, {1, 2}))

      task =
        Task.async(fn ->
          true = :boids_space.put(space, %{id: :a, pos: {5, 5}, vel: {1, 1}, group: :default, data: nil})
          :boids_space.near(space, {5, 5}, 1)
        end)

      assert [%{id: :a, pos: {5, 5}}] = Task.await(task)
    end

    test "the tables go with their owner" do
      {:ok, pid} = Agent.start(fn -> :boids_space.new(%{}) end)
      space = Agent.get(pid, & &1)
      assert space.owner == pid
      Agent.stop(pid)
      assert :ets.info(space.rows) == :undefined
      assert :ets.info(space.links) == :undefined
    end
  end
end
