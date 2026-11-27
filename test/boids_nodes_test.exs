defmodule BoidsNodesTest do
  # A world on several nodes: the tiles and their node, a boid that shows
  # itself at a border, and a boid that moves to another node.
  use ExUnit.Case, async: false
  import Boids.Helpers

  alias Boids.TestBoids.{Hawk, Mouse}

  @moduletag :capture_log
  @tile 160.0

  defp name, do: :"world#{System.unique_integer([:positive])}"

  describe "the tiles of a world, on one node" do
    setup do
      space = :boids_space.new(%{})
      on_exit(fn -> :ok end)
      %{space: space}
    end

    test "a world has tiles of 16 cells, or of the option tile" do
      assert :boids_space.new(%{}).tile == 160.0
      assert :boids_space.new(%{cell_size: 5}).tile == 80
      assert :boids_space.new(%{tile: 50}).tile == 50
      assert_raise ErlangError, fn -> :boids_space.new(%{tile: 0}) end
      assert_raise ErlangError, fn -> :boids_space.new(%{tile: :large}) end
      assert :boids.start_world(tile: -1) == {:error, {:bad_option, {:tile, -1}}}
    end

    test "with one node, each position is at home", %{space: space} do
      assert :boids_space.nodes(space) == [node()]
      assert :boids_space.home(space, {12_345, -678}) == node()
      assert :boids_space.place(space, {160, 160}, 50) == :home
    end

    test "the names of the nodes give the node of each tile", %{space: space} do
      nodes = [node(), :"b@127.0.0.1", :"c@127.0.0.1"]
      :ok = :boids_space.set_nodes(space, nodes ++ [node()])
      assert :boids_space.nodes(space) == Enum.sort(nodes)
      homes = for i <- 0..199, do: :boids_space.home(space, {i * @tile + 1, 1})
      # Each node has a part of the tiles.
      assert Enum.sort(Enum.uniq(homes)) == Enum.sort(nodes)
      # All the positions of a tile have the node of the tile.
      for i <- 0..20 do
        home = :boids_space.home(space, {i * @tile, 0})
        assert :boids_space.home(space, {i * @tile + 159.9, 159.9}) == home
      end

      # A new node takes only tiles: the other tiles keep their node.
      :ok = :boids_space.set_nodes(space, [:"d@127.0.0.1" | nodes])
      again = for i <- 0..199, do: :boids_space.home(space, {i * @tile + 1, 1})
      assert Enum.all?(Enum.zip(homes, again), fn {before, now} -> now == before or now == :"d@127.0.0.1" end)
      assert :"d@127.0.0.1" in again
    end

    test "place/3 tells if a boid is at home, near a border, or away", %{space: space} do
      other = :"b@127.0.0.1"
      :ok = :boids_space.set_nodes(space, [node(), other])
      tiles = for i <- 0..400, do: {i, :boids_space.home(space, {i * @tile + 80, 80})}
      # Two tiles of this node, then a tile of the other node.
      {i, _} =
        Enum.find(tiles, fn {i, home} ->
          home == node() and tiles |> Enum.at(i + 1) |> elem(1) == node() and
            tiles |> Enum.at(i + 2) |> elem(1) == other
        end)

      rows = for j <- [-1, 0, 1], do: :boids_space.home(space, {i * @tile + 80, j * @tile + 80})

      if Enum.all?(rows, &(&1 == node())) do
        assert :boids_space.place(space, {i * @tile + 150, 80}, 5) == :home
      end

      border = (i + 2) * @tile
      assert :boids_space.place(space, {border - 80, 80}, 0) == :home
      assert :boids_space.place(space, {border - 3, 80}, 5) == {:border, [other]}
      assert :boids_space.place(space, {border + 3, 80}, 0) == {:away, other, []}
      assert {:away, ^other, []} = :boids_space.place(space, {border + 3, 80}, 5)
    end

    test "a boid away from its node can see tiles of more nodes" do
      space = :boids_space.new(%{})
      nodes = [node(), :"b@127.0.0.1", :"c@127.0.0.1"]
      :ok = :boids_space.set_nodes(space, nodes)

      places =
        for i <- 0..300, j <- 0..3 do
          :boids_space.place(space, {i * @tile + 1, j * @tile + 1}, 5)
        end

      # At a corner of tiles of three nodes, a boid sees the two other nodes.
      assert Enum.any?(places, &match?({:border, [_, _]}, &1))
      assert Enum.any?(places, &match?({:away, _, [_]}, &1))
    end

    test "the tiles of a world with wrap and of a world in three dimensions" do
      wrapped = :boids_space.new(%{bounds: {{0, 0}, {640, 640}}, wrap: true})
      other = :"b@127.0.0.1"
      :ok = :boids_space.set_nodes(wrapped, [node(), other])
      # A position out of the box is in the tile of its position in the box.
      for x <- [1, 200, 400, 600] do
        assert :boids_space.home(wrapped, {x + 640, 1 - 640}) == :boids_space.home(wrapped, {x, 1})
      end

      # A boid at a side of the box sees the tile across that side.
      across = :boids_space.home(wrapped, {639, 1})
      here = :boids_space.home(wrapped, {1, 1})

      case :boids_space.place(wrapped, {1, 80}, 5) do
        :home -> assert across == here and here == node()
        {:border, [^other]} -> assert here == node()
        {:away, ^other, _} -> assert here == other
      end

      cube = :boids_space.new(%{})
      :ok = :boids_space.set_nodes(cube, [node(), other])
      homes = for i <- 0..40, do: :boids_space.home(cube, {1, 1, i * @tile + 1})
      assert Enum.sort(Enum.uniq(homes)) == [other, node()] |> Enum.sort()
      places = for i <- 0..40, do: :boids_space.place(cube, {80, 80, i * @tile + 1}, 5)
      assert Enum.any?(places, &match?({:border, [^other]}, &1))
      assert Enum.any?(places, &match?({:away, ^other, _}, &1))
    end
  end

  describe "the rows of the boids of another node" do
    test "show/2 writes a row that near/3 and lookup/2 give, and that the count does not have" do
      space = :boids_space.new(%{})
      remote = spawn(fn -> :ok end)

      assert :boids_space.insert_new(space, %{id: :mine, pos: {0, 0}, vel: {0, 0}, pid: self(), kind: :server})

      entry = %{id: :far, pos: {3, 0}, vel: {1, 0}, group: :birds, data: :blue, pid: remote, kind: :server}
      assert :boids_space.show(space, entry)
      assert :boids_space.owner(space, :far) == {{:ghost, :server}, remote}

      assert {:ok, %{id: :far, pos: {3, 0}, group: :birds, data: :blue, pid: ^remote}} =
               :boids_space.lookup(space, :far)

      assert [%{id: :mine}, %{id: :far, dist: 3.0}] = :boids_space.near(space, {0, 0}, 5)
      assert :boids_space.count(space) == 1
      assert [%{id: :mine}] = :boids_space.all(space)
      assert :boids_space.servers(space) == [self()]

      # The next row of the boid: it moved to another cell, and its process is another process.
      other = spawn(fn -> :ok end)
      assert :boids_space.show(space, %{id: :far, pos: {23, 0}, vel: {1, 0}, pid: other, kind: :process})
      assert :boids_space.owner(space, :far) == {{:ghost, :process}, other}
      assert [%{id: :mine}] = :boids_space.near(space, {0, 0}, 5)
      assert [%{id: :far, group: :default, data: :undefined}] = :boids_space.near(space, {23, 0}, 1)
      # The same row again changes nothing.
      assert :boids_space.show(space, %{id: :far, pos: {23, 0}, vel: {1, 0}, pid: other, kind: :process})
      assert [%{id: :far}] = :boids_space.near(space, {23, 0}, 1)
      assert :ets.info(space.grid, :size) == 2

      # A boid of this node keeps its row.
      refute :boids_space.show(space, %{id: :mine, pos: {9, 9}, vel: {0, 0}, pid: remote})
      assert {:ok, %{pos: {0, 0}}} = :boids_space.lookup(space, :mine)
      # A position of another size is not in the space.
      refute :boids_space.show(space, %{id: :cube, pos: {1, 1, 1}, vel: {0, 0, 0}, pid: remote})
      :ok = :boids_space.remove(space, :far)
      assert :ets.info(space.grid, :size) == 1
    end

    test "the world removes a row that gets no update for half a second" do
      world = name()
      {:ok, pid} = :boids.start_world(name: world)
      on_exit(fn -> :boids.stop_world(pid) end)
      remote = spawn(fn -> Process.sleep(:infinity) end)
      entry = %{id: :far, pos: {3, 0}, vel: {1, 0}, group: :birds, data: nil, pid: remote, kind: :server}
      send(world, {:show, entry})
      assert eventually(fn -> match?({:ok, _}, :boids.lookup(world, :far)) end)
      assert :boids.count(world) == 0
      # Updates keep the row.
      for _ <- 1..8 do
        Process.sleep(100)
        send(world, {:show, entry})
      end

      assert {:ok, _} = :boids.lookup(world, :far)
      assert :boids.whereis(world, :far) == remote
      Process.sleep(900)
      assert :boids.lookup(world, :far) == :error

      # A row of a boid of this node is not such a row.
      {:ok, :mine} = :boids.add(world, id: :mine, pos: {0, 0}, tick: :manual)
      send(world, {:show, %{entry | id: :mine}})
      Process.sleep(900)
      assert {:ok, %{pos: {0, 0}}} = :boids.lookup(world, :mine)
    end

    test "a boid that comes to this node takes the row that showed it" do
      world = name()
      {:ok, pid} = :boids.start_world(name: world, defaults: %{tick: :manual})
      on_exit(fn -> :boids.stop_world(pid) end)
      remote = spawn(fn -> Process.sleep(:infinity) end)
      send(world, {:show, %{id: :hawk, pos: {3, 0}, vel: {1, 0}, pid: remote, kind: :server}})
      assert eventually(fn -> :boids.whereis(world, :hawk) == remote end)
      {:ok, hawk} = :gen_boid.start(world, Mouse, %{id: :hawk, pos: {5, 5}})
      assert :boids_space.owner(:boids.space(world), :hawk) == {:server, hawk}
      assert :boids.count(world) == 1
      # The sweep does not remove the row of the boid of this node.
      Process.sleep(900)
      assert {:ok, %{pos: {5, 5}}} = :boids.lookup(world, :hawk)
    end

    test "a boid near a border of its node shows itself, and a boid of another node does not" do
      world = name()
      {:ok, pid} = :boids.start_world(name: world, defaults: %{tick: :manual, rules: []})
      on_exit(fn -> :boids.stop_world(pid) end)
      space = :boids.space(world)
      other = :"other@127.0.0.1"
      :ok = :boids_space.set_nodes(space, [node(), other])
      i = Enum.find(0..400, &(:boids_space.home(space, {&1 * @tile + 80, 80}) == other))
      {:ok, id} = :boids.add(world, pos: {i * @tile + 80, 80})

      # The boid is in a tile of a node that does not answer: it stays,
      # and it tries again at its next step.
      for _ <- 1..3, do: :ok = :boids.step(world, 0.05)
      assert {:server, boid} = :boids_space.owner(space, id)
      assert Process.alive?(boid)

      # A boid that is not in the world, and the row of a boid of another node, show nothing.
      assert :boids.commit(space, :boids_boid.new(%{id: :nobody, pos: {i * @tile + 80, 80}})) == :ok
      remote = spawn(fn -> :ok end)
      assert :boids_space.show(space, %{id: :far, pos: {i * @tile + 80, 80}, vel: {0, 0}, pid: remote})

      assert :boids_world.settle(space, :boids_boid.new(%{id: :far, pos: {i * @tile + 80, 80}})) ==
               {:away, other}

      # A boid at home shows nothing.
      j = Enum.find(0..400, &(:boids_space.place(space, {&1 * @tile + 80, 80}, 10) == :home))
      assert :boids_world.settle(space, :boids_boid.new(%{id: :far, pos: {j * @tile + 80, 80}})) == :home
    end

    test "a node keeps the process of a boid that made the most moves" do
      world = name()
      {:ok, pid} = :boids.start_world(name: world, defaults: %{tick: :manual, rules: []})
      on_exit(fn -> :boids.stop_world(pid) end)
      space = :boids.space(world)
      process = %{tick: :manual, max_dt: 0.25, search: 1, priority: :low, hibernate: true}

      # A boid that comes from another node, after a number of moves.
      coming = fn id, module, moves, data ->
        boid = :boids_boid.new(%{id: id, pos: {1, 1}, rules: [], data: data})
        :gen_boid.adopt(world, %{boid: boid, mod: module, server: process, relations: [], moves: moves})
      end

      {:ok, old} = :gen_boid.start(world, Mouse, %{id: :mouse, pos: {0, 0}, data: :old})
      ref = Process.monitor(old)
      # After a lost answer of a move, the node has an old process of the
      # boid. The process with more moves takes its place.
      assert {:ok, new} = coming.(:mouse, Mouse, 1, :new)
      assert_receive {:DOWN, ^ref, :process, ^old, {:shutdown, :replaced}}
      assert :boids_space.owner(space, :mouse) == {:server, new}
      assert {:ok, %{data: :new, pos: {1, 1}}} = :boids.lookup(world, :mouse)
      assert :boids.count(world) == 1
      # A process that is not newer does not: the node has the boid.
      assert coming.(:mouse, Mouse, 1, :same) == {:error, {:exists, :mouse}}
      assert coming.(:mouse, Mouse, 0, :older) == {:error, {:exists, :mouse}}
      assert {:ok, %{data: :new}} = :boids.lookup(world, :mouse)
      # The end of the old process does not remove the row of the new process.
      Process.sleep(50)
      assert :boids_space.owner(space, :mouse) == {:server, new}

      # A module that traps exits stops too, and its terminate/2 runs.
      {:ok, hawk} = :gen_boid.start(world, Hawk, %{owner: self(), trap: true, boid: %{id: :hawk}})
      assert {:ok, newer} = coming.(:hawk, Mouse, 3, :new)
      assert_receive {:terminated, {:shutdown, :replaced}, :hawk, 0}
      assert eventually(fn -> not Process.alive?(hawk) end)
      assert :boids_space.owner(space, :hawk) == {:server, newer}

      # A process of yours keeps its row.
      {:ok, _space, _boid} = :boids.join(world, id: :person, pos: {0, 0})
      assert coming.(:person, Mouse, 9, :new) == {:error, {:exists, :person}}
      assert :boids_space.owner(space, :person) == {:process, self()}
    end

    test "the world process answers for a boid that is not its boid" do
      world = name()
      {:ok, pid} = :boids.start_world(name: world, defaults: %{tick: :manual, rules: []})
      on_exit(fn -> :boids.stop_world(pid) end)
      space = :boids.space(world)
      {:ok, id} = :boids.add(world, pos: {0, 0})
      # The message of a process that is not the process of the boid changes nothing.
      assert :boids_world.moved(space, id, self()) == :ok
      assert :boids_world.moved(space, :nobody, self()) == :ok
      assert {:ok, _} = :boids.lookup(world, id)
      # A world with one node finds only its own boids.
      assert :boids_world.find(space, :nobody) == :error
      assert :boids.whereis(world, :nobody) == :undefined
      assert :boids_world.find_local(world, :nobody) == :error
      assert {:server, _} = :boids_world.find_local(world, id)
      assert :boids.nodes(world) == [node()]
      # A relation needs a boid of this node that has it. The other boid
      # is in the world, or the caller found it on another node.
      assert :boids_world.relate(space, :nobody, :likes, id, true) == {:error, {:not_found, :nobody}}
      assert :boids_world.relate(space, id, :likes, :nobody, false) == {:error, {:not_found, :nobody}}
      assert :boids_world.relate(space, id, :likes, :nobody, true) == :ok
      assert :boids.related(world, id, :likes) == [:nobody]
      assert :boids_world.unrelate(space, id, :likes, :nobody) == :ok
      assert :boids.related(world, id, :likes) == []
    end
  end
end

defmodule BoidsClusterTest do
  # A world on real nodes: the nodes of Boids.Cluster.
  use ExUnit.Case, async: false
  import Boids.Helpers
  import Boids.Cluster, only: [call: 4]

  alias Boids.Cluster
  alias Boids.TestBoids.{Hawk, Person, Traveler}

  @moduletag :capture_log
  @tile 160.0

  defp name, do: :"world#{System.unique_integer([:positive])}"

  # A boid that does not move.
  defp still(more), do: Map.merge(%{rules: [], max_speed: 0, tick: 20}, Map.new(more))

  # A boid that moves along x with a constant speed.
  defp mover(more, speed \\ 40) do
    Map.merge(
      %{rules: [], vel: {speed, 0}, min_speed: abs(speed), max_speed: abs(speed), tick: 20},
      Map.new(more)
    )
  end

  setup_all do
    nodes = Cluster.start(2)
    on_exit(fn -> Cluster.stop(nodes) end)
    %{nodes: nodes}
  end

  describe "a world on two nodes" do
    # A world with a name on the two nodes, and a border between a tile
    # of one node (left) and a tile of the other node (right).
    defp world(nodes, more \\ %{}) do
      world = name()
      options = Map.merge(%{name: world, defaults: %{rules: [], tick: 20}}, more)
      for {peer, _} <- nodes, do: {:ok, _} = call(peer, :boids, :start_world, [options])
      [{a, na}, {b, nb}] = nodes
      assert eventually(fn -> call(a, :boids, :nodes, [world]) == Enum.sort([na, nb]) end)
      assert eventually(fn -> call(b, :boids, :nodes, [world]) == Enum.sort([na, nb]) end)
      space = call(a, :boids, :space, [world])
      home = fn i -> call(a, :boids_space, :home, [space, {i * @tile + 80, 80}]) end
      i = Enum.find(0..400, fn i -> home.(i) != home.(i + 1) end)
      peer = fn node -> if node == na, do: a, else: b end

      %{
        world: world,
        border: (i + 1) * @tile,
        left: peer.(home.(i)),
        right: peer.(home.(i + 1)),
        left_node: home.(i),
        right_node: home.(i + 1)
      }
    end

    defp owner(peer, world, id),
      do: call(peer, :boids_space, :owner, [call(peer, :boids, :space, [world]), id])

    # The kind of the row of a boid on a node, and the node of its process.
    defp kind(peer, world, id) do
      case owner(peer, world, id) do
        {kind, pid} -> {kind, node(pid)}
        :error -> :error
      end
    end

    test "the worlds with one name and the same options are one world", %{nodes: nodes} do
      %{world: world, left: left, right: right, left_node: ln, right_node: rn} = world(nodes)
      assert call(left, :boids, :nodes, [world]) == Enum.sort([ln, rn])
      assert call(right, :boids, :nodes, [world]) == Enum.sort([ln, rn])
      # A world that stops goes from the world of the other node.
      :ok = call(right, :boids, :stop_world, [world])
      assert eventually(fn -> call(left, :boids, :nodes, [world]) == [ln] end)
    end

    test "worlds with other options, or with no name that is an atom, are not one world", %{nodes: nodes} do
      [{a, na}, {b, nb}] = nodes
      world = name()
      {:ok, _} = call(a, :boids, :start_world, [%{name: world}])
      {:ok, _} = call(b, :boids, :start_world, [%{name: world, tile: 80}])
      {:ok, alone} = call(a, :boids, :start_world, [%{}])
      {:ok, global} = call(b, :boids, :start_world, [%{name: {:global, world}}])
      Process.sleep(300)
      assert call(a, :boids, :nodes, [world]) == [na]
      assert call(b, :boids, :nodes, [world]) == [nb]
      assert call(a, :boids, :nodes, [alone]) == [na]
      assert call(b, :boids, :nodes, [global]) == [nb]
    end

    test "a boid near a border shows itself to the other node", %{nodes: nodes} do
      %{world: world, border: border, left: left, right: right, left_node: ln} = world(nodes)
      {:ok, id} = call(left, :boids, :add, [world, still(pos: {border - 5, 80}, group: :birds, data: :blue)])
      {:ok, far} = call(left, :boids, :add, [world, still(pos: {border - 60, 80})])

      assert eventually(fn -> kind(right, world, id) == {{:ghost, :server}, ln} end)
      assert {:ok, %{pos: {x, _}, group: :birds, data: :blue}} = call(right, :boids, :lookup, [world, id])
      assert x == border - 5
      assert [%{id: ^id}] = call(right, :boids, :near, [world, {border, 80}, 8])
      # It is a boid of the left node: the right node does not count it.
      assert call(right, :boids, :count, [world]) == 0
      assert call(right, :boids, :snapshot, [world]) == []
      assert call(left, :boids, :count, [world]) == 2
      # A boid that is not near the border does not show itself.
      assert kind(right, world, far) == :error

      # A boid of the right node sees it as a neighbor.
      args = %{boid: %{id: :hawk, pos: {border + 3, 80}, perception: 20, tick: 20, max_speed: 0}}
      {:ok, _} = call(right, :gen_boid, :start, [world, Hawk, args])

      assert eventually(fn ->
               {:ok, %{state: %{seen: seen}}} = call(right, :boids, :boid, [world, :hawk])
               Enum.any?(seen, fn {seen_id, _pos} -> seen_id == id end)
             end)

      # The hawk is near the border too: the left node sees it.
      assert eventually(fn -> match?({{:ghost, :server}, _}, kind(left, world, :hawk)) end)

      # Away from the border, the boid does not show itself: its row goes from the right node.
      :ok = call(left, :boids, :update, [world, id, %{pos: {border - 70, 80}}])
      assert eventually(fn -> kind(right, world, id) == :error end)
    end

    test "the row of a boid that sends no update goes after half a second", %{nodes: nodes} do
      %{world: world, border: border, left: left, right: right} = world(nodes)
      {:ok, id} = call(left, :boids, :add, [world, %{pos: {border - 5, 80}, rules: [], tick: :manual}])
      Process.sleep(300)
      # A boid with a manual tick shows itself only at a step.
      assert kind(right, world, id) == :error
      :ok = call(left, :boids, :step, [world, 0.05])
      assert eventually(fn -> match?({{:ghost, :server}, _}, kind(right, world, id)) end)
      Process.sleep(1000)
      assert kind(right, world, id) == :error
    end

    test "a boid that crosses the border moves to the other node, with all its state", %{nodes: nodes} do
      %{world: world, border: border, left: left, right: right, left_node: ln, right_node: rn} = world(nodes)
      {:ok, :mate} = call(left, :boids, :add, [world, still(id: :mate, pos: {border - 30, 80})])
      {:ok, :fan} = call(left, :boids, :add, [world, still(id: :fan, pos: {border - 6, 80})])

      options =
        mover(
          id: :traveler,
          pos: {border - 20, 80},
          data: :blue,
          search: 2,
          state: %{steps: 0, stop_at: border + 3, note: "mine"}
        )

      {:ok, first} = call(left, :gen_boid, :start, [world, Traveler, options])
      assert node(first) == ln
      :ok = call(left, :boids, :relate, [world, :traveler, :follows, :mate])
      assert call(left, :boids, :related, [world, :traveler, :follows]) == [:mate]

      # The process of the boid is on the right node now.
      assert eventually(fn -> kind(right, world, :traveler) == {:server, rn} end)
      assert call(right, :boids, :count, [world]) == 1
      # The first process stopped, with the reason and its state.
      assert eventually(fn -> not call(left, :erlang, :is_process_alive, [first]) end)

      assert {{:shutdown, {:moved, ^rn}}, %{note: "mine"}} =
               call(left, :persistent_term, :get, [{Traveler, :traveler}])

      # The boid has its state, its data, its rules and the options of its process.
      assert eventually(fn -> elem(call(right, :boids, :boid, [world, :traveler]), 1).max_speed == 0 end)
      {:ok, boid} = call(right, :boids, :boid, [world, :traveler])
      assert %{id: :traveler, data: :blue, rules: [], state: %{note: "mine", stop_at: _, steps: steps}} = boid
      assert steps > 5
      {x, 80.0} = boid.pos
      assert x >= border + 3 and x < border + 10
      {:server, second} = owner(right, world, :traveler)
      assert %{tick: 20, search: 2, mod: Traveler} = call(right, :sys, :get_state, [second])
      # It continues to make steps.
      assert eventually(fn -> elem(call(right, :boids, :boid, [world, :traveler]), 1).state.steps > steps end)

      # Its relation went with it.
      assert call(right, :boids, :related, [world, :traveler, :follows]) == [:mate]
      assert call(left, :boids, :related, [world, :traveler, :follows]) == []
      assert :graph.edges(call(right, :boids, :relations, [world])) == [{:traveler, :mate, :follows}]
      assert :graph.edges(call(left, :boids, :relations, [world])) == []

      # The left node sees it near the border, and finds its process.
      assert eventually(fn -> kind(left, world, :traveler) == {{:ghost, :server}, rn} end)
      assert call(left, :boids, :whereis, [world, :traveler]) == second
      assert call(left, :boids, :count, [world]) == 2

      # A boid of the left node has a relation to it, and moves to it while it sees it.
      :ok = call(left, :boids, :relate, [world, :fan, :likes, :traveler])

      :ok =
        call(left, :boids, :update, [
          world,
          :fan,
          %{max_speed: 3, rules: [{:seek, 1.0, %{target: {:related, :likes}}}]}
        ])

      assert eventually(fn ->
               {:ok, %{vel: {vx, _}}} = call(left, :boids, :boid, [world, :fan])
               vx > 0.5
             end)

      # The boid goes back: it moves to the left node again.
      back = %{
        vel: {-40, 0},
        min_speed: 40,
        max_speed: 40,
        state: %{steps: 0, stop_at: border + 1000, note: "back"}
      }

      :ok = call(left, :boids, :update, [world, :traveler, back])
      assert eventually(fn -> kind(left, world, :traveler) == {:server, ln} end)
      assert eventually(fn -> not call(right, :erlang, :is_process_alive, [second]) end)
      assert {:ok, %{state: %{note: "back"}}} = call(right, :boids, :boid, [world, :traveler])
      assert call(left, :boids, :related, [world, :traveler, :follows]) == [:mate]
      :ok = call(left, :boids, :remove, [world, :traveler])
    end

    test "a boid with no module of yours moves too", %{nodes: nodes} do
      %{world: world, border: border, left: left, right: right, right_node: rn} = world(nodes)
      {:ok, id} = call(left, :boids, :add, [world, mover(pos: {border - 10, 80}, group: :birds)])
      assert is_reference(id)
      assert eventually(fn -> kind(right, world, id) == {:server, rn} end)
      {:server, pid} = owner(right, world, id)
      assert %{mod: :undefined, tick: 20} = call(right, :sys, :get_state, [pid])
      assert {:ok, %{group: :birds}} = call(right, :boids, :lookup, [world, id])
      # The row of the left node is the row of a boid of another node now, or it is gone.
      assert eventually(fn -> kind(left, world, id) in [{{:ghost, :server}, rn}, :error] end)
      assert call(left, :boids, :count, [world]) == 0
    end

    test "a boid that comes to a node takes the place of a boid with the same id and fewer moves", %{
      nodes: nodes
    } do
      %{world: world, border: border, left: left, right: right, right_node: rn} = world(nodes)

      {:ok, :twin} =
        call(right, :boids, :add, [world, still(id: :twin, pos: {border + 100, 80}, data: :right)])

      {:server, resident} = owner(right, world, :twin)
      {:ok, :twin} = call(left, :boids, :add, [world, mover(id: :twin, pos: {border - 10, 80}, data: :left)])
      # The ids of a world are for one boid each. Two boids with one id
      # become one boid: the boid that made a move.
      assert eventually(fn -> not call(right, :erlang, :is_process_alive, [resident]) end)
      assert eventually(fn -> call(left, :boids, :count, [world]) == 0 end)
      assert kind(right, world, :twin) == {:server, rn}
      assert {:ok, %{data: :left}} = call(right, :boids, :lookup, [world, :twin])
      assert call(right, :boids, :count, [world]) == 1
    end

    test "a boid stops when the other node has a boid with its id that is not older", %{nodes: nodes} do
      %{world: world, border: border, left: left, right: right, right_node: rn} = world(nodes)
      # The first boid moves to the right node, and stops there, away from the border.
      first = mover(id: :twin, pos: {border - 10, 80}, data: :first, state: %{steps: 0, stop_at: border + 40})
      {:ok, _} = call(left, :gen_boid, :start, [world, Traveler, first])
      assert eventually(fn -> kind(right, world, :twin) == {:server, rn} end)
      assert eventually(fn -> elem(call(right, :boids, :boid, [world, :twin]), 1).max_speed == 0 end)
      assert eventually(fn -> kind(left, world, :twin) == :error end)

      # A second boid with the id comes to the border: it made no move,
      # so the boid of the right node stays, and the second boid stops.
      {:ok, :twin} =
        call(left, :boids, :add, [world, mover(id: :twin, pos: {border - 10, 80}, data: :second)])

      {:server, second} = owner(left, world, :twin)
      assert eventually(fn -> not call(left, :erlang, :is_process_alive, [second]) end)
      assert eventually(fn -> call(left, :boids, :count, [world]) == 0 end)
      assert {:ok, %{data: :first}} = call(right, :boids, :lookup, [world, :twin])
      assert call(right, :boids, :count, [world]) == 1
    end

    test "a boid that the other node refuses stays on its node", %{nodes: nodes} do
      %{world: world, border: border, left: left, right: right, left_node: ln} = world(nodes)
      # The right node has boids in three dimensions, so it refuses a boid in two dimensions.
      {:ok, _} = call(right, :boids, :add, [world, still(pos: {border + 100, 80, 0})])
      {:ok, id} = call(left, :boids, :add, [world, mover(pos: {border - 10, 80})])

      assert eventually(fn ->
               {:ok, %{pos: {x, _}}} = call(left, :boids, :lookup, [world, id])
               x > border + 20
             end)

      assert kind(left, world, id) == {:server, ln}
      assert kind(right, world, id) == :error
    end

    test "the functions with an id find a boid on another node", %{nodes: nodes} do
      %{world: world, border: border, left: left, right: right, right_node: rn} = world(nodes)
      {:ok, id} = call(right, :boids, :add, [world, still(pos: {border + 80, 80})])
      {:ok, :here} = call(left, :boids, :add, [world, still(id: :here, pos: {border - 80, 80})])
      # The left node has no row of the boid.
      assert kind(left, world, id) == :error
      pid = call(left, :boids, :whereis, [world, id])
      assert node(pid) == rn
      assert {:ok, %{id: ^id, max_speed: 0}} = call(left, :boids, :boid, [world, id])
      assert call(left, :boids, :update, [world, id, %{data: :red}]) == :ok
      assert {:ok, %{data: :red}} = call(right, :boids, :lookup, [world, id])
      assert call(left, :boids, :add_rule, [world, id, {:wander, 1.0}]) == :ok
      assert call(left, :boids, :which_rules, [world, id]) == {:ok, [:wander]}
      assert call(left, :boids, :delete_rule, [world, id, :wander]) == :ok

      # A relation is on the node of the boid that has it.
      assert call(left, :boids, :relate, [world, :here, :likes, id]) == :ok
      assert call(left, :boids, :related, [world, :here, :likes]) == [id]
      assert call(left, :boids, :relate, [world, id, :follows, :here]) == :ok
      assert call(right, :boids, :related, [world, id, :follows]) == [:here]
      assert call(left, :boids, :related, [world, id, :follows]) == []
      assert call(left, :boids, :unrelate, [world, id, :follows, :here]) == :ok
      assert call(right, :boids, :related, [world, id, :follows]) == []
      assert call(left, :boids, :unrelate, [world, :here, :likes, id]) == :ok
      assert call(left, :boids, :related, [world, :here, :likes]) == []
      assert call(left, :boids, :relate, [world, :here, :likes, id]) == :ok

      # An id that is on no node.
      assert call(left, :boids, :whereis, [world, :nobody]) == :undefined
      assert call(left, :boids, :boid, [world, :nobody]) == {:error, :not_found}
      assert call(left, :boids, :update, [world, :nobody, %{data: 1}]) == {:error, :not_found}
      assert call(left, :boids, :remove, [world, :nobody]) == {:error, :not_found}
      assert call(left, :boids, :relate, [world, :nobody, :likes, id]) == {:error, {:not_found, :nobody}}
      assert call(left, :boids, :relate, [world, :here, :likes, :nobody]) == {:error, {:not_found, :nobody}}

      # The node of a boid removes it.
      assert call(left, :boids, :remove, [world, id]) == :ok
      assert eventually(fn -> call(right, :boids, :count, [world]) == 0 end)
      assert call(left, :boids, :whereis, [world, id]) == :undefined
    end

    test "a process of yours near a border shows itself, and does not move", %{nodes: nodes} do
      %{world: world, border: border, left: left, right: right, left_node: ln} = world(nodes)
      {:ok, person} = call(left, GenServer, :start, [Person, {world, %{id: :person, pos: {border - 80, 80}}}])
      assert kind(right, world, :person) == :error
      :ok = call(left, GenServer, :call, [person, {:go, {border - 4, 80}}])
      assert eventually(fn -> kind(right, world, :person) == {{:ghost, :process}, ln} end)
      # In a tile of the right node, it is still a process of the left node.
      :ok = call(left, GenServer, :call, [person, {:go, {border + 4, 80}}])

      assert eventually(fn ->
               match?({:ok, %{pos: {x, _}}} when x > border, call(right, :boids, :lookup, [world, :person]))
             end)

      assert kind(left, world, :person) == {:process, ln}
      assert kind(right, world, :person) == {{:ghost, :process}, ln}
      # The functions for a gen_boid do not find it.
      assert call(right, :boids, :update, [world, :person, %{data: 1}]) == {:error, :not_found}
      assert call(right, :boids, :remove, [world, :person]) == {:error, :not_found}
      assert call(right, :boids, :whereis, [world, :person]) == person
      call(left, GenServer, :stop, [person])
    end
  end

  describe "the nodes of a world change" do
    test "a new node takes its tiles, and a node that stops goes from the world" do
      [{a, na}, {b, nb}] = nodes = Cluster.start(2)
      on_exit(fn -> Cluster.stop(nodes) end)
      world = name()
      options = %{name: world, defaults: %{rules: [], tick: 20, max_speed: 0}}
      for {peer, _} <- nodes, do: {:ok, _} = call(peer, :boids, :start_world, [options])
      assert eventually(fn -> call(a, :boids, :nodes, [world]) == Enum.sort([na, nb]) end)
      assert eventually(fn -> call(b, :boids, :nodes, [world]) == Enum.sort([na, nb]) end)

      # One boid in the middle of each of 40 tiles, on the node of its tile.
      space = call(a, :boids, :space, [world])

      for i <- 0..39 do
        pos = {i * @tile + 80, 80}
        peer = if call(a, :boids_space, :home, [space, pos]) == na, do: a, else: b
        {:ok, ^i} = call(peer, :boids, :add, [world, %{id: i, pos: pos}])
      end

      count = fn peer -> call(peer, :boids, :count, [world]) end
      assert count.(a) + count.(b) == 40

      # A third node comes: the boids of its tiles move to it.
      {c, nc} = third = Cluster.add(nodes)
      on_exit(fn -> Cluster.stop([third]) end)
      {:ok, _} = call(c, :boids, :start_world, [options])
      assert eventually(fn -> call(a, :boids, :nodes, [world]) == Enum.sort([na, nb, nc]) end)
      # In the end, each boid is on the node of its tile.
      settled = fn ->
        rows =
          for {peer, node} <- [{a, na}, {b, nb}, {c, nc}],
              row <- call(peer, :boids, :snapshot, [world]),
              do: {node, row}

        length(rows) == 40 and
          Enum.all?(rows, fn {node, %{pos: pos, pid: pid}} ->
            node(pid) == node and
              call(a, :boids_space, :home, [call(a, :boids, :space, [world]), pos]) == node
          end)
      end

      assert eventually(settled, 500)
      assert count.(c) > 0

      # A boid of the third node near a border shows itself. Then its node stops.
      on_c = call(c, :boids, :snapshot, [world])
      space_c = call(c, :boids, :space, [world])
      home = fn i -> call(c, :boids_space, :home, [space_c, {i * @tile + 80, 80}]) end
      i = Enum.find(100..500, fn i -> home.(i) == nc and home.(i + 1) != nc end)
      other = if home.(i + 1) == na, do: a, else: b
      {:ok, :edge} = call(c, :boids, :add, [world, %{id: :edge, pos: {(i + 1) * @tile - 3, 80}}])
      assert eventually(fn -> call(other, :boids, :lookup, [world, :edge]) != :error end)
      # The other node cannot remove a boid of a node that does not answer.
      space_o = call(other, :boids, :space, [world])
      :ok = call(other, :sys, :suspend, [world])
      Cluster.stop([third])
      assert call(other, :boids, :remove, [space_o, :edge]) == {:error, :not_found}
      :ok = call(other, :sys, :resume, [world])
      # The row of the boid of the node that stopped goes.
      assert eventually(fn -> call(other, :boids, :lookup, [world, :edge]) == :error end)

      assert eventually(fn -> call(a, :boids, :nodes, [world]) == Enum.sort([na, nb]) end)
      assert eventually(fn -> call(b, :boids, :nodes, [world]) == Enum.sort([na, nb]) end)
      # The boids of the node that stopped are gone with it.
      assert count.(a) + count.(b) == 40 - length(on_c)
    end
  end
end
