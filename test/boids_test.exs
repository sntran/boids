defmodule BoidsTest do
  use ExUnit.Case, async: true
  import Boids.Helpers

  alias Boids.TestBoids.Mouse

  @box {{0, 0}, {100, 100}}

  # A world that stops at the end of the test.
  defp world(opts \\ %{}) do
    {:ok, world} = :boids.start_world(opts)
    on_exit(fn -> :boids.stop_world(world) end)
    world
  end

  # A boid with no rule and no clock: it moves only with step/2.
  defp still(more \\ %{}), do: Map.merge(%{pos: {0, 0}, rules: [], tick: :manual}, Map.new(more))

  # Only a process that hibernates has a heap smaller than the minimum
  # heap of a new process.
  defp hibernates?(pid) do
    {:total_heap_size, words} = Process.info(pid, :total_heap_size)
    words < 233
  end

  defp pos(world, id) do
    {:ok, %{pos: pos}} = :boids.lookup(world, id)
    pos
  end

  describe "start_world/1 and stop_world/1" do
    test "starts the process of a world, with its space" do
      {:ok, world} = :boids.start_world()
      assert Process.alive?(world)
      space = :boids.space(world)
      assert %{owner: ^world, cell_size: 10.0, bounds: :undefined, wrap: false, defaults: %{}} = space
      assert :boids.space(space) == space
      assert :boids.count(world) == 0
      assert :boids.snapshot(world) == []
      assert :boids.stop_world(world) == :ok
      refute Process.alive?(world)
      assert :ets.info(space.rows) == :undefined
      assert :boids.stop_world(world) == {:error, :not_found}
      assert :boids.stop_world(space) == {:error, :not_found}
    end

    test "the processes that control a world have a high priority" do
      world = world()
      space = :boids.space(world)
      assert Process.info(world, :priority) == {:priority, :high}
      assert Process.info(:boids_world.sup(world), :priority) == {:priority, :high}
      assert Process.info(:boids_world.boid_sup(space), :priority) == {:priority, :high}
      # A boid has a low priority, or the priority of the other processes.
      {:ok, id} = :boids.add(world, still())
      assert Process.info(:boids.whereis(world, id), :priority) == {:priority, :low}
      {:ok, id} = :boids.add(world, still(priority: :normal))
      assert Process.info(:boids.whereis(world, id), :priority) == {:priority, :normal}
    end

    test "the processes of a world and of a boid have a label" do
      world = world(name: :boids_test_label)
      {:ok, :a} = :boids.add(world, still(id: :a))
      assert :proc_lib.get_label(world) == {:boids, :world, :boids_test_label}
      assert :proc_lib.get_label(:boids.whereis(world, :a)) == {:boids, :boid, :a}
      assert :proc_lib.get_label(world()) == {:boids, :world, :undefined}
    end

    test "accepts a list of options" do
      world = world(bounds: @box, wrap: true, cell_size: 5, defaults: %{max_speed: 3})
      assert %{bounds: @box, wrap: true, cell_size: 5, defaults: %{max_speed: 3}} = :boids.space(world)
    end

    test "gives a name to the world" do
      world = world(name: :boids_test_named)
      assert Process.whereis(:boids_test_named) == world
      assert :boids.count(:boids_test_named) == 0
      global = world(name: {:global, :boids_test_global})
      assert :global.whereis_name(:boids_test_global) == global
      assert :boids.count({:global, :boids_test_global}) == 0
      via = world(name: {:via, :global, :boids_test_via})
      assert :boids.count({:via, :global, :boids_test_via}) == 0
      assert :boids.stop_world({:via, :global, :boids_test_via}) == :ok
      refute Process.alive?(via)
    end

    @tag :capture_log
    test "refuses a name that another process has" do
      world = world(name: :boids_test_twice)
      assert :boids.start_world(name: :boids_test_twice) == {:error, {:already_started, world}}
    end

    test "refuses a bad option" do
      for {key, value} <- [
            cell_size: 0,
            wrap: true,
            bounds: {{0, 0}, {0, 0}},
            name: "space",
            name: {:local, :space},
            name: {:via, "module", :space},
            defaults: [max_speed: 1],
            color: :red
          ] do
        assert :boids.start_world(%{key => value}) == {:error, {:bad_option, {key, value}}}
      end

      assert :boids.start_world(defaults: %{max_speed: -1}) == {:error, {:bad_option, {:max_speed, -1}}}
      assert :boids.start_world(cell_size: 1.0e200) == {:error, {:bad_option, {:cell_size, 1.0e200}}}
      box = {{0, 0}, {1.0e200, 1}}
      assert :boids.start_world(bounds: box) == {:error, {:bad_option, {:bounds, box}}}
      assert :boids.start_world(defaults: %{tick: 0}) == {:error, {:bad_option, {:tick, 0}}}
      assert :boids.start_world(defaults: %{shape: :bird}) == {:error, {:bad_option, {:shape, :bird}}}
      assert :boids.start_world(:big) == {:error, {:bad_option, :big}}
      assert :boids.start_world([:big]) == {:error, {:bad_option, [:big]}}
    end

    test "each default is good alone" do
      # The check of each boid sees the defaults with the options of the boid.
      world =
        world(bounds: {{0, 0, 0}, {9, 9, 9}}, defaults: %{vel: {0, 0, 1}, min_speed: 12, tick: :manual})

      assert :boids.add(world, pos: {1, 1, 1}) == {:error, {:bad_option, {:min_speed, 12}}}
      assert {:ok, id} = :boids.add(world, pos: {1, 1, 1}, max_speed: 20)
      assert {:ok, %{vel: {0, 0, 1}, min_speed: 12}} = :boids.boid(world, id)
    end

    test "stops the boids of the world" do
      {:ok, world} = :boids.start_world()
      {:ok, id} = :boids.add(world, still())
      pid = :boids.whereis(world, id)
      assert Process.alive?(pid)
      assert :boids.stop_world(:boids.space(world)) == :ok
      refute Process.alive?(pid)
    end
  end

  describe "child_spec/1" do
    test "starts a world below a supervisor of yours" do
      {:ok, sup} =
        Supervisor.start_link([{:boids, name: :boids_test_child, bounds: @box}], strategy: :one_for_one)

      assert %{bounds: @box} = :boids.space(:boids_test_child)
      {:ok, id} = :boids.add(:boids_test_child, still())
      assert :boids.count(:boids_test_child) == 1
      assert :boids.stop_world(:boids_test_child) == {:error, :not_found}
      pid = :boids.whereis(:boids_test_child, id)
      Supervisor.stop(sup)
      refute Process.alive?(pid)
      assert Process.whereis(:boids_test_child) == nil
    end

    test "has the name of the world in its id" do
      assert %{
               id: {:boids, :a},
               start: {:boids_world_sup, :start_link, [%{name: :a}]},
               type: :supervisor
             } =
               :boids.child_spec(%{name: :a})

      assert %{id: {:boids, :undefined}} = :boids.child_spec([])
    end

    test "refuses a bad option" do
      assert catch_error(:boids.child_spec(%{cell_size: -1})) == {:bad_option, {:cell_size, -1}}
    end

    @tag :capture_log
    test "a world that stops with an error starts again, with no boid" do
      {:ok, sup} = Supervisor.start_link([{:boids, name: :boids_test_restart}], strategy: :one_for_one)
      first = Process.whereis(:boids_test_restart)
      {:ok, id} = :boids.add(:boids_test_restart, still())
      pid = :boids.whereis(:boids_test_restart, id)
      Process.exit(first, :kill)
      assert eventually(fn -> Process.whereis(:boids_test_restart) not in [nil, first] end)
      assert eventually(fn -> not Process.alive?(pid) end)
      assert :boids.count(:boids_test_restart) == 0
      assert {:ok, _} = :boids.add(:boids_test_restart, still())
      Supervisor.stop(sup)
    end
  end

  describe "add/2" do
    test "starts the process of a boid" do
      world = world()
      {:ok, id} = :boids.add(world, still(pos: {1, 2}, vel: {3, 4}, group: :birds, data: :blue))
      # The id is not the process: a boid can move to another node.
      assert is_reference(id)
      pid = :boids.whereis(world, id)
      assert is_pid(pid)
      assert :boids.count(world) == 1

      assert :boids.lookup(world, id) ==
               {:ok, %{id: id, pos: {1, 2}, vel: {3, 4}, group: :birds, data: :blue, pid: pid}}

      assert :boids.snapshot(world) == [elem(:boids.lookup(world, id), 1)]
      assert {:ok, %{id: ^id, pos: {1, 2}, max_speed: 10.0, rules: []}} = :boids.boid(world, id)
    end

    test "accepts an id and a list of options" do
      world = world()
      assert :boids.add(world, id: :a, pos: {1, 2}, tick: :manual) == {:ok, :a}
      pid = :boids.whereis(world, :a)
      assert is_pid(pid)
      assert {:ok, %{id: :a, pid: ^pid}} = :boids.lookup(world, :a)
    end

    test "refuses an id that is in the world" do
      world = world()
      {:ok, :a} = :boids.add(world, still(id: :a))
      assert :boids.add(world, still(id: :a, pos: {5, 5})) == {:error, {:exists, :a}}
      assert :boids.count(world) == 1
      assert pos(world, :a) == {0, 0}
    end

    test "refuses a bad option" do
      world = world()
      assert :boids.add(world, %{}) == {:error, {:bad_option, {:pos, :undefined}}}
      assert :boids.add(world, still(max_speed: -1)) == {:error, {:bad_option, {:max_speed, -1}}}
      assert :boids.add(world, still(tick: 0)) == {:error, {:bad_option, {:tick, 0}}}
      assert :boids.add(world, still(tick: 1.5)) == {:error, {:bad_option, {:tick, 1.5}}}
      assert :boids.add(world, still(max_dt: 0)) == {:error, {:bad_option, {:max_dt, 0}}}
      assert :boids.add(world, still(seed: :random)) == {:error, {:bad_option, {:seed, :random}}}
      assert :boids.add(world, still(priority: :high)) == {:error, {:bad_option, {:priority, :high}}}
      assert :boids.add(world, still(hibernate: :yes)) == {:error, {:bad_option, {:hibernate, :yes}}}
      assert :boids.add(world, still(wings: 2)) == {:error, {:bad_option, {:wings, 2}}}
      assert :boids.add(world, :bird) == {:error, {:bad_option, :bird}}
      assert :boids.add(world, [:bird]) == {:error, {:bad_option, [:bird]}}
      assert :boids.count(world) == 0
    end

    test "uses the defaults of the world" do
      world = world(defaults: %{max_speed: 3, group: :fish, tick: :manual, rules: []})
      {:ok, a} = :boids.add(world, pos: {0, 0})
      {:ok, b} = :boids.add(world, pos: {0, 0}, max_speed: 4)
      assert {:ok, %{max_speed: 3, group: :fish, rules: []}} = :boids.boid(world, a)
      assert {:ok, %{max_speed: 4, group: :fish}} = :boids.boid(world, b)
    end

    test "refuses a position that does not have the size of the world" do
      world = world()
      {:ok, a} = :boids.add(world, still())
      assert :boids.add(world, still(pos: {0, 0, 0})) == {:error, {:bad_option, {:pos, {0, 0, 0}}}}
      assert :boids.join(world, pos: {0, 0, 0}) == {:error, {:bad_option, {:pos, {0, 0, 0}}}}
      assert :boids.populate(world, 2, area: {{0, 0, 0}, {1, 1, 1}}, tick: :manual) |> elem(0) == :error

      assert :boids.update(world, a, %{pos: {0, 0, 0}, vel: {0, 0, 0}}) ==
               {:error, {:bad_option, {:pos, {0, 0, 0}}}}

      assert_raise ArgumentError, fn -> :boids.set_obstacle(world, :rock, {0, 0, 0}, 1) end
      assert :boids.count(world) == 1
      # The size of the first boid stays, also for an empty world.
      :ok = :boids.remove(world, a)
      assert :boids.add(world, still(pos: {0, 0, 0})) == {:error, {:bad_option, {:pos, {0, 0, 0}}}}
      assert {:ok, _} = :boids.add(world, still())
      # A world with a box has the size of its box.
      box = world(bounds: {{0, 0, 0}, {9, 9, 9}})
      assert :boids.add(box, still()) == {:error, {:bad_option, {:pos, {0, 0}}}}
      assert_raise ArgumentError, fn -> :boids.set_obstacle(box, :rock, {0, 0}, 1) end
      assert :boids.set_obstacle(box, :rock, {0, 0, 0}, 1) == :ok
    end

    @tag :capture_log
    test "an obstacle of another size does not stop a boid" do
      # An empty world with no box accepts an obstacle of each size.
      world = world()
      assert :boids.set_obstacle(world, :rock, {5, 0, 0}, 2) == :ok
      {:ok, id} = :boids.add(world, still(vel: {1, 0}, rules: [avoid: 1]))
      :boids.step(world, 1)
      assert pos(world, id) == {1.0, 0.0}
    end

    test "functions for a boid that is not in the world" do
      world = world()
      assert :boids.lookup(world, :nobody) == :error
      assert :boids.whereis(world, :nobody) == :undefined
      assert :boids.boid(world, :nobody) == {:error, :not_found}
      assert :boids.update(world, :nobody, %{max_speed: 1}) == {:error, :not_found}
      assert :boids.remove(world, :nobody) == {:error, :not_found}
    end
  end

  describe "remove/2" do
    test "stops the process of a boid, and removes its row" do
      world = world()
      {:ok, id} = :boids.add(world, still())
      {:ok, other} = :boids.add(world, still())
      pid = :boids.whereis(world, id)
      assert :boids.remove(world, id) == :ok
      refute Process.alive?(pid)
      assert :boids.lookup(world, id) == :error
      assert :boids.count(world) == 1
      assert :boids.remove(world, id) == {:error, :not_found}
      assert Process.alive?(:boids.whereis(world, other))
    end

    test "a late leave for a process that stopped does not take the row of a new process" do
      world = world()
      {:ok, :a} = :boids.add(world, still(id: :a))
      first = :boids.whereis(world, :a)
      :ok = :boids.remove(world, :a)
      {:ok, :a} = :boids.add(world, still(id: :a))
      second = :boids.whereis(world, :a)
      # The message of remove/2 for the first process, after the start of the second.
      assert :boids_world.leave(:boids.space(world), :a, first) == :ok
      assert :boids.whereis(world, :a) == second
      assert :boids.remove(world, :a) == :ok
      assert :boids.count(world) == 0
    end

    test "only the process of a boid of join/2 removes it with leave/2" do
      world = world()
      {:ok, space, boid} = :boids.join(world, id: :me, pos: {1, 2})
      assert Task.await(Task.async(fn -> :boids.leave(space, boid) end)) == :ok
      assert :boids.whereis(world, :me) == self()
      assert :boids.leave(space, boid) == :ok
      assert :boids.count(world) == 0
    end

    test "the id is free again" do
      world = world()
      {:ok, :a} = :boids.add(world, still(id: :a))
      :ok = :boids.remove(world, :a)
      assert :boids.add(world, still(id: :a, pos: {5, 5})) == {:ok, :a}
      assert pos(world, :a) == {5, 5}
    end
  end

  describe "update/3" do
    test "changes options of a boid, and its row" do
      world = world()
      {:ok, id} = :boids.add(world, still())

      assert :boids.update(world, id, %{pos: {50, 60}, vel: {1, 0}, group: :b, data: 1, max_speed: 2}) ==
               :ok

      assert {:ok, %{pos: {50, 60}, vel: {1, 0}, group: :b, data: 1}} = :boids.lookup(world, id)
      assert {:ok, %{max_speed: 2, pos: {50, 60}}} = :boids.boid(world, id)
      assert [%{id: ^id}] = :boids.near(world, {50, 60}, 1)
      assert :boids.update(world, id, rules: [wander: 1]) == :ok
      assert {:ok, %{rules: [{:wander, 1, %{}}]}} = :boids.boid(world, id)
    end

    test "refuses a bad option, and changes nothing" do
      world = world()
      {:ok, id} = :boids.add(world, still())

      assert :boids.update(world, id, %{pos: {1, 1}, max_speed: -1}) ==
               {:error, {:bad_option, {:max_speed, -1}}}

      assert :boids.update(world, id, %{id: :other}) == {:error, {:bad_option, {:id, :other}}}
      assert :boids.update(world, id, %{tick: 5}) == {:error, {:bad_option, {:tick, 5}}}
      assert pos(world, id) == {0, 0}
    end
  end

  describe "add_rule/3, delete_rule/3 and which_rules/2" do
    test "change the rules of a boid, from its next step" do
      world = world()
      {:ok, id} = :boids.add(world, still(max_force: 100))
      assert :boids.which_rules(world, id) == {:ok, []}
      assert :boids.add_rule(world, id, {{:seek, :home}, 1, target: {10, 0}}) == :ok
      assert :boids.add_rule(world, id, {{:seek, :food}, 1, %{target: {0, 10}}}) == :ok
      assert :boids.which_rules(world, id) == {:ok, [seek: :home, seek: :food]}
      :boids.step(world, 0.1)
      {x, y} = pos(world, id)
      assert x > 0 and y > 0
      assert :boids.delete_rule(world, id, {:seek, :food}) == :ok
      assert :boids.which_rules(world, id) == {:ok, [seek: :home]}
      assert {:ok, %{rules: [{{:seek, :home}, 1, %{target: {10, 0}}}]}} = :boids.boid(world, id)
      # A boid with no such rule does not change.
      assert :boids.delete_rule(world, id, :wander) == :ok
      assert :boids.which_rules(world, id) == {:ok, [seek: :home]}
    end

    test "a rule of your own is a function, and its name is the function" do
      world = world()
      me = self()

      push = fn boid, neighbors, seen ->
        send(me, {:rule, boid.id, length(neighbors), seen.dt})
        {3, 0}
      end

      {:ok, id} = :boids.add(world, still(id: :a, max_force: 100))
      {:ok, _} = :boids.add(world, still(pos: {1, 1}))
      assert :boids.add_rule(world, id, {push, 2}) == :ok
      assert :boids.which_rules(world, id) == {:ok, [push]}
      :boids.step(world, 0.5)
      assert_received {:rule, :a, 1, 0.5}
      assert_vec(pos(world, id), {1.5, 0.0})
      assert :boids.delete_rule(world, id, push) == :ok
      :boids.step(world, 0.5)
      refute_received {:rule, _, _, _}
    end

    test "give not_found for an id that is not a boid with a process of the library" do
      world = world()
      {:ok, _space, _me} = :boids.join(world, id: :me, pos: {0, 0})

      for id <- [:me, :nobody] do
        assert :boids.add_rule(world, id, {:wander, 1}) == {:error, :not_found}
        assert :boids.delete_rule(world, id, :wander) == {:error, :not_found}
        assert :boids.which_rules(world, id) == {:error, :not_found}
        assert :boids.update(world, id, %{max_speed: 1}) == {:error, :not_found}
        assert :boids.boid(world, id) == {:error, :not_found}
        assert :boids.remove(world, id) == {:error, :not_found}
      end
    end

    test "refuse a bad rule, and change nothing" do
      world = world()
      {:ok, id} = :boids.add(world, still())

      assert :boids.add_rule(world, id, {:seek, 1}) ==
               {:error, {:bad_option, {:rules, {:seek, 1, %{}}}}}

      assert :boids.add_rule(world, id, {:fly, 1}) == {:error, {:bad_option, {:rules, {:fly, 1, %{}}}}}
      assert :boids.which_rules(world, id) == {:ok, []}
    end

    test "the memory of a rule has the name of the rule" do
      world = world()

      {:ok, id} =
        :boids.add(world, still(seed: 1, rules: [{:wander, 1}, {{:wander, :slow}, 1, jitter: 0.1}]))

      :boids.step(world, 0.1)

      assert {:ok, %{memory: %{:wander => {_, _}, {:wander, :slow} => {_, _}} = memory}} =
               :boids.boid(world, id)

      assert map_size(memory) == 2
      :ok = :boids.delete_rule(world, id, :wander)
      assert {:ok, %{memory: only}} = :boids.boid(world, id)
      assert Map.keys(only) == [{:wander, :slow}]
    end
  end

  describe "a boid with no module of yours" do
    @describetag :capture_log

    test "stops at a call or a cast of gen_boid" do
      world = world()
      {:ok, first} = :boids.add(world, still())
      assert {{:bad_call, :hello}, _} = catch_exit(:gen_boid.call(:boids.whereis(world, first), :hello))
      {:ok, second} = :boids.add(world, still())
      second = :boids.whereis(world, second)
      ref = Process.monitor(second)
      :gen_boid.cast(second, :hello)
      assert_receive {:DOWN, ^ref, _, _, {:bad_cast, :hello}}
      assert eventually(fn -> :boids.count(world) == 0 end)
    end
  end

  describe "the relations between the boids" do
    setup do
      world = world()
      for id <- [:a, :b, :c], do: {:ok, ^id} = :boids.add(world, still(id: id))
      %{world: world}
    end

    test "relate/4 adds a relation, and the reads give it in the two directions", %{world: world} do
      assert :boids.relate(world, :a, :follows, :b) == :ok
      assert :boids.relate(world, :c, :follows, :b) == :ok
      # Two boids can have two relations, with different labels.
      assert :boids.relate(world, :a, :fears, :b) == :ok
      # The same relation again changes nothing.
      assert :boids.relate(world, :a, :follows, :b) == :ok
      assert :boids.related(world, :a, :follows) == [:b]
      assert Enum.sort(:boids.related_to(world, :b, :follows)) == [:a, :c]
      assert :boids.related(world, :a, :fears) == [:b]
      assert :boids.related(world, :b, :follows) == []
      assert :boids.related_to(world, :a, :follows) == []
      assert :boids.related(world, :nobody, :follows) == []
      # The space of the world gives the same, with no message.
      assert :boids.related(:boids.space(world), :c, :follows) == [:b]
    end

    test "relations/1 gives the relations as a graph", %{world: world} do
      assert :graph.vertices(:boids.relations(world)) == []
      :ok = :boids.relate(world, :a, :follows, :b)
      :ok = :boids.relate(world, :c, :follows, :b)
      :ok = :boids.relate(world, :a, :fears, :b)
      graph = :boids.relations(world)
      assert Enum.sort(:graph.vertices(graph)) == [:a, :b, :c]
      assert Enum.sort(:graph.edges(graph)) == [{:a, :b, :fears}, {:a, :b, :follows}, {:c, :b, :follows}]
      assert graph |> :graph.in_neighbours(:b) |> Enum.uniq() |> Enum.sort() == [:a, :c]
      assert Enum.uniq(:graph.out_neighbours(graph, :a)) == [:b]
      assert :graph.has_edge(graph, :a, :b)
    end

    test "unrelate/4 removes one relation", %{world: world} do
      :ok = :boids.relate(world, :a, :follows, :b)
      :ok = :boids.relate(world, :c, :follows, :b)
      :ok = :boids.relate(world, :a, :fears, :b)
      assert :boids.unrelate(world, :a, :follows, :b) == :ok
      assert :boids.related(world, :a, :follows) == []
      assert :boids.related_to(world, :b, :follows) == [:c]
      assert :boids.related(world, :a, :fears) == [:b]
      assert Enum.sort(:graph.edges(:boids.relations(world))) == [{:a, :b, :fears}, {:c, :b, :follows}]
      # A relation that the world does not have changes nothing.
      assert :boids.unrelate(world, :a, :follows, :b) == :ok
      assert :boids.unrelate(world, :b, :follows, :nobody) == :ok
      assert :boids.related_to(world, :b, :follows) == [:c]
    end

    test "relate/4 refuses an id that is not in the world", %{world: world} do
      assert :boids.relate(world, :a, :follows, :nobody) == {:error, {:not_found, :nobody}}
      assert :boids.relate(world, :nobody, :follows, :a) == {:error, {:not_found, :nobody}}
      assert :graph.vertices(:boids.relations(world)) == []
      assert :boids.related(world, :a, :follows) == []
    end

    test "a world accepts a cycle of relations", %{world: world} do
      assert :boids.relate(world, :a, :follows, :b) == :ok
      assert :boids.relate(world, :b, :follows, :a) == :ok
      assert :boids.related(world, :b, :follows) == [:a]
    end

    test "a world with the option acyclic refuses a cycle" do
      world = world(relations: :acyclic)
      for id <- [:a, :b, :c], do: {:ok, ^id} = :boids.add(world, still(id: id))
      assert :boids.relate(world, :a, :follows, :b) == :ok
      assert :boids.relate(world, :b, :follows, :c) == :ok
      assert :boids.relate(world, :c, :follows, :a) == {:error, :cycle}
      assert :boids.related(world, :c, :follows) == []
      assert :boids.related_to(world, :a, :follows) == []
      assert :graph.topsort(:boids.relations(world)) == [:a, :b, :c]
    end

    test "the option relations is cyclic or acyclic" do
      assert {:ok, world} = :boids.start_world(relations: :cyclic)
      :boids.stop_world(world)
      assert :boids.start_world(relations: :tree) == {:error, {:bad_option, {:relations, :tree}}}
      assert catch_error(:boids.child_spec(relations: :tree)) == {:bad_option, {:relations, :tree}}
    end

    test "the relations of a boid go when the world removes the boid", %{world: world} do
      :ok = :boids.relate(world, :a, :follows, :b)
      :ok = :boids.relate(world, :b, :follows, :c)
      :ok = :boids.relate(world, :c, :fears, :a)
      assert :boids.remove(world, :b) == :ok
      assert :boids.related(world, :a, :follows) == []
      assert :boids.related_to(world, :c, :follows) == []
      assert :boids.related_to(world, :b, :follows) == []
      assert :boids.related(world, :b, :follows) == []
      # The other relations stay.
      assert :boids.related(world, :c, :fears) == [:a]
      assert :graph.edges(:boids.relations(world)) == [{:c, :a, :fears}]
      assert Enum.sort(:graph.vertices(:boids.relations(world))) == [:a, :c]
    end

    test "the relations of a boid go when its process stops", %{world: world} do
      :ok = :boids.relate(world, :a, :follows, :b)
      :ok = :boids.relate(world, :c, :follows, :a)
      :ok = GenServer.stop(:boids.whereis(world, :a))
      assert eventually(fn -> :boids.count(world) == 2 end)
      assert :boids.related_to(world, :b, :follows) == []
      assert :boids.related(world, :c, :follows) == []
      assert :graph.edges(:boids.relations(world)) == []
    end

    test "a process of yours with join/2 has relations, and they go when it leaves", %{
      world: world
    } do
      {:ok, space, me} = :boids.join(world, id: :me, pos: {1, 1})
      assert :boids.relate(world, :me, :follows, :a) == :ok
      assert :boids.relate(world, :b, :follows, :me) == :ok
      assert :boids.related(world, :me, :follows) == [:a]
      assert :boids.related_to(world, :me, :follows) == [:b]
      assert :boids.leave(space, me) == :ok
      assert :boids.related_to(world, :a, :follows) == []
      assert :boids.related(world, :b, :follows) == []
    end

    test "a rule with the target of a relation uses the related boid", %{world: world} do
      rules = [{:seek, 1, %{target: {:related, :follows}}}]
      :ok = :boids.update(world, :a, %{rules: rules, max_force: 100})
      :ok = :boids.update(world, :b, %{pos: {10, 0}})
      # No relation gives no force.
      :boids.step(world, 0.1)
      assert pos(world, :a) == {0, 0}
      :ok = :boids.relate(world, :a, :follows, :b)
      :boids.step(world, 0.1)
      {x, y} = pos(world, :a)
      assert x > 0 and y == 0
      # A process of yours uses the relation too, with advance/3.
      {:ok, space, me} = :boids.join(world, id: :me, pos: {0, 5}, rules: rules, max_force: 100)
      :ok = :boids.relate(world, :me, :follows, :c)
      :ok = :boids.update(world, :c, %{pos: {0, 20}})
      %{pos: {mx, my}} = :boids.advance(space, me, 0.1)
      assert mx == 0 and my > 5
    end
  end

  describe "flocks/2" do
    test "gives the groups of boids that see each other" do
      world = world()
      assert :boids.flocks(world, 5) == []
      {:ok, :a} = :boids.add(world, still(id: :a))
      {:ok, :b} = :boids.add(world, still(id: :b, pos: {3, 0}))
      {:ok, :c} = :boids.add(world, still(id: :c, pos: {6, 0}))
      {:ok, :d} = :boids.add(world, still(id: :d, pos: {50, 50}))
      # A chain of boids is one flock: a sees b, and b sees c.
      flocks = :boids.flocks(world, 5) |> Enum.map(&Enum.sort/1) |> Enum.sort()
      assert flocks == [[:a, :b, :c], [:d]]
      # A boid sees no other boid at a small radius, and all at a large one.
      assert length(:boids.flocks(world, 1)) == 4
      assert [[_, _, _, _]] = :boids.flocks(:boids.space(world), 100)
    end
  end

  describe "graph/2" do
    test "gives the boids that see each other as a graph" do
      world = world()
      {:ok, :a} = :boids.add(world, still(id: :a))
      {:ok, :b} = :boids.add(world, still(id: :b, pos: {3, 0}))
      {:ok, :c} = :boids.add(world, still(id: :c, pos: {50, 50}))
      graph = :boids.graph(world, 5)
      assert Enum.sort(:graph.vertices(graph)) == [:a, :b, :c]
      # The label of a boid is its row.
      assert :graph.vertex(graph, :b) == elem(:boids.lookup(world, :b), 1)
      assert :graph.has_edge(graph, :a, :b)
      assert :graph.has_edge(graph, :b, :a)
      assert :graph.no_edges(graph) == 2
      assert :graph.out_degree(graph, :c) == 0
      groups = graph |> :graph.components() |> Enum.map(&Enum.sort/1) |> Enum.sort()
      assert groups == [[:a, :b], [:c]]
      # With a large radius, each boid sees each other boid.
      all = :boids.graph(:boids.space(world), 100)
      assert :graph.no_edges(all) == 6
      assert [[_, _, _]] = :graph.components(all)
    end

    test "an empty world gives an empty graph" do
      assert :graph.vertices(:boids.graph(world(), 10)) == []
    end
  end

  describe "the process of a boid" do
    @tag :capture_log
    test "a boid that stops with an error goes from the world, and the other boids continue" do
      world = world()
      {:ok, :a} = :boids.add(world, still(id: :a, pos: {1, 1}))
      {:ok, other} = :boids.add(world, still())
      Process.exit(:boids.whereis(world, :a), :kill)
      assert eventually(fn -> :boids.whereis(world, :a) == :undefined end)
      assert :boids.count(world) == 1
      assert Process.alive?(:boids.whereis(world, other))
      # The id is free for a new boid.
      assert :boids.add(world, still(id: :a)) == {:ok, :a}
    end

    @tag :capture_log
    test "a boid with an error at each step does not stop the world" do
      world = world()
      {:ok, good} = :boids.populate(world, 20, area: @box, tick: 5)
      bad = fn _boid, _neighbors, _seen -> raise "a fault of a rule" end
      for _ <- 1..15, do: {:ok, _} = :boids.add(world, pos: {1, 1}, rules: [{bad, 1}], tick: 5)
      assert eventually(fn -> :boids.count(world) == 20 end)
      assert Process.alive?(world)
      assert Enum.all?(good, &Process.alive?(:boids.whereis(world, &1)))
      assert Enum.sort(Enum.map(:boids.snapshot(world), & &1.id)) == Enum.sort(good)
    end

    @tag :capture_log
    test "the end of the process of a world stops all the world" do
      {:ok, world} = :boids.start_world()
      {:ok, id} = :boids.add(world, still())
      pid = :boids.whereis(world, id)
      sup = :boids_world.sup(world)
      Process.exit(world, :kill)
      assert eventually(fn -> not Process.alive?(sup) end)
      refute Process.alive?(pid)
      assert :boids.stop_world(world) == {:error, :not_found}
    end

    test "a boid whose process stopped is not found" do
      world = world()
      {:ok, id} = :boids.add(world, still())
      space = :boids.space(world)
      # The world does not see the end of the process before the call.
      pid = :boids.whereis(world, id)
      :sys.suspend(world)
      ref = Process.monitor(pid)
      :ok = GenServer.stop(pid)
      assert_receive {:DOWN, ^ref, _, _, _}
      assert :boids.boid(space, id) == {:error, :not_found}
      assert :boids.update(space, id, %{max_speed: 1}) == {:error, :not_found}
      :sys.resume(world)
      assert eventually(fn -> :boids.count(world) == 0 end)
    end

    test "the world removes a boid whose process stops" do
      world = world()
      {:ok, id} = :boids.add(world, still())
      :ok = GenServer.stop(:boids.whereis(world, id))
      assert eventually(fn -> :boids.count(world) == 0 end)
      assert :boids.lookup(world, id) == :error
      assert :boids.near(world, {0, 0}, 5) == []
    end

    test "other messages change nothing" do
      world = world()
      {:ok, id} = :boids.add(world, still())
      send(:boids.whereis(world, id), :hello)
      GenServer.cast(:boids.whereis(world, id), :hello)
      send(world, :hello)
      send(world, {:DOWN, make_ref(), :process, self(), :normal})
      GenServer.cast(world, :hello)
      assert {:ok, %{pos: {0, 0}}} = :boids.boid(world, id)
      assert :boids.count(world) == 1
    end
  end

  describe "a boid below a supervisor of yours" do
    @describetag :capture_log

    setup do
      name = :"boids_test_own_#{System.unique_integer([:positive])}"

      children = [
        {:boids, name: name, defaults: %{tick: :manual, rules: []}},
        {:gen_boid, {name, Mouse, [id: :hawk, pos: {1, 1}, vel: {1, 0}]}}
      ]

      start = {Supervisor, :start_link, [children, [strategy: :rest_for_one]]}
      sup = start_supervised!(%{id: :own, start: start, type: :supervisor})
      %{world: name, sup: sup}
    end

    test "is a boid of the world, with the defaults of the world", %{world: world} do
      assert {:ok, %{id: :hawk, pos: {1, 1}, rules: []}} = :boids.boid(world, :hawk)
      assert :boids.update(world, :hawk, %{max_speed: 3}) == :ok
      :boids.step(world, 1)
      assert pos(world, :hawk) == {2.0, 1.0}
    end

    test "starts again with its id after an error", %{world: world} do
      first = :boids.whereis(world, :hawk)
      :boids.step(world, 1)
      Process.exit(first, :kill)
      assert eventually(fn -> :boids.whereis(world, :hawk) not in [:undefined, first] end)
      assert pos(world, :hawk) == {1, 1}
      assert :boids.count(world) == 1
    end

    test "finds its world again when the world starts again", %{world: world} do
      first = :boids.whereis(world, :hawk)
      Process.exit(Process.whereis(world), :kill)

      # The supervisor starts the world again, then the boid.
      again = fn ->
        try do
          :boids.whereis(world, :hawk) not in [:undefined, first]
        catch
          :exit, _ -> false
        end
      end

      assert eventually(again)
    end

    test "boids:remove/2 does not stop it", %{world: world} do
      assert :boids.remove(world, :hawk) == {:error, :not_found}
      assert Process.alive?(:boids.whereis(world, :hawk))
      {:ok, other} = :boids.add(world, pos: {5, 5})
      assert :boids.remove(world, other) == :ok
      assert :boids.count(world) == 1
    end

    test "the specification of the child has the module and its arguments" do
      assert :gen_boid.child_spec({:f, Mouse, %{id: :hawk}}) == %{
               id: {:gen_boid, Mouse, %{id: :hawk}},
               start: {:gen_boid, :start_link, [:f, Mouse, %{id: :hawk}, %{}]}
             }

      assert :gen_boid.child_spec({:f, Mouse, %{id: :hawk}, name: :hawk}) == %{
               id: {:gen_boid, Mouse, %{id: :hawk}},
               start: {:gen_boid, :start_link, [:f, Mouse, %{id: :hawk}, [name: :hawk]]}
             }
    end

    test "start_link/3 refuses a bad option and an id of the world", %{world: world} do
      Process.flag(:trap_exit, true)
      start = fn options -> :gen_boid.start_link(world, Mouse, options) end
      assert start.(pos: {0, 0}, mass: 0) == {:error, {:shutdown, {:bad_option, {:mass, 0}}}}
      assert start.(:bird) == {:error, {:shutdown, {:bad_option, :bird}}}
      assert start.(id: :hawk, pos: {0, 0}) == {:error, {:shutdown, {:exists, :hawk}}}
      assert {:ok, pid} = start.(id: :mouse, pos: {0, 0})
      assert :boids.whereis(world, :mouse) == pid
    end
  end

  describe "the clock of a boid" do
    test "a boid moves in real time" do
      world = world()
      {:ok, id} = :boids.add(world, pos: {0, 0}, vel: {10, 0}, rules: [], tick: 5)
      Process.sleep(200)
      {x, y} = pos(world, id)
      # 2 units in 200 ms. The limits accept a slow computer.
      assert x > 1.0 and x < 10.0
      assert y == 0.0
      later = eventually(fn -> elem(pos(world, id), 0) > x end)
      assert later
    end

    test "with a manual tick, a boid moves only with step/2" do
      world = world()
      {:ok, id} = :boids.add(world, still(vel: {10, 0}))
      Process.sleep(50)
      assert pos(world, id) == {0, 0}
    end

    test "the scale of the time makes the boids slow, fast or stopped" do
      world = world()
      assert :boids.set_time_scale(world, 0) == :ok
      {:ok, id} = :boids.add(world, pos: {0, 0}, vel: {1, 0}, rules: [], tick: 5)
      Process.sleep(50)
      assert pos(world, id) == {0, 0}
      assert :boids.set_time_scale(world, 100) == :ok
      # 100 units for each second of the clock.
      assert eventually(fn -> elem(pos(world, id), 0) > 5.0 end)
    end

    test "a step has the maximum time at most" do
      world = world()
      {:ok, id} = :boids.add(world, pos: {0, 0}, vel: {10, 0}, rules: [], tick: 20, max_dt: 0.001)
      Process.sleep(200)
      {x, _} = pos(world, id)
      # 10 ticks of 0.01 unit at most, and not 2 units.
      assert x > 0.0 and x < 0.5
    end

    test "a boid hibernates between two steps" do
      world = world()

      sleeps? = &hibernates?(:boids.whereis(world, &1))

      {:ok, timed} = :boids.add(world, pos: {0, 0}, vel: {1, 0}, rules: [], tick: 20)
      assert eventually(fn -> sleeps?.(timed) end)
      before = pos(world, timed)
      assert eventually(fn -> pos(world, timed) != before end)
      {:ok, manual} = :boids.add(world, still())
      refute sleeps?.(manual)
      :boids.step(world, 0.1)
      assert eventually(fn -> sleeps?.(manual) end)
      # A boid that hibernates answers.
      assert {:ok, %{id: ^manual}} = :boids.boid(world, manual)
    end

    test "without hibernate, a boid keeps its heap" do
      world = world()

      sleeps? = &hibernates?(:boids.whereis(world, &1))

      {:ok, timed} = :boids.add(world, pos: {0, 0}, vel: {1, 0}, rules: [], tick: 5, hibernate: false)
      {:ok, manual} = :boids.add(world, still(hibernate: false))
      assert eventually(fn -> pos(world, timed) != {0, 0} end)
      :boids.step(world, 0.1)
      refute sleeps?.(timed)
      refute sleeps?.(manual)
    end

    test "a boid whose tick comes late waits longer before its next tick" do
      world = world()
      {:ok, id} = :boids.add(world, pos: {0, 0}, vel: {10, 0}, rules: [], tick: 10)
      # The tick comes 100 ms late, as with processors that have too much work.
      pid = :boids.whereis(world, id)
      :erlang.suspend_process(pid)
      Process.sleep(110)
      late = pos(world, id)
      :erlang.resume_process(pid)
      assert eventually(fn -> pos(world, id) != late end)
      # The boid waits 8 times the delay more: about 0.7 second.
      moved = pos(world, id)
      Process.sleep(300)
      assert pos(world, id) == moved
      assert eventually(fn -> pos(world, id) != moved end)
      # Then the ticks come at the usual time again.
      again = pos(world, id)
      Process.sleep(200)
      assert elem(pos(world, id), 0) - elem(again, 0) > 0.5
    end

    test "the maximum time of a step is 0.25 second, or 4 ticks" do
      assert {%{tick: 50, max_dt: 0.25, search: 1, priority: :low, hibernate: true}, %{}} =
               :gen_boid.options(%{})

      assert {%{max_dt: 0.25}, _} = :gen_boid.options(%{tick: :manual})
      assert {%{max_dt: 0.25}, _} = :gen_boid.options(%{tick: 20})
      assert {%{max_dt: 4.0}, %{pos: {0, 0}}} = :gen_boid.options(%{tick: 1000, pos: {0, 0}})
      assert {%{max_dt: 0.1}, _} = :gen_boid.options(%{tick: 1000, max_dt: 0.1})
    end

    test "a seed gives the same random numbers" do
      world = world()
      rules = [wander: 1]
      {:ok, a} = :boids.add(world, still(seed: 42, rules: rules, id: :a))
      {:ok, b} = :boids.add(world, still(seed: 42, rules: rules, id: :b, pos: {50, 50}))
      {:ok, c} = :boids.add(world, still(seed: 43, rules: rules, id: :c, pos: {90, 90}))
      for _ <- 1..10, do: :boids.step(world, 0.1)
      assert_vec(:boids_vec.sub(pos(world, b), {50, 50}), pos(world, a))
      refute :boids_vec.sub(pos(world, c), {90, 90}) == pos(world, a)
    end
  end

  describe "step/2" do
    test "moves each boid for the time of the step" do
      world = world()
      {:ok, a} = :boids.add(world, still(vel: {1, 0}))
      {:ok, b} = :boids.add(world, still(pos: {5, 5}, vel: {0, -2}))
      assert :boids.step(world, 0.5) == :ok
      assert pos(world, a) == {0.5, 0.0}
      assert pos(world, b) == {5.0, 4.0}
      assert {:ok, %{pos: {0.5, +0.0}}} = :boids.boid(world, a)
      assert :boids.step(world, 0) == :ok
      assert pos(world, a) == {0.5, 0.0}
    end

    test "each boid calculates its step before a boid moves" do
      world = world()
      me = self()

      rule = fn boid, neighbors, _seen ->
        send(me, {boid.id, Enum.map(neighbors, & &1.pos)})
        {0, 0}
      end

      for {id, x} <- [a: 0, b: 1, c: 2],
          do: {:ok, _} = :boids.add(world, still(id: id, pos: {x, 0}, vel: {1, 0}, rules: [{rule, 1}]))

      :boids.step(world, 1)
      assert_received {:a, [{1, 0}, {2, 0}]}
      assert_received {:b, [{0, 0}, {2, 0}]}
      assert_received {:c, [{1, 0}, {0, 0}]}
      assert pos(world, :a) == {1.0, 0.0}
      :boids.step(world, 1)
      assert_received {:c, [{2.0, +0.0}, {1.0, +0.0}]}
    end

    test "uses the scale of the time" do
      world = world()
      {:ok, a} = :boids.add(world, still(vel: {1, 0}))
      :boids.set_time_scale(world, 10)
      :boids.step(world, 0.5)
      assert pos(world, a) == {5.0, 0.0}
      :boids.set_time_scale(world, 0)
      :boids.step(world, 0.5)
      assert pos(world, a) == {5.0, 0.0}
    end

    test "a step does not change the clock of a boid" do
      world = world()
      {:ok, id} = :boids.add(world, still(vel: {1, 0}))
      pid = :boids.whereis(world, id)
      %{last: last} = :sys.get_state(pid)
      Process.sleep(5)
      :boids.step(world, 0.5)
      assert %{last: ^last, pending: :undefined} = :sys.get_state(pid)
    end

    test "a commit with no plan changes nothing" do
      world = world()
      {:ok, id} = :boids.add(world, still(vel: {1, 0}))
      pid = :boids.whereis(world, id)
      assert GenServer.call(pid, :commit) == :ok
      assert pos(world, id) == {0, 0}
      # An update removes the plan.
      assert GenServer.call(pid, {:plan, 1}) == :ok
      :ok = :boids.update(world, id, %{pos: {7, 7}})
      assert GenServer.call(pid, :commit) == :ok
      assert pos(world, id) == {7, 7}
    end

    test "refuses a bad time" do
      world = world()
      assert_raise FunctionClauseError, fn -> :boids.step(world, -1) end
      assert_raise FunctionClauseError, fn -> :boids.step(world, :long) end
    end

    test "with a seed for each boid, two runs give the same result" do
      run = fn ->
        {:ok, world} = :boids.start_world(bounds: {{0, 0}, {60, 60}}, wrap: true)
        rules = [separation: 1.5, alignment: 1.0, cohesion: 1.0, wander: 0.5]

        for n <- 1..40 do
          pos = {rem(n * 17, 60), rem(n * 29, 60)}
          vel = {rem(n, 7) - 3, rem(n, 5) - 2}
          {:ok, ^n} = :boids.add(world, id: n, pos: pos, vel: vel, rules: rules, tick: :manual, seed: n)
        end

        for _ <- 1..60, do: :boids.step(world, 0.05)
        rows = Enum.sort_by(:boids.snapshot(world), & &1.id)
        :ok = :boids.stop_world(world)
        Enum.map(rows, &Map.take(&1, [:id, :pos, :vel]))
      end

      first = run.()
      assert first == run.()
      assert length(first) == 40
    end

    test "two runs with the same seeds give snapshot/1 in the same order" do
      # The ids are references: they are not the same in two runs.
      run = fn ->
        :rand.seed(:exsss, 7)
        {:ok, world} = :boids.start_world(bounds: {{0, 0}, {60, 60}}, wrap: true)
        rules = [separation: 1.5, alignment: 1.0, cohesion: 1.0, wander: 0.5]
        {:ok, ids} = :boids.populate(world, 40, rules: rules, tick: :manual, seed: 1)
        assert Enum.all?(ids, &is_reference/1)
        assert Enum.map(:boids.snapshot(world), & &1.id) == ids
        for _ <- 1..30, do: :boids.step(world, 0.05)
        # A boid goes, and a boid comes: the other boids keep their places.
        gone = Enum.at(ids, 10)
        :ok = :boids.remove(world, gone)
        {:ok, new} = :boids.add(world, pos: {30, 30}, vel: {1, 0}, rules: rules, tick: :manual, seed: 99)
        for _ <- 1..30, do: :boids.step(world, 0.05)
        rows = :boids.snapshot(world)
        assert Enum.map(rows, & &1.id) == List.delete(ids, gone) ++ [new]
        assert :boids.snapshot(world, :local) == rows
        :ok = :boids.stop_world(world)
        Enum.map(rows, &Map.take(&1, [:pos, :vel]))
      end

      first = run.()
      assert first == run.()
      assert length(Enum.uniq(first)) == 40
    end
  end

  describe "populate/3" do
    test "adds boids at random positions of the box of the world" do
      world = world(bounds: {{10, 20}, {30, 50}})
      {:ok, ids} = :boids.populate(world, 30, %{tick: :manual, min_speed: 2, max_speed: 5})
      assert length(Enum.uniq(ids)) == 30
      assert :boids.count(world) == 30

      for %{pos: {x, y}, vel: vel} <- :boids.snapshot(world) do
        assert x >= 10 and x <= 30 and y >= 20 and y <= 50
        speed = :boids_vec.norm(vel)
        assert speed >= 2 - 1.0e-9 and speed <= 5 + 1.0e-9
      end

      positions = Enum.uniq(Enum.map(:boids.snapshot(world), & &1.pos))
      assert length(positions) == 30
    end

    test "uses an area, in two or three dimensions" do
      world = world()
      {:ok, _} = :boids.populate(world, 10, tick: :manual, area: {{0, 0, 0}, {1, 2, 3}}, vel: {0, 0, 1})

      for %{pos: {x, y, z}, vel: vel} <- :boids.snapshot(world) do
        assert x >= 0 and x <= 1 and y >= 0 and y <= 2 and z >= 0 and z <= 3
        assert vel == {0, 0, 1}
      end
    end

    test "the area comes before the box of the world" do
      world = world(bounds: @box)
      {:ok, [id]} = :boids.populate(world, 1, tick: :manual, area: {{200, 200}, {201, 201}})
      {x, y} = pos(world, id)
      assert x >= 200 and y >= 200
    end

    test "no boid" do
      world = world(bounds: @box)
      assert :boids.populate(world, 0, %{}) == {:ok, []}
    end

    test "gives new ids, and a seed to each boid" do
      world = world(bounds: @box)
      {:ok, [a, b]} = :boids.populate(world, 2, id: :same, tick: :manual, seed: 5, rules: [wander: 1])
      assert a != b
      :boids.step(world, 0.1)
      {:ok, %{memory: %{wander: first}}} = :boids.boid(world, a)
      {:ok, %{memory: %{wander: second}}} = :boids.boid(world, b)
      assert first != second
    end

    test "the boid number N has the seed plus N" do
      world = world(bounds: @box, defaults: %{tick: :manual, rules: [wander: 1]})
      {:ok, [first, second]} = :boids.populate(world, 2, seed: 100)
      {:ok, one} = :boids.add(world, pos: {1, 1}, seed: 101)
      {:ok, two} = :boids.add(world, pos: {1, 1}, seed: 102)
      :boids.step(world, 0.1)
      point = fn id -> elem(:boids.boid(world, id), 1).memory.wander end
      assert point.(first) == point.(one)
      assert point.(second) == point.(two)
      assert point.(first) != point.(second)
    end

    test "refuses a bad option" do
      world = world()
      assert :boids.populate(world, 3, %{}) == {:error, {:bad_option, {:area, :undefined}}}

      assert :boids.populate(world, 3, area: {{0, 0}, {1, 1, 1}}) ==
               {:error, {:bad_option, {:area, {{0, 0}, {1, 1, 1}}}}}

      assert :boids.populate(world, 3, area: {{0}, {1}}) == {:error, {:bad_option, {:area, {{0}, {1}}}}}
      assert :boids.populate(world, 3, area: @box, mass: 0) == {:error, {:bad_option, {:mass, 0}}}
      assert :boids.populate(world, 3, area: @box, tick: -1) == {:error, {:bad_option, {:tick, -1}}}
      assert :boids.populate(world, 3, :many) == {:error, {:bad_option, :many}}
      assert :boids.count(world) == 0
      assert_raise FunctionClauseError, fn -> :boids.populate(world, -1, area: @box) end
    end
  end

  describe "the grids" do
    test "set_grid/3, grid/2 and remove_grid/2" do
      world = world()
      grid = :boids_grid.from_rows(["..#", "..."], [])
      assert :boids.grid(world, :land) == :error
      assert :boids.set_grid(world, :land, grid) == :ok
      assert :boids.grid(world, :land) == {:ok, grid}
      door = :boids_grid.set_cost(grid, [{2, 0}], 1)
      assert :boids.set_grid(:boids.space(world), :land, door) == :ok
      assert :boids.grid(:boids.space(world), :land) == {:ok, door}
      assert :boids.remove_grid(world, :land) == :ok
      assert :boids.grid(world, :land) == :error
      # A grid that is not there: nothing to remove.
      assert :boids.remove_grid(world, :land) == :ok
    end

    test "the process of the world writes the grids, and a bad grid is an error of the caller" do
      world = world()
      grid = :boids_grid.new(size: {2, 2})
      assert :boids_world.set(world, {:grid, :land}, grid) == :ok
      assert :boids.grid(world, :land) == {:ok, grid}
      assert :boids_world.set(world, {:grid, :land}, :walls) == {:error, :badarg}
      assert_raise ArgumentError, fn -> :boids.set_grid(world, :land, [{0, 0}]) end
      assert Process.alive?(world)
      assert :boids.grid(world, :land) == {:ok, grid}
      assert :boids_world.set(world, {:grid, :land}, :none) == :ok
      assert :boids.grid(world, :land) == :error
    end
  end

  describe "the obstacles" do
    test "set_obstacle/4, obstacles/1 and remove_obstacle/2" do
      world = world()
      assert :boids.obstacles(world) == []
      assert :boids.set_obstacle(world, :rock, {5, 5}, 2) == :ok
      assert :boids.obstacles(world) == [%{id: :rock, pos: {5, 5}, radius: 2}]
      assert :boids.set_obstacle(:boids.space(world), :rock, {6, 5}, 2) == :ok
      assert :boids.obstacles(world) == [%{id: :rock, pos: {6, 5}, radius: 2}]
      assert :boids.remove_obstacle(world, :rock) == :ok
      assert :boids.obstacles(world) == []
    end

    test "the process of the world writes the facts of the world, one change after the other" do
      world = world(cell_size: 1)
      space = :boids.space(world)
      # Only the process of the world can write these tables.
      assert :ets.info(space.facts, :protection) == :protected
      assert :ets.info(space.obstacle_cells, :protection) == :protected
      assert :boids_world.set(world, :time_scale, 2) == :ok
      assert :boids_world.set(space, {:obstacle, :rock}, {{5, 5}, 1}) == :ok
      assert %{time_scale: 2, obstacles: [%{id: :rock, pos: {5, 5}, radius: 1}]} = :boids_space.env(space)
      assert :boids_world.set(world, {:obstacle, :rock}, :none) == :ok
      assert :boids.obstacles(world) == []

      # Many processes move one obstacle at the same time. The world
      # makes one change after the other: the index has only the cells
      # of the last row.
      tasks =
        for n <- 1..8 do
          Task.async(fn ->
            for step <- 1..200, do: :ok = :boids.set_obstacle(world, :rock, {n * 10.5, step * 1.0}, 0.4)
          end)
        end

      Task.await_many(tasks)
      assert [%{id: :rock, pos: {x, y}}] = :boids.obstacles(world)
      index = :ets.tab2list(space.obstacle_cells)

      # The cells of a size that the rock touches.
      touched = fn size ->
        for i <- floor((x - 0.4) / size)..floor((x + 0.4) / size),
            j <- floor((y - 0.4) / size)..floor((y + 0.4) / size),
            do: {i, j}
      end

      assert Enum.sort(for {cell, :rock} <- index, not match?({:coarse, _}, cell), do: cell) == touched.(1)
      assert Enum.sort(for {{:coarse, cell}, :rock} <- index, do: cell) == touched.(8)

      assert [%{id: :rock}] = :boids_space.obstacles(space, {x, y}, 0)
    end

    test "a bad value of a fact is an error of the caller, and the world continues" do
      world = world()
      assert_raise ArgumentError, fn -> :boids.set_time_scale(world, -1) end
      assert_raise ArgumentError, fn -> :boids.set_time_scale(world, :fast) end
      assert_raise ArgumentError, fn -> :boids.set_obstacle(world, :rock, {1, 2}, -1) end
      assert :boids_world.set(world, {:obstacle, :rock}, :there) == {:error, :badarg}
      assert :boids_world.set(world, :weather, :rain) == {:error, :badarg}
      assert Process.alive?(world)
      assert :boids.obstacles(world) == []
      assert :boids_space.env(:boids.space(world)).time_scale == 1.0
    end

    test "a read finds an obstacle one time while the process of the world moves it" do
      world = world(cell_size: 1)
      space = :boids.space(world)
      # Many obstacles far away: a read uses the cells.
      for id <- 1..100, do: :ok = :boids.set_obstacle(world, id, {id * 1.0, -20.0}, 0.4)
      :ok = :boids.set_obstacle(world, :rock, {0.5, 0.5}, 0.4)

      mover =
        spawn_link(fn ->
          Stream.cycle([{0.5, 0.5}, {3.5, 0.5}, {3.5, 3.5}, {0.5, 3.5}])
          |> Enum.each(fn pos -> :ok = :boids.set_obstacle(world, :rock, pos, 0.4) end)
        end)

      # This process reads with no message, as a boid does.
      results =
        for _ <- 1..20_000, do: Enum.count(:boids_space.obstacles(space, {2, 2}, 3), &(&1.id == :rock))

      Process.unlink(mover)
      Process.exit(mover, :kill)
      assert Enum.frequencies(results) == %{1 => 20_000}
    end

    test "a boid with the rule avoid moves around an obstacle" do
      world = world()
      :boids.set_obstacle(world, :rock, {30, 0}, 5)
      rules = [{:avoid, 3, lookahead: 2}, {:seek, 1, target: {60, 0.5}}]

      {:ok, id} =
        :boids.add(world, still(pos: {0, 0.5}, vel: {10, 0}, rules: rules, combine: :priority))

      nearest =
        Enum.reduce(1..200, 1.0e9, fn _, nearest ->
          :boids.step(world, 0.05)
          min(nearest, :boids_vec.dist(pos(world, id), {30, 0}))
        end)

      assert nearest > 5.0
      assert :boids_vec.dist(pos(world, id), {60, 0.5}) < 10
    end

    test "a boid without the rule goes through the obstacle" do
      world = world()
      :boids.set_obstacle(world, :rock, {30, 0}, 5)

      {:ok, id} =
        :boids.add(world, still(pos: {0, 0.5}, vel: {10, 0}, rules: [{:seek, 1, target: {60, 0.5}}]))

      nearest =
        Enum.reduce(1..200, 1.0e9, fn _, nearest ->
          :boids.step(world, 0.05)
          min(nearest, :boids_vec.dist(pos(world, id), {30, 0}))
        end)

      assert nearest < 1.0
    end
  end

  describe "a world" do
    # Boids at fixed positions, so that each run is the same.
    defp scatter(world, count, size, opts) do
      for n <- 1..count do
        pos = {rem(n * 37, size) + rem(n, 3) / 4, rem(n * 61, size) + rem(n, 5) / 6}
        angle = n * 2.399963
        vel = {4 * :math.cos(angle), 4 * :math.sin(angle)}

        {:ok, ^n} =
          :boids.add(
            world,
            Map.merge(%{id: n, pos: pos, vel: vel, tick: :manual, seed: n}, Map.new(opts))
          )
      end
    end

    test "with alignment, the boids move in one direction" do
      world = world(bounds: {{0, 0}, {50, 50}}, wrap: true)
      scatter(world, 50, 50, min_speed: 3)
      assert order(:boids.snapshot(world)) < 0.3
      for _ <- 1..400, do: :boids.step(world, 0.05)
      assert order(:boids.snapshot(world)) > 0.9
    end

    test "without alignment, the boids do not move in one direction" do
      world = world(bounds: {{0, 0}, {50, 50}}, wrap: true)
      scatter(world, 50, 50, min_speed: 3, rules: [separation: 1.5, wander: 1.0])
      for _ <- 1..400, do: :boids.step(world, 0.05)
      assert order(:boids.snapshot(world)) < 0.5
    end

    test "with separation, the boids keep a distance" do
      world = world()
      scatter(world, 30, 6, rules: [separation: 1.0], vel: {0, 0})

      nearest = fn ->
        Enum.min(for a <- :boids.snapshot(world), [_, b | _] = :boids.near(world, a.pos, 100), do: b.dist)
      end

      assert nearest.() < 0.5
      for _ <- 1..200, do: :boids.step(world, 0.05)
      assert nearest.() > 2.0
    end

    test "with cohesion, the boids come together" do
      world = world()
      scatter(world, 30, 40, rules: [cohesion: 1.0], perception: 100, vel: {0, 0})

      spread = fn ->
        rows = :boids.snapshot(world)
        center = :boids_vec.scale(Enum.reduce(rows, {0, 0}, &:boids_vec.add(&1.pos, &2)), 1 / length(rows))
        Enum.sum(for row <- rows, do: :boids_vec.dist(row.pos, center)) / length(rows)
      end

      before = spread.()
      for _ <- 1..100, do: :boids.step(world, 0.05)
      assert spread.() < before / 3
    end

    test "with contain, the boids stay in the box" do
      # The boids start 5 units or more from the sides.
      world = world(bounds: {{-5, -5}, {45, 45}})
      scatter(world, 30, 40, rules: [contain: 3.0, wander: 1.0], min_speed: 5, max_force: 40)

      for _ <- 1..400 do
        :boids.step(world, 0.05)

        for %{pos: {x, y}} <- :boids.snapshot(world),
            do: assert(x > -5 and x < 45 and y > -5 and y < 45)
      end
    end

    test "without contain, the boids go out of the box" do
      world = world(bounds: {{-5, -5}, {45, 45}})
      scatter(world, 30, 40, rules: [wander: 1.0], min_speed: 5, max_force: 40)
      for _ <- 1..400, do: :boids.step(world, 0.05)

      assert Enum.any?(:boids.snapshot(world), fn %{pos: {x, y}} ->
               x < -5 or x > 45 or y < -5 or y > 45
             end)
    end

    test "with wrap, the boids stay in the box" do
      world = world(bounds: {{0, 0}, {40, 40}}, wrap: true)
      scatter(world, 30, 40, min_speed: 5)

      for _ <- 1..200 do
        :boids.step(world, 0.05)

        for %{pos: {x, y}} <- :boids.snapshot(world),
            do: assert(x >= 0 and x < 40 and y >= 0 and y < 40)
      end
    end

    test "a boid pursues a boid of another group, which flees" do
      world = world()

      {:ok, :cat} =
        :boids.add(
          world,
          still(
            id: :cat,
            group: :cats,
            max_speed: 10,
            perception: 50,
            rules: [{:pursue, 1, target: {:group, :mice}}]
          )
        )

      mouse = [{:flee, 1, target: {:group, :cats}, radius: 15}]

      {:ok, :mouse} =
        :boids.add(
          world,
          still(id: :mouse, group: :mice, pos: {20, 0}, max_speed: 4, perception: 50, rules: mouse)
        )

      :boids.step(world, 0.05)
      # The cat is too far: the mouse does not move.
      assert pos(world, :mouse) == {20, 0}
      for _ <- 1..40, do: :boids.step(world, 0.05)
      {x, _} = pos(world, :mouse)
      assert x > 20
      for _ <- 1..100, do: :boids.step(world, 0.05)
      assert :boids_vec.dist(pos(world, :cat), pos(world, :mouse)) < 1.0
    end

    test "boids in three dimensions" do
      world = world(bounds: {{0, 0, 0}, {30, 30, 30}}, wrap: true)
      {:ok, ids} = :boids.populate(world, 40, tick: :manual, seed: 1, min_speed: 3)
      for _ <- 1..100, do: :boids.step(world, 0.05)

      for %{pos: {x, y, z}, vel: vel} <- :boids.snapshot(world) do
        assert x >= 0 and x < 30 and y >= 0 and y < 30 and z >= 0 and z < 30
        assert :boids_vec.norm(vel) <= 10.0 + 1.0e-9
      end

      assert length(ids) == 40
    end
  end

  describe "a process of yours as a boid" do
    test "join/2 adds the process to the world" do
      world = world(defaults: %{max_speed: 3, tick: :manual, seed: 1})
      assert {:ok, space, boid} = :boids.join(world, pos: {1, 2}, vel: {1, 0}, rules: [])
      assert space == :boids.space(world)
      assert %{id: id, pos: {1, 2}, max_speed: 3} = boid
      assert id == self()

      assert :boids.lookup(world, self()) ==
               {:ok, %{id: self(), pos: {1, 2}, vel: {1, 0}, group: :default, data: :undefined, pid: self()}}

      assert :boids.whereis(world, self()) == self()
    end

    test "plan/3 calculates a step, and commit/2 writes it" do
      world = world()
      {:ok, space, boid} = :boids.join(world, id: :me, pos: {1, 2}, vel: {2, 0}, rules: [])
      planned = :boids.plan(space, boid, 0.5)
      assert planned.pos == {2.0, 2.0}
      assert pos(world, :me) == {1, 2}
      assert :boids.commit(space, planned) == :ok
      assert pos(world, :me) == {2.0, 2.0}
    end

    test "advance/3 makes a step, with the scale of the time" do
      world = world()
      {:ok, space, boid} = :boids.join(world, id: :me, pos: {1, 2}, vel: {2, 0}, rules: [])
      boid = :boids.advance(space, boid, 0.5)
      assert boid.pos == {2.0, 2.0}
      assert pos(world, :me) == {2.0, 2.0}
      :boids.set_time_scale(world, 2)
      assert :boids.advance(space, boid, 0.5).pos == {4.0, 2.0}
    end

    test "a change of the boid goes to the world with commit/2" do
      world = world()
      {:ok, space, boid} = :boids.join(world, id: :me, pos: {1, 2})
      changed = :boids_boid.update(boid, %{group: :leaders, data: :gold, pos: {40, 40}})
      :ok = :boids.commit(space, changed)
      assert {:ok, %{group: :leaders, data: :gold, pos: {40, 40}}} = :boids.lookup(world, :me)
    end

    test "leave/2 removes the boid" do
      world = world()
      {:ok, space, boid} = :boids.join(world, pos: {1, 2})
      assert :boids.leave(space, boid) == :ok
      assert :boids.count(world) == 0
      assert :boids.leave(space, boid) == :ok
      # After leave/2, a commit adds no row.
      assert :boids.commit(space, boid) == :ok
      assert :boids.count(world) == 0
      assert {:ok, _, _} = :boids.join(world, pos: {1, 2})
    end

    test "refuses an id that is in the world, and a bad option" do
      world = world()
      {:ok, _, _} = :boids.join(world, id: :me, pos: {1, 2})
      assert :boids.join(world, id: :me, pos: {3, 4}) == {:error, {:exists, :me}}
      assert :boids.join(world, id: :other) == {:error, {:bad_option, {:pos, :undefined}}}
      assert :boids.join(world, id: :other, pos: {0, 0}, tick: 0) == {:error, {:bad_option, {:tick, 0}}}
      # The options of the process of add/2 are permitted, and not used.
      assert {:ok, _, _} =
               :boids.join(world, id: :other, pos: {0, 0}, tick: 5, priority: :normal, hibernate: false)

      :ok = :boids_world.leave(:boids.space(world), :other, self())
      assert :boids.join(world, :me) == {:error, {:bad_option, :me}}
      assert :boids.count(world) == 1
    end

    test "one process can have many boids" do
      world = world()
      {:ok, _, _} = :boids.join(world, id: :a, pos: {1, 2})
      {:ok, _, _} = :boids.join(world, id: :b, pos: {1, 2})
      assert :boids.count(world) == 2
    end

    test "the world removes the boid when the process stops" do
      world = world()
      me = self()

      pid =
        spawn(fn ->
          {:ok, _, _} = :boids.join(world, id: :a, pos: {1, 2})
          {:ok, _, _} = :boids.join(world, id: :b, pos: {1, 2})
          send(me, :joined)
          Process.sleep(:infinity)
        end)

      assert_receive :joined
      assert :boids.count(world) == 2
      assert :boids.whereis(world, :a) == pid
      Process.exit(pid, :kill)
      assert eventually(fn -> :boids.count(world) == 0 end)
    end

    test "the functions for a boid of add/2 do not find it" do
      world = world()
      {:ok, _, _} = :boids.join(world, id: :me, pos: {1, 2})
      assert :boids.boid(world, :me) == {:error, :not_found}
      assert :boids.update(world, :me, %{max_speed: 1}) == {:error, :not_found}
      assert :boids.remove(world, :me) == {:error, :not_found}
      assert :boids.step(world, 1) == :ok
      assert pos(world, :me) == {1, 2}
    end

    test "the boids of add/2 see it" do
      world = world()
      {:ok, space, me} = :boids.join(world, id: :leader, pos: {10, 0}, vel: {0, 1}, rules: [])

      {:ok, id} =
        :boids.add(
          world,
          still(perception: 5, rules: [{:pursue, 1, target: {:boid, :leader}, max_time: 0}])
        )

      :boids.step(world, 0.1)
      {x, y} = pos(world, id)
      assert x > 0 and y == 0
      # It also sees the boids of add/2.
      assert [%{id: ^id}] = :boids_boid.perceive(me, :boids.near(space, me.pos, 100))
    end

    test "a new process can use the id of a process that stopped" do
      world = world()
      space = :boids.space(world)
      {pid, ref} = spawn_monitor(fn -> :ok end)
      assert_receive {:DOWN, ^ref, _, _, _}
      # The row of a process that stopped, before the world sees its end.
      true = :boids_space.insert_new(space, %{id: :a, pos: {9, 9}, vel: {0, 0}, pid: pid})
      assert {:ok, _, _} = :boids.join(world, id: :a, pos: {1, 2})
      assert {:ok, %{pos: {1, 2}, pid: owner}} = :boids.lookup(world, :a)
      assert owner == self()
      assert :boids.count(world) == 1
    end

    test "a row with no process keeps its id" do
      world = world()
      true = :boids_space.insert_new(:boids.space(world), %{id: :a, pos: {9, 9}, vel: {0, 0}})
      assert :boids.join(world, id: :a, pos: {1, 2}) == {:error, {:exists, :a}}
    end
  end
end
