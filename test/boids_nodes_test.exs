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

    test "of two processes of one boid on two nodes, one stops" do
      world = name()
      {:ok, pid} = :boids.start_world(name: world, defaults: %{tick: :manual, rules: []})
      on_exit(fn -> :boids.stop_world(pid) end)
      space = :boids.space(world)
      # The name of this node is between these two names.
      small = :"a@127.0.0.1"
      large = :"z@127.0.0.1"
      assert small < node() and node() < large
      :ok = :boids_space.set_nodes(space, [node(), large])
      mine = Enum.find(0..400, &(:boids_space.home(space, {&1 * @tile + 80, 80}) == node())) * @tile + 80
      theirs = Enum.find(0..400, &(:boids_space.home(space, {&1 * @tile + 80, 80}) == large)) * @tile + 80
      process = %{tick: :manual, max_dt: 0.25, search: 1, priority: :low, hibernate: true}

      # A boid of this node with a number of moves, at an x.
      boid = fn id, moves, x ->
        new = :boids_boid.new(%{id: id, pos: {x, 80}, rules: []})

        {:ok, pid} =
          :gen_boid.adopt(world, %{boid: new, mod: :undefined, server: process, relations: [], moves: moves})

        pid
      end

      # The world handled each message before this call.
      stays = fn pid -> :boids.count(world) >= 0 and Process.alive?(pid) end
      stops = fn pid -> :boids.count(world) >= 0 and eventually(fn -> not Process.alive?(pid) end) end

      # The world of the node with the smaller name decides. This node
      # has the smaller name than the node large: its process stops when
      # the other process made more moves.
      one = boid.(:one, 2, mine)
      {:ok, _} = :boids.add(world, id: :mate, pos: {mine, 80})
      :ok = :boids.relate(world, :one, :likes, :mate)
      :ok = :boids.relate(world, :mate, :likes, :one)
      send(world, {:claim, :one, large, 1})
      assert stays.(one)
      send(world, {:census, large, [{:nobody, 9}, {:one, 3}]})
      assert stops.(one)
      assert :boids.lookup(world, :one) == :error
      # The relations of the boid went with it. A relation to it stays.
      assert :boids.related(world, :one, :likes) == []
      assert :boids.related(world, :mate, :likes) == [:one]

      # With the same number of moves, the process of the node with the
      # larger name stays. The tile of a process has no effect: a
      # decision for the same two processes is always the same decision
      # (specs/MoveMany.tla).
      home = boid.(:home, 1, mine)
      send(world, {:claim, :home, large, 1})
      assert stops.(home)
      away = boid.(:away, 1, theirs)
      send(world, {:claim, :away, large, 1})
      assert stops.(away)

      # A node that started a process for the boid tells the other
      # nodes, with the process that called. The world of that process
      # does nothing: the process stops with the answer of its call.
      calls = boid.(:calls, 1, mine)
      send(world, {:claim, :calls, large, 2, calls})
      assert stays.(calls)
      # For the call of another process, the world decides.
      send(world, {:claim, :calls, large, 2, self()})
      assert stops.(calls)

      # A row that shows a boid of this node from another node is such a message.
      shown = boid.(:shown, 0, mine)
      remote = :erlang.list_to_pid(~c"<0.0.0>")
      entry = %{id: :shown, pos: {theirs, 80}, vel: {0, 0}, pid: remote, kind: :process}
      send(world, {:show, entry})
      assert stays.(shown)
      send(world, {:show, Map.merge(entry, %{kind: :server, moves: 0})})
      # The process that shows itself is of this node here, so nothing changes.
      assert stays.(shown)

      # The world of the node small decides for this node: this node
      # tells it its boid, and waits.
      :ok = :boids_space.set_nodes(space, [node(), small])
      waits = boid.(:waits, 0, mine)
      send(world, {:claim, :waits, small, 5})
      assert stays.(waits)
      # The decision stops only the process with the number of moves that the other world saw.
      send(world, {:yield, :waits, 3})
      send(world, {:yield, :nobody, 0})
      assert stays.(waits)
      send(world, {:yield, :waits, 0})
      assert stops.(waits)

      # A process of yours is not a boid that moves: it stays.
      {:ok, _space, _boid} = :boids.join(world, id: :person, pos: {mine, 80})
      send(world, {:claim, :person, large, 9})
      send(world, {:yield, :person, 0})
      assert :boids.count(world) >= 0
      assert :boids_space.owner(space, :person) == {:process, self()}

      # A boid below a supervisor of yours does not move from node to
      # node. It has no part in a decision: another boid with its id is
      # a fault of the ids, and the boid of the supervisor stays.
      {:ok, resident} = :gen_boid.start_link(world, Mouse, %{id: :resident, pos: {mine, 80}})
      send(world, {:claim, :resident, large, 9})
      send(world, {:yield, :resident, 0})

      send(
        world,
        {:show, %{id: :resident, pos: {theirs, 80}, vel: {0, 0}, pid: remote, kind: :server, moves: 4}}
      )

      send(world, {:census, large, [{:resident, 7}]})
      assert stays.(resident)
      # A boid with its id that comes from another node does not take its place.
      new = :boids_boid.new(%{id: :resident, pos: {mine, 80}, rules: []})
      coming = %{boid: new, mod: :undefined, server: process, relations: [], moves: 5}
      assert :gen_boid.adopt(world, coming) == {:error, {:exists, :resident}}
      assert stays.(resident)
      # Its row tells the other nodes no number of moves.
      {:ok, shown_boid} = :boids.boid(world, :resident)
      assert :boids_world.settle(space, shown_boid, :none) == :home
      :gen_boid.stop(resident)
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
      assert call(right, :boids, :count, [world, :local]) == 0
      assert call(right, :boids, :snapshot, [world, :local]) == []
      assert call(left, :boids, :count, [world, :local]) == 2
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
      assert call(right, :boids, :count, [world, :local]) == 1
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
      assert call(left, :boids, :count, [world, :local]) == 2

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
      assert call(left, :boids, :count, [world, :local]) == 0
    end

    test "two boids with one id on two nodes become one boid", %{nodes: nodes} do
      %{world: world, border: border, left: left, right: right} = world(nodes)

      {:ok, :twin} =
        call(right, :boids, :add, [world, still(id: :twin, pos: {border + 100, 80}, data: :right)])

      {:server, resident} = owner(right, world, :twin)
      {:ok, :twin} = call(left, :boids, :add, [world, mover(id: :twin, pos: {border - 10, 80}, data: :left)])
      {:server, comer} = owner(left, world, :twin)
      # The ids of a world are for one boid each. The boid of the left node
      # shows itself to the right node, which has a boid with that id:
      # one of the two processes stops, and the other stays.
      assert eventually(fn ->
               [
                 call(right, :erlang, :is_process_alive, [resident]),
                 call(left, :erlang, :is_process_alive, [comer])
               ]
               |> Enum.count(& &1) == 1
             end)

      assert eventually(fn ->
               call(left, :boids, :count, [world, :local]) + call(right, :boids, :count, [world, :local]) == 1
             end)

      assert call(left, :boids, :count, [world]) == 1
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
      assert eventually(fn -> call(left, :boids, :count, [world, :local]) == 0 end)
      assert {:ok, %{data: :first}} = call(right, :boids, :lookup, [world, :twin])
      assert call(right, :boids, :count, [world, :local]) == 1
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
      assert eventually(fn -> call(right, :boids, :count, [world, :local]) == 0 end)
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

  describe "a world on two nodes, for a person who uses it" do
    test "worlds with one name and other options write one error to the log of each node", %{nodes: nodes} do
      [{a, na}, {b, nb}] = nodes
      world = name()
      {:ok, _} = call(a, :boids, :start_world, [%{name: world}])
      {:ok, _} = call(b, :boids, :start_world, [%{name: world, tile: 80}])

      about = fn peer, other ->
        Enum.filter(Cluster.errors(peer), &(&1 =~ "#{world}" and &1 =~ "#{other}" and &1 =~ "other options"))
      end

      assert eventually(fn -> length(about.(a, nb)) == 1 and length(about.(b, na)) == 1 end)
      # The next check of the options writes no second error.
      for {peer, _} <- nodes, do: call(peer, :erlang, :send, [world, :options])
      assert call(a, :boids, :nodes, [world]) == [na]
      assert call(b, :boids, :nodes, [world]) == [nb]
      assert length(about.(a, nb)) == 1 and length(about.(b, na)) == 1
    end

    test "worlds with one name and the same options write no error", %{nodes: nodes} do
      %{world: world} = world(nodes)
      Process.sleep(700)
      for {peer, _} <- nodes, do: assert(Enum.filter(Cluster.errors(peer), &(&1 =~ "#{world}")) == [])
    end

    test "a boid below a supervisor of yours stays on its node, and shows itself", %{nodes: nodes} do
      %{world: world, border: border, left: left, right: right, left_node: ln} = world(nodes)
      args = mover(id: :pet, pos: {border - 10, 80}, state: %{steps: 0, stop_at: border + 30})
      {:ok, pet} = call(left, :gen_boid, :start_link, [world, Traveler, args])

      # In a tile of the right node, it is still a process of the left node.
      assert eventually(fn ->
               match?(
                 {:ok, %{pos: {x, _}}} when x >= border + 30,
                 call(right, :boids, :lookup, [world, :pet])
               )
             end)

      Process.sleep(200)
      assert kind(left, world, :pet) == {:server, ln}
      assert kind(right, world, :pet) == {{:ghost, :server}, ln}
      assert call(left, :erlang, :is_process_alive, [pet])
      assert call(right, :boids, :count, [world, :local]) == 0
      assert call(right, :boids, :whereis, [world, :pet]) == pet
      :ok = call(left, :gen_boid, :stop, [pet])
    end

    test "the random numbers of a boid with a seed continue after a move", %{nodes: nodes} do
      %{world: world, border: border, left: left, right: right, right_node: rn} =
        world(nodes, %{defaults: %{tick: :manual}})

      # The same boid in a world on one node: there, it does not move to another node.
      alone = name()
      {:ok, _} = call(left, :boids, :start_world, [%{name: alone, defaults: %{tick: :manual}}])

      dice = %{
        id: :dice,
        pos: {border - 12, 80},
        vel: {40, 0},
        min_speed: 40,
        max_speed: 40,
        rules: [wander: 0.3],
        seed: 7
      }

      {:ok, :dice} = call(left, :boids, :add, [world, dice])
      {:ok, :dice} = call(left, :boids, :add, [alone, dice])

      for _ <- 1..30 do
        :ok = call(left, :boids, :step, [world, 0.05])
        :ok = call(left, :boids, :step, [alone, 0.05])
        assert [%{pos: here}] = call(left, :boids, :snapshot, [world])
        assert {:ok, %{pos: ^here}} = call(left, :boids, :lookup, [alone, :dice])
      end

      # The path has random numbers, and the boid made a move.
      assert {:ok, %{pos: {_, y}}} = call(left, :boids, :lookup, [alone, :dice])
      assert y != 80
      assert kind(right, world, :dice) == {:server, rn}
    end

    test "the views of a world are of all its nodes, or of one node", %{nodes: nodes} do
      %{world: world, border: border, left: left, right: right} =
        world(nodes, %{defaults: %{rules: [], tick: :manual, vel: {1, 0}}})

      for {id, x} <- [l1: -30, l2: -18, l3: -6],
          do: {:ok, ^id} = call(left, :boids, :add, [world, %{id: id, pos: {border + x, 80}}])

      for {id, x} <- [r1: 6, r2: 18, far: 100],
          do: {:ok, ^id} = call(right, :boids, :add, [world, %{id: id, pos: {border + x, 80}}])

      ids = fn rows -> rows |> Enum.map(& &1.id) |> Enum.sort() end
      sorted = fn flocks -> flocks |> Enum.map(&Enum.sort/1) |> Enum.sort() end

      for peer <- [left, right] do
        assert call(peer, :boids, :count, [world]) == 6
        assert ids.(call(peer, :boids, :snapshot, [world])) == [:far, :l1, :l2, :l3, :r1, :r2]
        # A flock can be on the two nodes.
        assert sorted.(call(peer, :boids, :flocks, [world, 13])) == [[:far], [:l1, :l2, :l3, :r1, :r2]]
        graph = call(peer, :boids, :graph, [world, 13])
        assert Enum.sort(:graph.vertices(graph)) == [:far, :l1, :l2, :l3, :r1, :r2]
        assert :graph.has_edge(graph, :l3, :r1) and :graph.has_edge(graph, :r1, :l3)
        refute :graph.has_edge(graph, :l1, :l3)
        assert %{id: :r1, pos: {_, 80}} = :graph.vertex(graph, :r1)
      end

      assert call(left, :boids, :count, [world, :local]) == 3
      assert ids.(call(left, :boids, :snapshot, [world, :local])) == [:l1, :l2, :l3]
      assert ids.(call(right, :boids, :snapshot, [world, :local])) == [:far, :r1, :r2]
      assert sorted.(call(left, :boids, :flocks, [world, 13, :local])) == [[:l1, :l2, :l3]]
      assert sorted.(call(right, :boids, :flocks, [world, 13, :local])) == [[:far], [:r1, :r2]]
      assert Enum.sort(:graph.vertices(call(left, :boids, :graph, [world, 13, :local]))) == [:l1, :l2, :l3]

      # A step of the world moves the boids of the two nodes, and a
      # step of one node moves the boids of that node.
      x = fn id ->
        call(left, :boids, :snapshot, [world]) |> Enum.find(&(&1.id == id)) |> Map.fetch!(:pos) |> elem(0)
      end

      before = {x.(:l1), x.(:far)}
      :ok = call(left, :boids, :step, [world, 1.0])
      assert_in_delta x.(:l1), elem(before, 0) + 1, 1.0e-9
      assert_in_delta x.(:far), elem(before, 1) + 1, 1.0e-9
      :ok = call(left, :boids, :step, [world, 1.0, :local])
      assert_in_delta x.(:l1), elem(before, 0) + 2, 1.0e-9
      assert_in_delta x.(:far), elem(before, 1) + 1, 1.0e-9
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

      count = fn peer -> call(peer, :boids, :count, [world, :local]) end
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
              row <- call(peer, :boids, :snapshot, [world, :local]),
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
      on_c = call(c, :boids, :snapshot, [world, :local])
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

    test "a call to a boid of a node that gives no answer gives the result timeout" do
      [{a, na}, {b, nb}] = nodes = Cluster.start(2)
      on_exit(fn -> Cluster.stop(nodes) end)
      world = name()
      options = %{name: world, defaults: %{rules: [], tick: 20, max_speed: 0}}
      for {peer, _} <- nodes, do: {:ok, _} = call(peer, :boids, :start_world, [options])
      assert eventually(fn -> call(a, :boids, :nodes, [world]) == Enum.sort([na, nb]) end)
      assert eventually(fn -> call(b, :boids, :nodes, [world]) == Enum.sort([na, nb]) end)
      space = call(a, :boids, :space, [world])
      home = fn i -> call(a, :boids_space, :home, [space, {i * @tile + 80, 80}]) end
      # A tile of the node a, then a tile of the node b.
      i = Enum.find(0..400, fn i -> home.(i) == na and home.(i + 1) == nb end)
      border = (i + 1) * @tile
      {:ok, :here} = call(a, :boids, :add, [world, %{id: :here, pos: {border - 80, 80}}])
      # The node a has a row for the boid near, and no row for the boid far.
      {:ok, :near} = call(b, :boids, :add, [world, %{id: :near, pos: {border + 3, 80}}])
      {:ok, :far} = call(b, :boids, :add, [world, %{id: :far, pos: {border + 80, 80}}])
      assert eventually(fn -> call(a, :boids, :lookup, [world, :near]) != :error end)
      assert call(a, :boids, :lookup, [world, :far]) == :error

      # The time limit is 5 seconds, or the value of the application.
      assert call(a, :boids, :timeout, []) == 5000
      :ok = call(a, :application, :set_env, [:boids, :timeout, 50])
      assert call(a, :boids, :timeout, []) == 50

      # The node b stops its work, and its connection stays: it gives no answer.
      os_pid = call(b, :os, :getpid, [])
      {_, 0} = System.cmd("kill", ["-STOP", to_string(os_pid)])
      rule = {:wander, 1.0, %{}}

      try do
        # The node a has the row of the boid near for a short time: it
        # sends the call to the process of the boid, or to its node.
        assert is_pid(call(a, :boids, :whereis, [world, :near]))
        assert call(a, :boids, :boid, [world, :near]) == {:error, :timeout}
        assert call(a, :boids, :remove, [world, :near]) == {:error, :timeout}
        assert call(a, :boids, :relate, [world, :near, :leader, :here]) == {:error, :timeout}
        assert call(a, :boids, :unrelate, [world, :near, :leader, :here]) == {:error, :timeout}
        # With no row, the node a asks the other nodes for the boid.
        assert call(a, :boids, :whereis, [world, :far]) == :undefined

        # A boid that can be on the node b, and an id that is in no node that answers.
        for id <- [:near, :far, :nobody] do
          assert call(a, :boids, :boid, [world, id]) == {:error, :timeout}
          assert call(a, :boids, :update, [world, id, %{data: :late}]) == {:error, :timeout}
          assert call(a, :boids, :add_rule, [world, id, rule]) == {:error, :timeout}
          assert call(a, :boids, :delete_rule, [world, id, :wander]) == {:error, :timeout}
          assert call(a, :boids, :which_rules, [world, id]) == {:error, :timeout}
          assert call(a, :boids, :remove, [world, id]) == {:error, :timeout}
          assert call(a, :boids, :relate, [world, id, :leader, :here]) == {:error, :timeout}
          assert call(a, :boids, :unrelate, [world, id, :leader, :here]) == {:error, :timeout}
        end

        assert call(a, :boids, :relate, [world, :here, :leader, :far]) == {:error, :timeout}
        # A boid of the node a has its answers.
        assert {:ok, %{id: :here}} = call(a, :boids, :boid, [world, :here])
      after
        {_, 0} = System.cmd("kill", ["-CONT", to_string(os_pid)])
      end

      # The node b does its work again. It got the call to remove the
      # boid near during its stop, and does that work now: the result
      # timeout does not tell that a call had no effect. No call for the
      # boid far came to the node b.
      assert call(b, :boids, :nodes, [world]) == Enum.sort([na, nb])
      assert eventually(fn -> call(b, :boids, :snapshot, [world, :local]) |> Enum.map(& &1.id) == [:far] end)
      assert {:ok, %{data: :undefined}} = call(b, :boids, :boid, [world, :far])
      assert call(a, :boids, :count, [world]) == 2
    end
  end
end

defmodule BoidsSplitTest do
  # A world on two nodes whose connection ends, and comes again.
  use ExUnit.Case, async: false
  import Boids.Helpers
  import Boids.Cluster, only: [call: 4]

  alias Boids.Cluster
  alias Boids.TestBoids.Traveler

  @moduletag :capture_log
  @tile 160.0

  setup_all do
    nodes = Cluster.start(2, split: true)
    on_exit(fn -> Cluster.stop(nodes) end)
    %{nodes: nodes}
  end

  # A world on the two nodes. `small` is the node with the smaller name:
  # its world decides between two processes of one boid.
  defp world(nodes) do
    world = :"world#{System.unique_integer([:positive])}"
    options = %{name: world, defaults: %{rules: [], tick: 20}}
    for {peer, _} <- nodes, do: {:ok, _} = call(peer, :boids, :start_world, [options])
    [{small, ns}, {large, nl}] = Enum.sort_by(nodes, &elem(&1, 1))
    joined(world, nodes)
    space = call(small, :boids, :space, [world])
    home = fn i -> call(small, :boids_space, :home, [space, {i * @tile + 80, 80}]) end
    # A tile of the node small, then a tile of the node large.
    i = Enum.find(0..400, fn i -> home.(i) == ns and home.(i + 1) == nl end)
    %{world: world, small: small, large: large, ns: ns, nl: nl, border: (i + 1) * @tile}
  end

  defp joined(world, [{a, na}, {b, nb}]) do
    assert eventually(fn -> call(a, :boids, :nodes, [world]) == Enum.sort([na, nb]) end)
    assert eventually(fn -> call(b, :boids, :nodes, [world]) == Enum.sort([na, nb]) end)
  end

  defp split(world, [{a, na}, {b, nb}] = nodes) do
    Cluster.split(hd(nodes), List.last(nodes))
    assert eventually(fn -> call(a, :boids, :nodes, [world]) == [na] end)
    assert eventually(fn -> call(b, :boids, :nodes, [world]) == [nb] end)
  end

  defp heal(world, nodes) do
    Cluster.heal(hd(nodes), List.last(nodes))
    joined(world, nodes)
  end

  defp node_of(peer, world, id) do
    case call(peer, :boids_space, :owner, [call(peer, :boids, :space, [world]), id]) do
      {:server, pid} -> node(pid)
      other -> other
    end
  end

  test "during a split each node has all the tiles, and after the heal a boid moves to the node of its tile",
       %{
         nodes: nodes
       } do
    %{world: world, small: small, large: large, ns: ns, nl: nl, border: border} = world(nodes)
    split(world, nodes)

    args = %{
      id: :lone,
      pos: {border - 20, 80},
      vel: {40, 0},
      min_speed: 40,
      max_speed: 40,
      state: %{steps: 0, stop_at: border + 60}
    }

    {:ok, _} = call(small, :gen_boid, :start, [world, Traveler, args])
    # The boid goes across the place of the border, and stays on its node.
    assert eventually(fn -> elem(call(small, :boids, :boid, [world, :lone]), 1).max_speed == 0 end)
    assert node_of(small, world, :lone) == ns
    assert node_of(large, world, :lone) == :error
    assert call(small, :boids, :count, [world]) == 1
    assert call(large, :boids, :count, [world]) == 0

    heal(world, nodes)
    assert eventually(fn -> node_of(large, world, :lone) == nl end)
    assert eventually(fn -> node_of(small, world, :lone) == :error end)
    assert call(small, :boids, :count, [world]) == 1
  end

  test "a step of the world, with a node that has no connection, is a step of the other nodes", %{
    nodes: nodes
  } do
    %{world: world, small: small, large: large, ns: ns, nl: nl, border: border} = world(nodes)
    boid = fn id, x -> %{id: id, pos: {x, 80}, vel: {1, 0}, min_speed: 1, max_speed: 1, tick: :manual} end
    {:ok, :here} = call(small, :boids, :add, [world, boid.(:here, border - 80)])
    {:ok, :there} = call(large, :boids, :add, [world, boid.(:there, border + 80)])
    space = call(small, :boids, :space, [world])
    x = fn peer, id -> call(peer, :boids, :lookup, [world, id]) |> elem(1) |> Map.fetch!(:pos) |> elem(0) end

    # The connection ends. For a short time, the list of the nodes of
    # the node small has the two nodes: its world did not get the news.
    split(world, nodes)
    :ok = call(small, :boids_space, :set_nodes, [space, [ns, nl]])
    assert call(small, :boids, :nodes, [world]) == [ns, nl]

    # The step does not wait for the node large, and gives no error.
    assert call(small, :boids, :step, [world, 1.0]) == :ok
    assert_in_delta x.(small, :here), border - 79, 1.0e-9
    assert_in_delta x.(large, :there), border + 80, 1.0e-9
    # The same with the list of one node.
    :ok = call(small, :boids_space, :set_nodes, [space, [ns]])
    assert call(small, :boids, :step, [world, 1.0]) == :ok
    assert_in_delta x.(small, :here), border - 78, 1.0e-9

    heal(world, nodes)
    assert call(small, :boids, :step, [world, 1.0]) == :ok
    assert_in_delta x.(small, :here), border - 77, 1.0e-9
    assert_in_delta x.(large, :there), border + 81, 1.0e-9
  end

  test "after a heal, a boid with a process on each node has one process", %{nodes: nodes} do
    %{world: world, small: small, large: large, ns: ns, nl: nl, border: border} = world(nodes)
    split(world, nodes)
    process = %{tick: :manual, max_dt: 0.25, search: 1, priority: :low, hibernate: true}
    # A position in a tile of each node.
    at = %{ns => border - 80, nl => border + 80}

    # A process of the boid on a node, with a number of moves, in a tile of a node.
    copy = fn peer, id, moves, tile ->
      boid = :boids_boid.new(%{id: id, pos: {at[tile], 80}, rules: [], data: moves})
      moving = %{boid: boid, mod: :undefined, server: process, relations: [], moves: moves, rand: :undefined}
      {:ok, pid} = call(peer, :gen_boid, :adopt, [world, moving])
      pid
    end

    # During the split, each node gets a process for each of these boids.
    cases = [
      # {id, moves and tile on the node small, moves and tile on the node large, the node that keeps the boid}
      {:more_small, {2, ns}, {1, nl}, ns},
      {:more_large, {1, ns}, {2, nl}, nl},
      # With the same number of moves, the process of the node with the
      # larger name stays, in each tile.
      {:tie, {1, ns}, {1, nl}, nl},
      {:home_small, {1, ns}, {1, ns}, nl},
      {:home_large, {1, nl}, {1, nl}, nl},
      {:away, {1, nl}, {1, ns}, nl}
    ]

    pids =
      for {id, {moves_s, tile_s}, {moves_l, tile_l}, _stays} <- cases, into: %{} do
        {id, %{ns => copy.(small, id, moves_s, tile_s), nl => copy.(large, id, moves_l, tile_l)}}
      end

    # A boid with one process stays as it is.
    only = copy.(small, :only, 0, ns)
    assert call(small, :boids, :count, [world]) == 7
    assert call(large, :boids, :count, [world]) == 6

    heal(world, nodes)
    assert eventually(fn -> call(small, :boids, :count, [world]) == 7 end)

    for {id, _small, _large, stays} <- cases do
      {keeper, other} = if stays == ns, do: {small, large}, else: {large, small}
      goes = if stays == ns, do: nl, else: ns
      assert node_of(keeper, world, id) == stays, "the boid #{id} is not on the node #{stays}"
      assert node_of(other, world, id) == :error
      assert call(keeper, :erlang, :is_process_alive, [pids[id][stays]])
      refute call(other, :erlang, :is_process_alive, [pids[id][goes]])
    end

    assert call(small, :erlang, :is_process_alive, [only])
    assert call(large, :boids, :count, [world]) == 7
    assert call(large, :boids, :count, [world, :local]) + call(small, :boids, :count, [world, :local]) == 7
  end

  describe "the facts of a world on two nodes (specs/Facts.tla)" do
    defp facts(peer, world), do: call(peer, :boids_world, :facts, [world])

    defp scale(peer, world),
      do: call(peer, :boids_space, :env, [call(peer, :boids, :space, [world])]).time_scale

    # The obstacles of a node: id => position. With the space of the
    # world, the read sends no message to the world.
    defp rocks(peer, world), do: Map.new(call(peer, :boids, :obstacles, [world]), &{&1.id, &1.pos})

    # In the end, the nodes have the same facts, with the same versions.
    defp same(world, peers) do
      assert eventually(fn -> peers |> Enum.map(&facts(&1, world)) |> Enum.uniq() |> length() == 1 end)
      facts(hd(peers), world)
    end

    test "the other node sees the obstacle and the scale of the time", %{nodes: nodes} do
      %{world: world, small: a, large: b, ns: na, border: border} = world(nodes)
      # A boid in a tile of the node b, which moves on its clock.
      bird = %{id: :bird, pos: {border + 80, 80}, vel: {1, 0}, min_speed: 1, max_speed: 1, tick: 5}
      {:ok, :bird} = call(b, :boids, :add, [world, bird])

      # When the call returns, the other node has the change: no wait.
      assert call(a, :boids, :set_obstacle, [world, :rock, {10.0, 10.0}, 3.0]) == :ok
      assert [%{id: :rock, pos: {10.0, 10.0}, radius: 3.0}] = call(b, :boids, :obstacles, [world])
      assert call(a, :boids, :set_time_scale, [world, 0.0]) == :ok
      assert scale(b, world) == 0.0

      # Each fact has the version of its change: a counter, and the node of the change.
      assert [{:time_scale, stopped, {second, ^na}}, {{:obstacle, :rock}, rock, {first, ^na}}] =
               facts(b, world)

      assert {stopped, rock} == {0.0, {{10.0, 10.0}, 3.0}}

      assert first < second
      assert facts(a, world) == facts(b, world)

      # The scale 0 stops all the world: the boid of the node b does not move.
      {:ok, %{pos: pos}} = call(b, :boids, :lookup, [world, :bird])
      Process.sleep(50)
      assert {:ok, %{pos: ^pos}} = call(b, :boids, :lookup, [world, :bird])

      # A change of the node b is on the node a too.
      assert call(b, :boids, :remove_obstacle, [world, :rock]) == :ok
      assert call(a, :boids, :obstacles, [world]) == []
      assert call(b, :boids, :set_time_scale, [call(b, :boids, :space, [world]), 2]) == :ok
      assert scale(a, world) == 2
      # The boid moves again.
      assert eventually(fn -> elem(call(b, :boids, :lookup, [world, :bird]), 1).pos != pos end)
      # A bad value is an error on its node, and no change on each node.
      assert catch_error(call(a, :boids, :set_time_scale, [world, -1])) == :badarg
      assert scale(b, world) == 2
      assert facts(a, world) == facts(b, world)
    end

    test "after a split, the last change in time wins on all the nodes, also when the other side made more changes",
         %{nodes: nodes} do
      %{world: world, small: small, large: large, nl: nl} = world(nodes)
      peers = [small, large]
      for id <- [:old, :back, :moved], do: :ok = call(small, :boids, :set_obstacle, [world, id, {1, 1}, 1])
      assert length(same(world, peers)) == 3

      split(world, nodes)
      # Each side makes an obstacle. The other side does not get it.
      :ok = call(small, :boids, :set_obstacle, [world, {:new, 1}, {1, 1}, 1])
      :ok = call(large, :boids, :set_obstacle, [world, {:new, 2}, {2, 2}, 1])
      # First changes: the node small makes many changes, and the node
      # large makes few.
      for n <- 3..12, do: :ok = call(small, :boids, :set_obstacle, [world, :moved, {n, n}, 1])
      for _ <- 1..10, do: :ok = call(small, :boids, :set_time_scale, [world, 1])
      :ok = call(small, :boids, :remove_obstacle, [world, :back])
      :ok = call(large, :boids, :set_obstacle, [world, :old, {9, 9}, 1])
      # Later changes, after a time that the clocks of the two nodes see.
      Process.sleep(100)
      :ok = call(large, :boids, :set_obstacle, [world, :moved, {2, 2}, 1])
      :ok = call(large, :boids, :set_time_scale, [world, 2])
      :ok = call(large, :boids, :set_obstacle, [world, :back, {4, 4}, 1])
      :ok = call(small, :boids, :remove_obstacle, [world, :old])
      assert rocks(small, world) == %{{:new, 1} => {1, 1}, moved: {12, 12}}
      assert rocks(large, world) == %{{:new, 2} => {2, 2}, back: {4, 4}, moved: {2, 2}, old: {9, 9}}

      heal(world, nodes)
      after_heal = same(world, peers)

      for peer <- peers do
        # Each side has the obstacle of the other side. For each fact
        # that the two sides changed, the last change in time wins: the
        # one change of the node large, against the ten changes of the
        # node small. An obstacle that was removed last stays removed,
        # and an obstacle that was made again after its removal is there.
        assert rocks(peer, world) == %{{:new, 1} => {1, 1}, {:new, 2} => {2, 2}, back: {4, 4}, moved: {2, 2}}
        assert scale(peer, world) == 2
      end

      assert {{:obstacle, :moved}, {{2, 2}, 1}, {_, ^nl}} = List.keyfind(after_heal, {:obstacle, :moved}, 0)
      assert {{:obstacle, :old}, :none, _} = List.keyfind(after_heal, {:obstacle, :old}, 0)
    end

    test "a world that starts again changes a fact at once, and its change wins against the older fact", %{
      nodes: nodes
    } do
      %{world: world, small: a, large: b, ns: na} = world(nodes)
      # The node b makes the facts, with many changes.
      for n <- 1..10, do: :ok = call(b, :boids, :set_obstacle, [world, :rock, {n, n}, 1])
      :ok = call(b, :boids, :set_time_scale, [world, 2])
      assert length(same(world, [a, b])) == 2

      # The world of the node a stops, and starts again with no fact. It
      # changes the rock at once: it does not wait for the facts of the
      # node b.
      :ok = call(a, :boids, :stop_world, [world])
      Process.sleep(20)
      {:ok, _} = call(a, :boids, :start_world, [%{name: world, defaults: %{rules: [], tick: 20}}])
      assert call(a, :boids, :set_obstacle, [world, :rock, {0, 0}, 1]) == :ok
      joined(world, nodes)

      # Its change is the last in time: it wins on the two nodes. The
      # world has the other facts of the node b again.
      after_start = same(world, [a, b])
      assert {{:obstacle, :rock}, {{0, 0}, 1}, {_, ^na}} = List.keyfind(after_start, {:obstacle, :rock}, 0)
      for peer <- [a, b], do: assert(rocks(peer, world) == %{rock: {0, 0}})
      for peer <- [a, b], do: assert(scale(peer, world) == 2)
    end

    test "a fact of each kind, with a large value, goes to a node that comes later and across a split", %{
      nodes: nodes
    } do
      [{small, ns}, {large, _nl}] = Enum.sort_by(nodes, &elem(&1, 1))
      world = :"world#{System.unique_integer([:positive])}"
      options = %{name: world, defaults: %{rules: [], tick: 20}}
      {:ok, _} = call(small, :boids, :start_world, [options])
      # A kind of fact that this version of the library does not know,
      # with a value of 1 MB: a node keeps it, and gives it to the other
      # nodes. It comes to the node as a fact of another node.
      blob = :binary.copy(<<7>>, 1_000_000)
      pid = call(small, :erlang, :whereis, [world])
      call(small, :erlang, :send, [pid, {:facts, [{{:test, :blob}, blob, {1, ns}}]}])
      assert facts(small, world) == [{{:test, :blob}, blob, {1, ns}}]

      # The world starts on the other node.
      {:ok, _} = call(large, :boids, :start_world, [options])
      joined(world, nodes)
      assert same(world, [small, large]) == [{{:test, :blob}, blob, {1, ns}}]

      # During a split, the fact is removed on one side. After the heal,
      # the other side has its mark.
      split(world, nodes)
      call(small, :erlang, :send, [pid, {:facts, [{{:test, :blob}, :none, {2, ns}}]}])
      assert [{{:test, :blob}, ^blob, {1, ^ns}}] = facts(large, world)
      heal(world, nodes)
      assert same(world, [small, large]) == [{{:test, :blob}, :none, {2, ns}}]
      # A node writes one error for each fact that it cannot write.
      for peer <- [small, large],
          do: assert(Enum.count(Cluster.errors(peer), &(&1 =~ "cannot write the fact {test,blob}")) == 2)
    end

    test "the process that changes a fact gets the result timeout when a node gives no answer", %{
      nodes: nodes
    } do
      %{world: world, small: a, large: b} = world(nodes)
      on_exit(fn -> call(a, :application, :unset_env, [:boids, :timeout]) end)
      :ok = call(a, :application, :set_env, [:boids, :timeout, 200])
      space_b = call(b, :boids, :space, [world])
      :ok = call(b, :sys, :suspend, [world])
      assert call(a, :boids, :set_obstacle, [world, :rock, {1, 1}, 1]) == {:error, :timeout}
      # The node of the caller has the change. The other node gets it later.
      assert rocks(a, world) == %{rock: {1, 1}}
      assert rocks(b, space_b) == %{}
      :ok = call(b, :sys, :resume, [world])
      assert eventually(fn -> rocks(b, space_b) == %{rock: {1, 1}} end)
      assert call(a, :boids, :set_time_scale, [world, 2]) == :ok
      assert facts(a, world) == facts(b, world)
    end

    test "the process that changes a fact does not wait for a world that stops", %{nodes: nodes} do
      %{world: world, small: a, large: b} = world(nodes)
      :ok = call(b, :sys, :suspend, [world])
      task = Task.async(fn -> call(a, :boids, :set_obstacle, [world, :rock, {1, 1}, 1]) end)
      assert eventually(fn -> rocks(a, world) == %{rock: {1, 1}} end)
      assert Task.yield(task, 100) == nil
      # The world of the other node stops, with no answer.
      true = call(b, :erlang, :exit, [call(b, :erlang, :whereis, [world]), :kill])
      assert Task.await(task) == :ok
    end

    test "the process that changes a fact can stop in the middle: the other node gets the change", %{
      nodes: nodes
    } do
      %{world: world, small: a, large: b} = world(nodes)
      space_b = call(b, :boids, :space, [world])
      :ok = call(b, :sys, :suspend, [world])
      caller = call(a, :erlang, :spawn, [:boids, :set_obstacle, [world, :rock, {1, 1}, 1]])
      assert eventually(fn -> rocks(a, world) == %{rock: {1, 1}} end)
      true = call(a, :erlang, :exit, [caller, :kill])
      :ok = call(b, :sys, :resume, [world])
      assert eventually(fn -> rocks(b, space_b) == %{rock: {1, 1}} end)
      assert facts(a, world) == facts(b, world)
    end

    test "the process that changes a fact does not wait for a node whose connection ended", %{nodes: nodes} do
      %{world: world, small: a, large: b, nl: nb} = world(nodes)
      # The world of the node a does not know that the connection ended:
      # the call comes to it before the news.
      :ok = call(a, :sys, :suspend, [world])
      task = Task.async(fn -> call(a, :boids, :set_obstacle, [world, :rock, {1, 1}, 1]) end)
      assert Task.yield(task, 100) == nil
      Cluster.split(hd(nodes), List.last(nodes))
      assert eventually(fn -> nb not in call(a, :erlang, :nodes, []) end)
      :ok = call(a, :sys, :resume, [world])
      assert Task.await(task) == :ok
      assert eventually(fn -> call(a, :boids, :nodes, [world]) |> length() == 1 end)
      assert eventually(fn -> call(b, :boids, :nodes, [world]) |> length() == 1 end)
      assert rocks(a, world) == %{rock: {1, 1}}
      assert rocks(b, world) == %{}
      # The other node gets the change after the heal.
      heal(world, nodes)
      assert length(same(world, [a, b])) == 1
      assert rocks(b, world) == %{rock: {1, 1}}
    end
  end

  describe "the grids of a world on two nodes" do
    # A grid of 32 x 16 cells of 10 around the border: the tile of the
    # node small on its left, and the tile of the node large on its right.
    # The blocked cells are columns of the grid, or cells.
    defp land(border, blocked) do
      cells =
        for b <- blocked, cell <- if(is_integer(b), do: for(j <- 0..15, do: {b, j}), else: [b]), do: cell

      :boids_grid.new(size: {32, 16}, cell_size: 10.0, origin: {border - 160.0, 0.0}, blocked: cells)
    end

    defp grid(peer, world), do: call(peer, :boids, :grid, [world, :land])
    defp x_of(peer, world, id), do: elem(elem(call(peer, :boids, :lookup, [world, id]), 1).pos, 0)

    test "the other node has the grid when the call returns, and its boids read the new grid", %{nodes: nodes} do
      %{world: world, small: a, large: b, ns: na, nl: nb, border: border} = world(nodes)
      open = land(border, [])
      assert call(a, :boids, :set_grid, [world, :land, open]) == :ok
      # No wait: the other node has the grid.
      assert grid(b, world) == {:ok, open}
      assert [{{:grid, :land}, ^open, {_, ^na}}] = facts(b, world)
      assert facts(a, world) == facts(b, world)

      # A boid of the node b, in the middle of a cell. It keeps the grid
      # that it read.
      walker = %{id: :walker, pos: {border + 85.0, 85.0}, tick: 5, walkable: {:named, :land}}
      {:ok, :walker} = call(b, :boids, :add, [world, walker])
      Process.sleep(50)
      assert {:ok, %{pos: {x, 85.0}}} = call(b, :boids, :lookup, [world, :walker])
      assert x == border + 85.0

      # The node a closes the cell of the boid. The world of the node b
      # writes the grid, and its boid reads it again: it goes to the
      # nearest walkable place.
      closed = land(border, [{24, 8}])
      assert call(a, :boids, :set_grid, [world, :land, closed]) == :ok
      assert grid(b, world) == {:ok, closed}

      assert eventually(fn ->
               :boids_grid.walkable(closed, elem(call(b, :boids, :lookup, [world, :walker]), 1).pos)
             end)

      {:ok, %{pos: pos}} = call(b, :boids, :lookup, [world, :walker])
      assert_in_delta :boids_vec.dist(pos, {border + 85.0, 85.0}), 5.0, 1.0e-3

      # A change of the node b is on the node a too.
      assert call(b, :boids, :set_grid, [world, :land, open]) == :ok
      assert grid(a, world) == {:ok, open}
      assert [{{:grid, :land}, ^open, {_, ^nb}}] = facts(a, world)
      # A bad grid is an error on its node, and no change on each node.
      assert catch_error(call(a, :boids, :set_grid, [world, :land, :walls])) == :badarg
      assert grid(b, world) == {:ok, open}
    end

    test "a boid with walkable that moves to the other node obeys the same walls there", %{nodes: nodes} do
      %{world: world, small: small, large: large, nl: nl, border: border} = world(nodes)
      # A wall in the tile of the node large, 40 after the border.
      wall = land(border, [20])
      assert call(small, :boids, :set_grid, [world, :land, wall]) == :ok
      mover = %{pos: {border - 10.0, 80.0}, vel: {80.0, 0.0}, max_speed: 80.0, tick: 5}

      {:ok, :walker} =
        call(small, :boids, :add, [world, Map.merge(mover, %{id: :walker, walkable: {:named, :land}})])

      {:ok, :bird} =
        call(small, :boids, :add, [world, Map.merge(mover, %{id: :bird, pos: {border - 10.0, 100.0}})])

      # The two boids move to the node large. The boid with the option
      # stops at the wall, and the other goes on.
      assert eventually(
               fn -> node_of(large, world, :walker) == nl and node_of(large, world, :bird) == nl end,
               500
             )

      assert eventually(fn -> x_of(large, world, :bird) > border + 60 end, 500)
      assert eventually(fn -> abs(x_of(large, world, :walker) - (border + 40.0)) < 1.0e-3 end, 500)
      Process.sleep(100)
      assert_in_delta x_of(large, world, :walker), border + 40.0, 1.0e-3
      assert {:ok, %{walkable: {:named, :land}}} = call(large, :boids, :boid, [world, :walker])
    end

    test "a node that comes later gets the grids, and its boids obey them", %{nodes: nodes} do
      [{small, _ns}, {large, nl}] = Enum.sort_by(nodes, &elem(&1, 1))
      world = :"world#{System.unique_integer([:positive])}"
      options = %{name: world, defaults: %{rules: [], tick: 5}}
      {:ok, _} = call(small, :boids, :start_world, [options])
      # A long land of 40 tiles, with a wall in each tile: 100 after the
      # start of the tile. The library asks for each cell if it is a wall.
      wall = fn {x, _y} -> rem(floor(x / 10), 16) == 10 end
      long = :boids_grid.new(size: {640, 16}, cell_size: 10.0, blocked: wall)
      assert call(small, :boids, :set_grid, [world, :land, long]) == :ok
      assert call(small, :boids, :set_grid, [world, :sea, :boids_grid.new(size: {2, 2})]) == :ok
      assert call(small, :boids, :remove_grid, [world, :sea]) == :ok

      # The world starts on the other node, with no grid. It gets the
      # grid, and the mark of the grid that was removed.
      {:ok, _} = call(large, :boids, :start_world, [options])
      joined(world, nodes)
      assert [{{:grid, :land}, ^long, _}, {{:grid, :sea}, :none, _}] = same(world, [small, large])
      assert grid(large, world) == {:ok, long}
      assert call(large, :boids, :grid, [world, :sea]) == :error

      # A boid in a tile of the node that came later stops at the wall of
      # that tile.
      space = call(large, :boids, :space, [world])

      tile =
        Enum.find(0..39, fn i -> call(large, :boids_space, :home, [space, {i * 160.0 + 80, 80.0}]) == nl end)

      start = {tile * 160.0 + 55.0, 85.0}
      walker = %{id: :walker, pos: start, vel: {40.0, 0.0}, max_speed: 40.0, walkable: {:named, :land}}
      {:ok, :walker} = call(large, :boids, :add, [world, walker])
      assert eventually(fn -> abs(x_of(large, world, :walker) - (tile * 160.0 + 100.0)) < 1.0e-3 end, 500)
      assert node_of(large, world, :walker) == nl
    end

    test "a door that opens on one side of a split is open on all the nodes after the split", %{nodes: nodes} do
      %{world: world, small: small, large: large, ns: ns, border: border} = world(nodes)
      wall = land(border, [20])
      assert call(small, :boids, :set_grid, [world, :land, wall]) == :ok
      # A boid of the node large, which goes to the wall and stops there.
      walker = %{id: :walker, pos: {border + 20.0, 85.0}, vel: {80.0, 0.0}, max_speed: 80.0, tick: 5}
      {:ok, :walker} = call(large, :boids, :add, [world, Map.put(walker, :walkable, {:named, :land})])
      assert eventually(fn -> abs(x_of(large, world, :walker) - (border + 40.0)) < 1.0e-3 end, 500)

      split(world, nodes)
      # The node small opens a door in front of the boid. The node large
      # does not get it: the wall stays.
      door = :boids_grid.set_cost(wall, [{20, 8}], 1)
      assert call(small, :boids, :set_grid, [world, :land, door]) == :ok
      assert grid(small, world) == {:ok, door}
      assert grid(large, world) == {:ok, wall}
      :ok = call(large, :boids, :update, [world, :walker, %{vel: {80.0, 0.0}}])
      Process.sleep(100)
      assert_in_delta x_of(large, world, :walker), border + 40.0, 1.0e-3

      heal(world, nodes)
      # The node large gets the facts of the node small: the door is
      # open on the two nodes, and the boid of the node large reads the
      # new grid and goes through.
      assert [{{:grid, :land}, ^door, {_, ^ns}}] = same(world, [small, large])
      assert grid(large, world) == {:ok, door}
      :ok = call(large, :boids, :update, [world, :walker, %{vel: {80.0, 0.0}}])
      assert eventually(fn -> x_of(large, world, :walker) > border + 60 end, 500)
    end

    test "remove_grid/2 removes a grid on all the nodes, and its boids have no limit", %{nodes: nodes} do
      %{world: world, small: small, large: large, border: border} = world(nodes)
      wall = land(border, [20])
      assert call(small, :boids, :set_grid, [world, :land, wall]) == :ok
      walker = %{id: :walker, pos: {border + 20.0, 85.0}, vel: {80.0, 0.0}, max_speed: 80.0, tick: 5}
      {:ok, :walker} = call(large, :boids, :add, [world, Map.put(walker, :walkable, {:named, :land})])
      assert eventually(fn -> abs(x_of(large, world, :walker) - (border + 40.0)) < 1.0e-3 end, 500)

      # The node small removes the grid: the node large has no grid when
      # the call returns, and a mark stays for the removed grid.
      assert call(small, :boids, :remove_grid, [world, :land]) == :ok
      assert grid(large, world) == :error
      assert grid(small, world) == :error
      assert [{{:grid, :land}, :none, _}] = facts(large, world)
      assert facts(small, world) == facts(large, world)
      :ok = call(large, :boids, :update, [world, :walker, %{vel: {80.0, 0.0}}])
      assert eventually(fn -> x_of(large, world, :walker) > border + 60 end, 500)
    end

    test "set_grid/3 and remove_grid/2 give the result timeout when a node gives no answer", %{nodes: nodes} do
      %{world: world, small: a, large: b, border: border} = world(nodes)
      on_exit(fn -> call(a, :application, :unset_env, [:boids, :timeout]) end)
      :ok = call(a, :application, :set_env, [:boids, :timeout, 200])
      wall = land(border, [20])
      space_b = call(b, :boids, :space, [world])
      :ok = call(b, :sys, :suspend, [world])
      assert call(a, :boids, :set_grid, [world, :land, wall]) == {:error, :timeout}
      # The node of the caller has the change. The other node gets it later.
      assert grid(a, world) == {:ok, wall}
      assert grid(b, space_b) == :error
      :ok = call(b, :sys, :resume, [world])
      assert eventually(fn -> grid(b, space_b) == {:ok, wall} end)
      :ok = call(b, :sys, :suspend, [world])
      assert call(a, :boids, :remove_grid, [world, :land]) == {:error, :timeout}
      :ok = call(b, :sys, :resume, [world])
      assert eventually(fn -> grid(b, space_b) == :error end)
      assert facts(a, world) == facts(b, world)
    end
  end

  describe "the fields of a world on two nodes" do
    # A field of the land of the grids (32 x 16 cells of 10 around the
    # border), with the ways to one goal cell.
    defp ways(border, blocked, goal), do: :boids_field.new(land(border, blocked), [goal])
    defp field(peer, world), do: call(peer, :boids, :field, [world, :exit])
    defp pos_of(peer, world, id), do: elem(call(peer, :boids, :lookup, [world, id]), 1).pos

    # True when a boid is at 15 or less from the center of a cell of the land.
    defp at_cell(peer, world, id, border, {i, j}) do
      :boids_vec.dist(pos_of(peer, world, id), {border - 160.0 + i * 10 + 5, j * 10 + 5.0}) <= 15.0
    end

    # A boid that follows the field with the name exit.
    defp goer(more) do
      rules = [{:flow, 1.0, field: {:named, :exit}}]
      Map.merge(%{id: :goer, rules: rules, max_speed: 40.0, max_force: 400.0, tick: 5}, more)
    end

    test "the other node has the field when the call returns, and its boids follow the new field", %{
      nodes: nodes
    } do
      %{world: world, small: a, large: b, ns: na, nl: nb, border: border} = world(nodes)
      # The goal is in the tile of the node b.
      east = ways(border, [], {28, 4})
      assert call(a, :boids, :set_field, [world, :exit, east]) == :ok
      # No wait: the other node has the field.
      assert field(b, world) == {:ok, east}
      assert [{{:field, :exit}, ^east, {_, ^na}}] = facts(b, world)
      assert facts(a, world) == facts(b, world)

      # A boid of the node b goes to the goal. It keeps the field that it read.
      {:ok, :goer} = call(b, :boids, :add, [world, goer(%{pos: {border + 25.0, 125.0}})])
      assert eventually(fn -> at_cell(b, world, :goer, border, {28, 4}) end, 500)

      # The node a moves the goal. The world of the node b writes the
      # field, and its boid reads it again: it goes to the new goal.
      south = ways(border, [], {20, 13})
      assert call(a, :boids, :set_field, [world, :exit, south]) == :ok
      assert field(b, world) == {:ok, south}
      assert eventually(fn -> at_cell(b, world, :goer, border, {20, 13}) end, 500)

      # A change of the node b is on the node a too.
      assert call(b, :boids, :set_field, [world, :exit, east]) == :ok
      assert field(a, world) == {:ok, east}
      assert [{{:field, :exit}, ^east, {_, ^nb}}] = facts(a, world)
      # A bad field is an error on its node, and no change on each node.
      assert catch_error(call(a, :boids, :set_field, [world, :exit, :ways])) == :badarg
      assert field(b, world) == {:ok, east}
    end

    test "a boid with a field that moves to the other node goes on to its goal there", %{nodes: nodes} do
      %{world: world, small: small, large: large, ns: ns, nl: nl, border: border} = world(nodes)
      # A wall in the tile of the node large, 40 after the border, with
      # a door at its top. The goal is behind the wall.
      wall = for j <- 3..15, do: {20, j}
      assert call(small, :boids, :set_grid, [world, :land, land(border, wall)]) == :ok
      assert call(small, :boids, :set_field, [world, :exit, ways(border, wall, {28, 12})]) == :ok
      # The boid starts in the tile of the node small.
      start = %{pos: {border - 60.0, 125.0}, walkable: {:named, :land}}
      {:ok, :goer} = call(small, :boids, :add, [world, goer(start)])
      assert node_of(small, world, :goer) == ns
      # It moves to the node large, goes through the door, and comes to
      # the goal: the field is on that node, and the rule goes with the boid.
      assert eventually(fn -> node_of(large, world, :goer) == nl end, 500)
      assert eventually(fn -> at_cell(large, world, :goer, border, {28, 12}) end, 1000)
      assert {:ok, boid} = call(large, :boids, :boid, [world, :goer])
      assert :boids_boid.named(boid) == [grid: :land, field: :exit]
    end

    test "a node that comes later gets the fields, and its boids follow them", %{nodes: nodes} do
      [{small, _ns}, {large, nl}] = Enum.sort_by(nodes, &elem(&1, 1))
      world = :"world#{System.unique_integer([:positive])}"
      options = %{name: world, defaults: %{rules: [], tick: 5}}
      {:ok, _} = call(small, :boids, :start_world, [options])
      # A long land of 40 tiles, with a goal in the middle of each tile.
      long = :boids_grid.new(size: {640, 16}, cell_size: 10.0)
      exits = :boids_field.new(long, for(tile <- 0..39, do: {tile * 16 + 8, 8}))
      assert call(small, :boids, :set_field, [world, :exit, exits]) == :ok
      food = :boids_field.new(:boids_grid.new(size: {2, 2}), [{0, 0}])
      assert call(small, :boids, :set_field, [world, :food, food]) == :ok
      assert call(small, :boids, :remove_field, [world, :food]) == :ok

      # The world starts on the other node, with no field. It gets the
      # field, and the mark of the field that was removed.
      {:ok, _} = call(large, :boids, :start_world, [options])
      joined(world, nodes)
      assert [{{:field, :exit}, ^exits, _}, {{:field, :food}, :none, _}] = same(world, [small, large])
      assert field(large, world) == {:ok, exits}
      assert call(large, :boids, :field, [world, :food]) == :error

      # A boid in a tile of the node that came later goes to the goal of
      # that tile.
      space = call(large, :boids, :space, [world])

      tile =
        Enum.find(0..39, fn i -> call(large, :boids_space, :home, [space, {i * 160.0 + 80, 80.0}]) == nl end)

      {:ok, :goer} = call(large, :boids, :add, [world, goer(%{pos: {tile * 160.0 + 25.0, 135.0}})])

      assert eventually(
               fn -> :boids_vec.dist(pos_of(large, world, :goer), {tile * 160.0 + 85.0, 85.0}) <= 15.0 end,
               500
             )

      assert node_of(large, world, :goer) == nl
    end

    test "a new field on one side of a split is on all the nodes after the split", %{nodes: nodes} do
      %{world: world, small: small, large: large, ns: ns, border: border} = world(nodes)
      east = ways(border, [], {28, 4})
      assert call(small, :boids, :set_field, [world, :exit, east]) == :ok
      # A boid of the node large, which goes to the goal and stays near it.
      {:ok, :goer} = call(large, :boids, :add, [world, goer(%{pos: {border + 25.0, 45.0}})])
      assert eventually(fn -> at_cell(large, world, :goer, border, {28, 4}) end, 500)

      split(world, nodes)
      # The node small moves the goal. The node large does not get the
      # new field: its boid stays near the old goal.
      south = ways(border, [], {20, 13})
      assert call(small, :boids, :set_field, [world, :exit, south]) == :ok
      assert field(small, world) == {:ok, south}
      assert field(large, world) == {:ok, east}

      for _ <- 1..10 do
        Process.sleep(20)
        assert :boids_vec.dist(pos_of(large, world, :goer), {border + 125.0, 45.0}) < 50.0
      end

      heal(world, nodes)
      # The node large gets the facts of the node small: the two nodes
      # have the new field, and the boid of the node large reads it and
      # goes to the new goal.
      assert [{{:field, :exit}, ^south, {_, ^ns}}] = same(world, [small, large])
      assert field(large, world) == {:ok, south}
      assert eventually(fn -> at_cell(large, world, :goer, border, {20, 13}) end, 500)
    end

    test "remove_field/2 removes a field on all the nodes, and its boids have no force", %{nodes: nodes} do
      %{world: world, small: small, large: large, border: border} = world(nodes)
      assert call(small, :boids, :set_field, [world, :exit, ways(border, [], {28, 4})]) == :ok
      {:ok, :goer} = call(large, :boids, :add, [world, goer(%{pos: {border + 25.0, 45.0}})])
      assert eventually(fn -> at_cell(large, world, :goer, border, {28, 4}) end, 500)

      # The node small removes the field: the node large has no field
      # when the call returns, and a mark stays for the removed field.
      assert call(small, :boids, :remove_field, [world, :exit]) == :ok
      assert field(large, world) == :error
      assert field(small, world) == :error
      assert [{{:field, :exit}, :none, _}] = facts(large, world)
      assert facts(small, world) == facts(large, world)
      # The boid has no force now: from the old goal, it goes away with
      # the velocity that it gets, and does not come back.
      away = %{pos: {border + 125.0, 45.0}, vel: {0.0, 40.0}}
      :ok = call(large, :boids, :update, [world, :goer, away])
      assert eventually(fn -> elem(pos_of(large, world, :goer), 1) > 45.0 + 60 end, 500)
    end

    test "set_field/3 and remove_field/2 give the result timeout when a node gives no answer", %{nodes: nodes} do
      %{world: world, small: a, large: b, border: border} = world(nodes)
      on_exit(fn -> call(a, :application, :unset_env, [:boids, :timeout]) end)
      :ok = call(a, :application, :set_env, [:boids, :timeout, 200])
      east = ways(border, [], {28, 4})
      space_b = call(b, :boids, :space, [world])
      :ok = call(b, :sys, :suspend, [world])
      assert call(a, :boids, :set_field, [world, :exit, east]) == {:error, :timeout}
      # The node of the caller has the change. The other node gets it later.
      assert field(a, world) == {:ok, east}
      assert field(b, space_b) == :error
      :ok = call(b, :sys, :resume, [world])
      assert eventually(fn -> field(b, space_b) == {:ok, east} end)
      :ok = call(b, :sys, :suspend, [world])
      assert call(a, :boids, :remove_field, [world, :exit]) == {:error, :timeout}
      :ok = call(b, :sys, :resume, [world])
      assert eventually(fn -> field(b, space_b) == :error end)
      assert facts(a, world) == facts(b, world)
    end
  end
end

defmodule BoidsThreeNodesTest do
  # A world on three nodes. A fault that needs three nodes, or three
  # processes of one boid, shows here (specs/MoveMany.tla).
  use ExUnit.Case, async: false
  import Boids.Helpers
  import Boids.Cluster, only: [call: 4]

  alias Boids.Cluster

  @moduletag :capture_log

  setup_all do
    nodes = Cluster.start(3, split: true)
    on_exit(fn -> Cluster.stop(nodes) end)
    # The nodes in the order of their names.
    %{nodes: Enum.sort_by(nodes, &elem(&1, 1))}
  end

  defp world(nodes) do
    world = :"world#{System.unique_integer([:positive])}"
    options = %{name: world, defaults: %{rules: [], tick: 20}}
    for {peer, _} <- nodes, do: {:ok, _} = call(peer, :boids, :start_world, [options])
    joined(world, nodes)
    world
  end

  # End the connection of the first node to the other nodes. When a
  # node loses a connection, Erlang ends its connections to the other
  # nodes also, so that no node has a part of the connections. Thus the
  # other nodes make their connection again.
  defp cut(world, [first | others] = nodes) do
    for other <- others, do: Cluster.split(first, other)
    for node <- nodes, do: joined(world, [node])
    connect(world, others)
  end

  # Make the connections of the nodes, one at a time.
  defp connect(world, nodes) do
    for {a, i} <- Enum.with_index(nodes), b <- Enum.drop(nodes, i + 1), do: Cluster.heal(a, b)
    joined(world, nodes)
  end

  # Each node of the list has the world with the nodes of the list, and no other node.
  defp joined(world, nodes) do
    names = nodes |> Enum.map(&elem(&1, 1)) |> Enum.sort()
    for {peer, _} <- nodes, do: assert(eventually(fn -> call(peer, :boids, :nodes, [world]) == names end))
  end

  # A process of the boid on a node, with a number of moves. The boid
  # has a manual step: it stays on its node.
  defp copy({peer, _node}, world, id, moves) do
    process = %{tick: :manual, max_dt: 0.25, search: 1, priority: :low, hibernate: true}
    boid = :boids_boid.new(%{id: id, pos: {80, 80}, rules: [], data: moves})
    moving = %{boid: boid, mod: :undefined, server: process, relations: [], moves: moves, rand: :undefined}
    {:ok, pid} = call(peer, :gen_boid, :adopt, [world, moving])
    pid
  end

  # The nodes that have a process of the boid.
  defp nodes_of(nodes, world, id) do
    for {peer, node} <- nodes,
        match?({:server, _}, call(peer, :boids_space, :owner, [call(peer, :boids, :space, [world]), id])),
        do: node
  end

  # In the end, the boid of each case has one process, on the node of the case.
  defp one_each(nodes, world, cases) do
    for {id, _copies, keeper} <- cases do
      {_peer, stays} = Enum.at(nodes, keeper)

      assert eventually(fn -> nodes_of(nodes, world, id) == [stays] end),
             "the boid #{id} is on #{inspect(nodes_of(nodes, world, id))}, not only on #{stays}"
    end

    for {peer, _} <- nodes, do: assert(call(peer, :boids, :count, [world]) == length(cases))
  end

  test "a node that starts a process for a boid tells all the nodes, and the boid has one process",
       %{nodes: nodes} do
    world = world(nodes)

    # A boid moves from a node to a second node. The first node does
    # not get the answer, and keeps its process. Then the boid moves to
    # a third node. The first node and the third node always had their
    # connection: no heal makes them compare their boids.
    cases = [
      # {id, the processes in the order of their start: {node, moves}, the node that keeps the boid}
      {:newer_large, [{0, 1}, {2, 2}], 2},
      {:newer_small, [{2, 1}, {0, 2}], 0},
      # A call of an old process that comes late starts a process with less moves.
      {:late, [{1, 5}, {2, 2}], 1},
      # With the same number of moves, the process of the node with the larger name stays.
      {:tie, [{0, 1}, {1, 1}, {2, 1}], 2},
      {:first, [{0, 3}, {1, 2}, {2, 1}], 0},
      {:middle, [{0, 1}, {2, 1}, {1, 2}], 1}
    ]

    pids =
      for {id, copies, keeper} <- cases, {index, moves} <- copies do
        {index == keeper, copy(Enum.at(nodes, index), world, id, moves)}
      end

    one_each(nodes, world, cases)
    {[{true, kept} | _], _} = Enum.split_with(pids, &elem(&1, 0))
    assert node(kept) == nodes |> Enum.at(2) |> elem(1)
  end

  test "after a split and a heal of three nodes, a boid with a process on each node has one process",
       %{nodes: [first, second, third] = nodes} do
    world = world(nodes)

    # The first node has no connection to the other nodes. The other
    # nodes have their connection.
    cut(world, nodes)
    joined(world, [first])
    joined(world, [second, third])

    one_cut = [
      {:cut_new, [{0, 1}, {1, 2}, {2, 3}], 2},
      {:cut_old, [{0, 4}, {1, 2}, {2, 3}], 0},
      {:cut_tie, [{0, 3}, {2, 2}, {1, 3}], 1}
    ]

    for {id, copies, _keeper} <- one_cut,
        {index, moves} <- copies,
        do: copy(Enum.at(nodes, index), world, id, moves)

    connect(world, nodes)
    one_each(nodes, world, one_cut)

    # No node has a connection.
    Cluster.split(first, second)
    for node <- nodes, do: joined(world, [node])

    all_cut = [
      {:all_tie, [{0, 1}, {1, 1}, {2, 1}], 2},
      {:all_first, [{0, 3}, {1, 2}, {2, 1}], 0},
      {:all_middle, [{0, 1}, {1, 5}, {2, 2}], 1},
      {:all_two, [{0, 1}, {1, 4}, {2, 4}], 2}
    ]

    for {id, copies, _keeper} <- all_cut,
        {index, moves} <- copies,
        do: copy(Enum.at(nodes, index), world, id, moves)

    # Each node has a process of each of these boids.
    for {id, _copies, _keeper} <- all_cut,
        do: assert(nodes_of(nodes, world, id) == Enum.map(nodes, &elem(&1, 1)))

    # The connections come again one at a time, the last node first.
    connect(world, [third, second, first])
    one_each(nodes, world, one_cut ++ all_cut)
  end

  describe "the facts of a world on three nodes (specs/Facts.tla)" do
    setup %{nodes: nodes} do
      # A test before these can end in the middle of a split: these tests
      # start with all the connections.
      for {a, i} <- Enum.with_index(nodes), b <- Enum.drop(nodes, i + 1), do: Cluster.heal(a, b)
      :ok
    end

    defp facts({peer, _node}, world), do: call(peer, :boids_world, :facts, [world])

    defp scale({peer, _node}, world),
      do: call(peer, :boids_space, :env, [call(peer, :boids, :space, [world])]).time_scale

    # The obstacles of a node: id => position.
    defp rocks({peer, _node}, world), do: Map.new(call(peer, :boids, :obstacles, [world]), &{&1.id, &1.pos})

    # In the end, the nodes have the same facts, with the same versions.
    defp same(world, nodes) do
      assert eventually(fn -> nodes |> Enum.map(&facts(&1, world)) |> Enum.uniq() |> length() == 1 end)
      facts(hd(nodes), world)
    end

    test "a node that comes later gets all the facts, and its changes are on all the nodes", %{
      nodes: [first, second, third] = nodes
    } do
      world = world([first, second])
      {one, _} = first
      {two, _} = second
      {three, node_three} = third
      :ok = call(one, :boids, :set_time_scale, [world, 3])
      :ok = call(one, :boids, :set_obstacle, [world, :rock, {1, 1}, 1])
      :ok = call(two, :boids, :set_obstacle, [world, :pole, {2, 2}, 1])
      :ok = call(two, :boids, :remove_obstacle, [world, :rock])
      before = facts(first, world)
      assert length(before) == 3
      assert facts(second, world) == before

      # The world starts on the third node, after the changes.
      {:ok, _} = call(three, :boids, :start_world, [%{name: world, defaults: %{rules: [], tick: 20}}])
      joined(world, nodes)
      assert same(world, nodes) == before
      assert rocks(third, world) == %{pole: {2, 2}}
      assert scale(third, world) == 3

      # The first change of the new node is after the changes that it
      # got. Each other node has it when the call returns.
      assert call(three, :boids, :set_obstacle, [world, :rock, {3, 3}, 1]) == :ok

      assert {{:obstacle, :rock}, {{3, 3}, 1}, {counter, ^node_three}} =
               List.keyfind(facts(third, world), {:obstacle, :rock}, 0)

      assert counter > Enum.max(for {_key, _value, {known, _node}} <- before, do: known)
      for node <- nodes, do: assert(rocks(node, world) == %{pole: {2, 2}, rock: {3, 3}})
      for node <- nodes, do: assert(facts(node, world) == facts(third, world))
    end

    test "after a split of the three nodes with changes on each node, the nodes have the same facts", %{
      nodes: [first, second, third] = nodes
    } do
      world = world(nodes)
      {one, _} = first
      {two, _} = second
      {three, node_three} = third
      :ok = call(one, :boids, :set_obstacle, [world, :rock, {1, 1}, 1])
      :ok = call(one, :boids, :set_obstacle, [world, :stone, {1, 1}, 1])
      for node <- nodes, do: assert(rocks(node, world) == %{rock: {1, 1}, stone: {1, 1}})

      # No node has a connection. The test ends each connection: it does
      # not wait for Erlang to end the connections of a third node.
      for {a, i} <- Enum.with_index(nodes), b <- Enum.drop(nodes, i + 1), do: Cluster.split(a, b)
      for node <- nodes, do: joined(world, [node])

      # The second node moves the rock and the stone.
      :ok = call(two, :boids, :set_obstacle, [world, :rock, {2, 2}, 1])
      :ok = call(two, :boids, :set_obstacle, [world, :stone, {2, 2}, 1])
      # Later, the third node makes a pole, and moves the stone.
      Process.sleep(50)
      :ok = call(three, :boids, :set_obstacle, [world, :pole, {7, 7}, 1])
      :ok = call(three, :boids, :set_obstacle, [world, :stone, {3, 3}, 1])
      # Later, the first node removes the rock, after two other changes.
      Process.sleep(50)
      :ok = call(one, :boids, :set_time_scale, [world, 0.5])
      :ok = call(one, :boids, :set_time_scale, [world, 0.25])
      :ok = call(one, :boids, :remove_obstacle, [world, :rock])
      assert rocks(first, world) == %{stone: {1, 1}}
      assert rocks(second, world) == %{rock: {2, 2}, stone: {2, 2}}
      assert rocks(third, world) == %{rock: {1, 1}, stone: {3, 3}, pole: {7, 7}}

      # The connections come again one at a time, the last node first.
      connect(world, [third, second, first])
      after_heal = same(world, nodes)

      for node <- nodes do
        # The rock was removed last, so it stays removed. The third node
        # moved the stone last, so the stone is where that node put it.
        assert rocks(node, world) == %{stone: {3, 3}, pole: {7, 7}}
        assert scale(node, world) == 0.25
      end

      assert {{:obstacle, :stone}, {{3, 3}, 1}, {_, ^node_three}} =
               List.keyfind(after_heal, {:obstacle, :stone}, 0)
    end
  end
end
