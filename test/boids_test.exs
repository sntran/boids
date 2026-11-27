defmodule BoidsTest do
  use ExUnit.Case, async: true
  import Boids.Helpers

  alias Boids.TestBoids.Mouse

  @box {{0, 0}, {100, 100}}

  # A space that stops at the end of the test.
  defp space(opts \\ %{}) do
    {:ok, space} = :boids.start_space(opts)
    on_exit(fn -> :boids.stop_space(space) end)
    space
  end

  # A boid with no rule and no clock: it moves only with step/2.
  defp still(more \\ %{}), do: Map.merge(%{pos: {0, 0}, rules: [], tick: :manual}, Map.new(more))

  # Only a process that hibernates has a heap smaller than the minimum
  # heap of a new process.
  defp hibernates?(pid) do
    {:total_heap_size, words} = Process.info(pid, :total_heap_size)
    words < 233
  end

  defp pos(space, id) do
    {:ok, %{pos: pos}} = :boids.lookup(space, id)
    pos
  end

  describe "start_space/1 and stop_space/1" do
    test "starts the process of a space, with its map" do
      {:ok, space} = :boids.start_space()
      assert Process.alive?(space)
      map = :boids.space(space)
      assert %{owner: ^space, cell_size: 10.0, bounds: :undefined, wrap: false, defaults: %{}} = map
      assert :boids.space(map) == map
      assert :boids.count(space) == 0
      assert :boids.snapshot(space) == []
      assert :boids.stop_space(space) == :ok
      refute Process.alive?(space)
      assert :ets.info(map.rows) == :undefined
      assert :boids.stop_space(space) == {:error, :not_found}
      assert :boids.stop_space(map) == {:error, :not_found}
    end

    test "the processes that control a space have a high priority" do
      space = space()
      map = :boids.space(space)
      assert Process.info(space, :priority) == {:priority, :high}
      assert Process.info(:boids_space_server.sup(space), :priority) == {:priority, :high}
      assert Process.info(:boids_space_server.boid_sup(map), :priority) == {:priority, :high}
      # A boid has a low priority, or the priority of the other processes.
      {:ok, id} = :boids.add(space, still())
      assert Process.info(id, :priority) == {:priority, :low}
      {:ok, id} = :boids.add(space, still(priority: :normal))
      assert Process.info(id, :priority) == {:priority, :normal}
    end

    test "the processes of a space and of a boid have a label" do
      space = space(name: :boids_test_label)
      {:ok, :a} = :boids.add(space, still(id: :a))
      assert :proc_lib.get_label(space) == {:boids, :space, :boids_test_label}
      assert :proc_lib.get_label(:boids.whereis(space, :a)) == {:boids, :boid, :a}
      assert :proc_lib.get_label(space()) == {:boids, :space, :undefined}
    end

    test "accepts a list of options" do
      space = space(bounds: @box, wrap: true, cell_size: 5, defaults: %{max_speed: 3})
      assert %{bounds: @box, wrap: true, cell_size: 5, defaults: %{max_speed: 3}} = :boids.space(space)
    end

    test "gives a name to the space" do
      space = space(name: :boids_test_named)
      assert Process.whereis(:boids_test_named) == space
      assert :boids.count(:boids_test_named) == 0
      global = space(name: {:global, :boids_test_global})
      assert :global.whereis_name(:boids_test_global) == global
      assert :boids.count({:global, :boids_test_global}) == 0
      via = space(name: {:via, :global, :boids_test_via})
      assert :boids.count({:via, :global, :boids_test_via}) == 0
      assert :boids.stop_space({:via, :global, :boids_test_via}) == :ok
      refute Process.alive?(via)
    end

    @tag :capture_log
    test "refuses a name that another process has" do
      space = space(name: :boids_test_twice)
      assert :boids.start_space(name: :boids_test_twice) == {:error, {:already_started, space}}
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
        assert :boids.start_space(%{key => value}) == {:error, {:bad_option, {key, value}}}
      end

      assert :boids.start_space(defaults: %{max_speed: -1}) == {:error, {:bad_option, {:max_speed, -1}}}
      assert :boids.start_space(cell_size: 1.0e200) == {:error, {:bad_option, {:cell_size, 1.0e200}}}
      box = {{0, 0}, {1.0e200, 1}}
      assert :boids.start_space(bounds: box) == {:error, {:bad_option, {:bounds, box}}}
      assert :boids.start_space(defaults: %{tick: 0}) == {:error, {:bad_option, {:tick, 0}}}
      assert :boids.start_space(defaults: %{shape: :bird}) == {:error, {:bad_option, {:shape, :bird}}}
      assert :boids.start_space(:big) == {:error, {:bad_option, :big}}
      assert :boids.start_space([:big]) == {:error, {:bad_option, [:big]}}
    end

    test "each default is good alone" do
      # The check of each boid sees the defaults with the options of the boid.
      space = space(bounds: {{0, 0, 0}, {9, 9, 9}}, defaults: %{vel: {0, 0, 1}, min_speed: 12, tick: :manual})
      assert :boids.add(space, pos: {1, 1, 1}) == {:error, {:bad_option, {:min_speed, 12}}}
      assert {:ok, id} = :boids.add(space, pos: {1, 1, 1}, max_speed: 20)
      assert {:ok, %{vel: {0, 0, 1}, min_speed: 12}} = :boids.boid(space, id)
    end

    test "stops the boids of the space" do
      {:ok, space} = :boids.start_space()
      {:ok, id} = :boids.add(space, still())
      pid = :boids.whereis(space, id)
      assert Process.alive?(pid)
      assert :boids.stop_space(:boids.space(space)) == :ok
      refute Process.alive?(pid)
    end
  end

  describe "child_spec/1" do
    test "starts a space below a supervisor of yours" do
      {:ok, sup} =
        Supervisor.start_link([{:boids, name: :boids_test_child, bounds: @box}], strategy: :one_for_one)

      assert %{bounds: @box} = :boids.space(:boids_test_child)
      {:ok, id} = :boids.add(:boids_test_child, still())
      assert :boids.count(:boids_test_child) == 1
      assert :boids.stop_space(:boids_test_child) == {:error, :not_found}
      pid = :boids.whereis(:boids_test_child, id)
      Supervisor.stop(sup)
      refute Process.alive?(pid)
      assert Process.whereis(:boids_test_child) == nil
    end

    test "has the name of the space in its id" do
      assert %{id: {:boids, :a}, start: {:boids_space_sup, :start_link, [%{name: :a}]}, type: :supervisor} =
               :boids.child_spec(%{name: :a})

      assert %{id: {:boids, :undefined}} = :boids.child_spec([])
    end

    test "refuses a bad option" do
      assert catch_error(:boids.child_spec(%{cell_size: -1})) == {:bad_option, {:cell_size, -1}}
    end

    @tag :capture_log
    test "a space that stops with an error starts again, with no boid" do
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
      space = space()
      {:ok, id} = :boids.add(space, still(pos: {1, 2}, vel: {3, 4}, group: :birds, data: :blue))
      assert is_pid(id)
      assert :boids.whereis(space, id) == id
      assert :boids.count(space) == 1

      assert :boids.lookup(space, id) ==
               {:ok, %{id: id, pos: {1, 2}, vel: {3, 4}, group: :birds, data: :blue, pid: id}}

      assert :boids.snapshot(space) == [elem(:boids.lookup(space, id), 1)]
      assert {:ok, %{id: ^id, pos: {1, 2}, max_speed: 10.0, rules: []}} = :boids.boid(space, id)
    end

    test "accepts an id and a list of options" do
      space = space()
      assert :boids.add(space, id: :a, pos: {1, 2}, tick: :manual) == {:ok, :a}
      pid = :boids.whereis(space, :a)
      assert is_pid(pid)
      assert {:ok, %{id: :a, pid: ^pid}} = :boids.lookup(space, :a)
    end

    test "refuses an id that is in the space" do
      space = space()
      {:ok, :a} = :boids.add(space, still(id: :a))
      assert :boids.add(space, still(id: :a, pos: {5, 5})) == {:error, {:exists, :a}}
      assert :boids.count(space) == 1
      assert pos(space, :a) == {0, 0}
    end

    test "refuses a bad option" do
      space = space()
      assert :boids.add(space, %{}) == {:error, {:bad_option, {:pos, :undefined}}}
      assert :boids.add(space, still(max_speed: -1)) == {:error, {:bad_option, {:max_speed, -1}}}
      assert :boids.add(space, still(tick: 0)) == {:error, {:bad_option, {:tick, 0}}}
      assert :boids.add(space, still(tick: 1.5)) == {:error, {:bad_option, {:tick, 1.5}}}
      assert :boids.add(space, still(max_dt: 0)) == {:error, {:bad_option, {:max_dt, 0}}}
      assert :boids.add(space, still(seed: :random)) == {:error, {:bad_option, {:seed, :random}}}
      assert :boids.add(space, still(priority: :high)) == {:error, {:bad_option, {:priority, :high}}}
      assert :boids.add(space, still(hibernate: :yes)) == {:error, {:bad_option, {:hibernate, :yes}}}
      assert :boids.add(space, still(wings: 2)) == {:error, {:bad_option, {:wings, 2}}}
      assert :boids.add(space, :bird) == {:error, {:bad_option, :bird}}
      assert :boids.add(space, [:bird]) == {:error, {:bad_option, [:bird]}}
      assert :boids.count(space) == 0
    end

    test "uses the defaults of the space" do
      space = space(defaults: %{max_speed: 3, group: :fish, tick: :manual, rules: []})
      {:ok, a} = :boids.add(space, pos: {0, 0})
      {:ok, b} = :boids.add(space, pos: {0, 0}, max_speed: 4)
      assert {:ok, %{max_speed: 3, group: :fish, rules: []}} = :boids.boid(space, a)
      assert {:ok, %{max_speed: 4, group: :fish}} = :boids.boid(space, b)
    end

    test "refuses a position that does not have the size of the space" do
      space = space()
      {:ok, a} = :boids.add(space, still())
      assert :boids.add(space, still(pos: {0, 0, 0})) == {:error, {:bad_option, {:pos, {0, 0, 0}}}}
      assert :boids.join(space, pos: {0, 0, 0}) == {:error, {:bad_option, {:pos, {0, 0, 0}}}}
      assert :boids.populate(space, 2, area: {{0, 0, 0}, {1, 1, 1}}, tick: :manual) |> elem(0) == :error

      assert :boids.update(space, a, %{pos: {0, 0, 0}, vel: {0, 0, 0}}) ==
               {:error, {:bad_option, {:pos, {0, 0, 0}}}}

      assert_raise ArgumentError, fn -> :boids.set_obstacle(space, :rock, {0, 0, 0}, 1) end
      assert :boids.count(space) == 1
      # The size of the first boid stays, also for an empty space.
      :ok = :boids.remove(space, a)
      assert :boids.add(space, still(pos: {0, 0, 0})) == {:error, {:bad_option, {:pos, {0, 0, 0}}}}
      assert {:ok, _} = :boids.add(space, still())
      # A space with a box has the size of its box.
      box = space(bounds: {{0, 0, 0}, {9, 9, 9}})
      assert :boids.add(box, still()) == {:error, {:bad_option, {:pos, {0, 0}}}}
      assert_raise ArgumentError, fn -> :boids.set_obstacle(box, :rock, {0, 0}, 1) end
      assert :boids.set_obstacle(box, :rock, {0, 0, 0}, 1) == :ok
    end

    @tag :capture_log
    test "an obstacle of another size does not stop a boid" do
      # An empty space with no box accepts an obstacle of each size.
      space = space()
      assert :boids.set_obstacle(space, :rock, {5, 0, 0}, 2) == :ok
      {:ok, id} = :boids.add(space, still(vel: {1, 0}, rules: [avoid: 1]))
      :boids.step(space, 1)
      assert pos(space, id) == {1.0, 0.0}
    end

    test "functions for a boid that is not in the space" do
      space = space()
      assert :boids.lookup(space, :nobody) == :error
      assert :boids.whereis(space, :nobody) == :undefined
      assert :boids.boid(space, :nobody) == {:error, :not_found}
      assert :boids.update(space, :nobody, %{max_speed: 1}) == {:error, :not_found}
      assert :boids.remove(space, :nobody) == {:error, :not_found}
    end
  end

  describe "remove/2" do
    test "stops the process of a boid, and removes its row" do
      space = space()
      {:ok, id} = :boids.add(space, still())
      {:ok, other} = :boids.add(space, still())
      assert :boids.remove(space, id) == :ok
      refute Process.alive?(id)
      assert :boids.lookup(space, id) == :error
      assert :boids.count(space) == 1
      assert :boids.remove(space, id) == {:error, :not_found}
      assert Process.alive?(other)
    end

    test "a late leave for a process that stopped does not take the row of a new process" do
      space = space()
      {:ok, :a} = :boids.add(space, still(id: :a))
      first = :boids.whereis(space, :a)
      :ok = :boids.remove(space, :a)
      {:ok, :a} = :boids.add(space, still(id: :a))
      second = :boids.whereis(space, :a)
      # The message of remove/2 for the first process, after the start of the second.
      assert :boids_space_server.leave(:boids.space(space), :a, first) == :ok
      assert :boids.whereis(space, :a) == second
      assert :boids.remove(space, :a) == :ok
      assert :boids.count(space) == 0
    end

    test "only the process of a boid of join/2 removes it with leave/2" do
      space = space()
      {:ok, map, boid} = :boids.join(space, id: :me, pos: {1, 2})
      assert Task.await(Task.async(fn -> :boids.leave(map, boid) end)) == :ok
      assert :boids.whereis(space, :me) == self()
      assert :boids.leave(map, boid) == :ok
      assert :boids.count(space) == 0
    end

    test "the id is free again" do
      space = space()
      {:ok, :a} = :boids.add(space, still(id: :a))
      :ok = :boids.remove(space, :a)
      assert :boids.add(space, still(id: :a, pos: {5, 5})) == {:ok, :a}
      assert pos(space, :a) == {5, 5}
    end
  end

  describe "update/3" do
    test "changes options of a boid, and its row" do
      space = space()
      {:ok, id} = :boids.add(space, still())
      assert :boids.update(space, id, %{pos: {50, 60}, vel: {1, 0}, group: :b, data: 1, max_speed: 2}) == :ok
      assert {:ok, %{pos: {50, 60}, vel: {1, 0}, group: :b, data: 1}} = :boids.lookup(space, id)
      assert {:ok, %{max_speed: 2, pos: {50, 60}}} = :boids.boid(space, id)
      assert [%{id: ^id}] = :boids.near(space, {50, 60}, 1)
      assert :boids.update(space, id, rules: [wander: 1]) == :ok
      assert {:ok, %{rules: [{:wander, 1, %{}}]}} = :boids.boid(space, id)
    end

    test "refuses a bad option, and changes nothing" do
      space = space()
      {:ok, id} = :boids.add(space, still())

      assert :boids.update(space, id, %{pos: {1, 1}, max_speed: -1}) ==
               {:error, {:bad_option, {:max_speed, -1}}}

      assert :boids.update(space, id, %{id: :other}) == {:error, {:bad_option, {:id, :other}}}
      assert :boids.update(space, id, %{tick: 5}) == {:error, {:bad_option, {:tick, 5}}}
      assert pos(space, id) == {0, 0}
    end
  end

  describe "add_rule/3, delete_rule/3 and which_rules/2" do
    test "change the rules of a boid, from its next step" do
      space = space()
      {:ok, id} = :boids.add(space, still(max_force: 100))
      assert :boids.which_rules(space, id) == {:ok, []}
      assert :boids.add_rule(space, id, {{:seek, :home}, 1, target: {10, 0}}) == :ok
      assert :boids.add_rule(space, id, {{:seek, :food}, 1, %{target: {0, 10}}}) == :ok
      assert :boids.which_rules(space, id) == {:ok, [seek: :home, seek: :food]}
      :boids.step(space, 0.1)
      {x, y} = pos(space, id)
      assert x > 0 and y > 0
      assert :boids.delete_rule(space, id, {:seek, :food}) == :ok
      assert :boids.which_rules(space, id) == {:ok, [seek: :home]}
      assert {:ok, %{rules: [{{:seek, :home}, 1, %{target: {10, 0}}}]}} = :boids.boid(space, id)
      # A boid with no such rule does not change.
      assert :boids.delete_rule(space, id, :wander) == :ok
      assert :boids.which_rules(space, id) == {:ok, [seek: :home]}
    end

    test "a rule of your own is a function, and its name is the function" do
      space = space()
      me = self()

      push = fn boid, neighbors, env ->
        send(me, {:rule, boid.id, length(neighbors), env.dt})
        {3, 0}
      end

      {:ok, id} = :boids.add(space, still(id: :a, max_force: 100))
      {:ok, _} = :boids.add(space, still(pos: {1, 1}))
      assert :boids.add_rule(space, id, {push, 2}) == :ok
      assert :boids.which_rules(space, id) == {:ok, [push]}
      :boids.step(space, 0.5)
      assert_received {:rule, :a, 1, 0.5}
      assert_vec(pos(space, id), {1.5, 0.0})
      assert :boids.delete_rule(space, id, push) == :ok
      :boids.step(space, 0.5)
      refute_received {:rule, _, _, _}
    end

    test "give not_found for an id that is not a boid with a process of the library" do
      space = space()
      {:ok, _space, _me} = :boids.join(space, id: :me, pos: {0, 0})

      for id <- [:me, :nobody] do
        assert :boids.add_rule(space, id, {:wander, 1}) == {:error, :not_found}
        assert :boids.delete_rule(space, id, :wander) == {:error, :not_found}
        assert :boids.which_rules(space, id) == {:error, :not_found}
        assert :boids.update(space, id, %{max_speed: 1}) == {:error, :not_found}
        assert :boids.boid(space, id) == {:error, :not_found}
        assert :boids.remove(space, id) == {:error, :not_found}
      end
    end

    test "refuse a bad rule, and change nothing" do
      space = space()
      {:ok, id} = :boids.add(space, still())
      assert :boids.add_rule(space, id, {:seek, 1}) == {:error, {:bad_option, {:rules, {:seek, 1, %{}}}}}
      assert :boids.add_rule(space, id, {:fly, 1}) == {:error, {:bad_option, {:rules, {:fly, 1, %{}}}}}
      assert :boids.which_rules(space, id) == {:ok, []}
    end

    test "the memory of a rule has the name of the rule" do
      space = space()
      {:ok, id} = :boids.add(space, still(seed: 1, rules: [{:wander, 1}, {{:wander, :slow}, 1, jitter: 0.1}]))
      :boids.step(space, 0.1)

      assert {:ok, %{memory: %{:wander => {_, _}, {:wander, :slow} => {_, _}} = memory}} =
               :boids.boid(space, id)

      assert map_size(memory) == 2
      :ok = :boids.delete_rule(space, id, :wander)
      assert {:ok, %{memory: only}} = :boids.boid(space, id)
      assert Map.keys(only) == [{:wander, :slow}]
    end
  end

  describe "a boid with no module of yours" do
    @describetag :capture_log

    test "stops at a call or a cast of gen_boid" do
      space = space()
      {:ok, first} = :boids.add(space, still())
      assert {{:bad_call, :hello}, _} = catch_exit(:gen_boid.call(first, :hello))
      {:ok, second} = :boids.add(space, still())
      ref = Process.monitor(second)
      :gen_boid.cast(second, :hello)
      assert_receive {:DOWN, ^ref, _, _, {:bad_cast, :hello}}
      assert eventually(fn -> :boids.count(space) == 0 end)
    end
  end

  describe "the relations between the boids" do
    setup do
      space = space()
      for id <- [:a, :b, :c], do: {:ok, ^id} = :boids.add(space, still(id: id))
      %{space: space}
    end

    test "relate/4 adds a relation, and the reads give it in the two directions", %{space: space} do
      assert :boids.relate(space, :a, :follows, :b) == :ok
      assert :boids.relate(space, :c, :follows, :b) == :ok
      # Two boids can have two relations, with different labels.
      assert :boids.relate(space, :a, :fears, :b) == :ok
      # The same relation again changes nothing.
      assert :boids.relate(space, :a, :follows, :b) == :ok
      assert :boids.related(space, :a, :follows) == [:b]
      assert Enum.sort(:boids.related_to(space, :b, :follows)) == [:a, :c]
      assert :boids.related(space, :a, :fears) == [:b]
      assert :boids.related(space, :b, :follows) == []
      assert :boids.related_to(space, :a, :follows) == []
      assert :boids.related(space, :nobody, :follows) == []
      # The map of the space gives the same, with no message.
      assert :boids.related(:boids.space(space), :c, :follows) == [:b]
    end

    test "relations/1 gives the relations as a graph", %{space: space} do
      assert :graph.vertices(:boids.relations(space)) == []
      :ok = :boids.relate(space, :a, :follows, :b)
      :ok = :boids.relate(space, :c, :follows, :b)
      :ok = :boids.relate(space, :a, :fears, :b)
      graph = :boids.relations(space)
      assert Enum.sort(:graph.vertices(graph)) == [:a, :b, :c]
      assert Enum.sort(:graph.edges(graph)) == [{:a, :b, :fears}, {:a, :b, :follows}, {:c, :b, :follows}]
      assert graph |> :graph.in_neighbours(:b) |> Enum.uniq() |> Enum.sort() == [:a, :c]
      assert Enum.uniq(:graph.out_neighbours(graph, :a)) == [:b]
      assert :graph.has_edge(graph, :a, :b)
    end

    test "unrelate/4 removes one relation", %{space: space} do
      :ok = :boids.relate(space, :a, :follows, :b)
      :ok = :boids.relate(space, :c, :follows, :b)
      :ok = :boids.relate(space, :a, :fears, :b)
      assert :boids.unrelate(space, :a, :follows, :b) == :ok
      assert :boids.related(space, :a, :follows) == []
      assert :boids.related_to(space, :b, :follows) == [:c]
      assert :boids.related(space, :a, :fears) == [:b]
      assert Enum.sort(:graph.edges(:boids.relations(space))) == [{:a, :b, :fears}, {:c, :b, :follows}]
      # A relation that the space does not have changes nothing.
      assert :boids.unrelate(space, :a, :follows, :b) == :ok
      assert :boids.unrelate(space, :b, :follows, :nobody) == :ok
      assert :boids.related_to(space, :b, :follows) == [:c]
    end

    test "relate/4 refuses an id that is not in the space", %{space: space} do
      assert :boids.relate(space, :a, :follows, :nobody) == {:error, {:not_found, :nobody}}
      assert :boids.relate(space, :nobody, :follows, :a) == {:error, {:not_found, :nobody}}
      assert :graph.vertices(:boids.relations(space)) == []
      assert :boids.related(space, :a, :follows) == []
    end

    test "a space accepts a cycle of relations", %{space: space} do
      assert :boids.relate(space, :a, :follows, :b) == :ok
      assert :boids.relate(space, :b, :follows, :a) == :ok
      assert :boids.related(space, :b, :follows) == [:a]
    end

    test "a space with the option acyclic refuses a cycle" do
      space = space(relations: :acyclic)
      for id <- [:a, :b, :c], do: {:ok, ^id} = :boids.add(space, still(id: id))
      assert :boids.relate(space, :a, :follows, :b) == :ok
      assert :boids.relate(space, :b, :follows, :c) == :ok
      assert :boids.relate(space, :c, :follows, :a) == {:error, :cycle}
      assert :boids.related(space, :c, :follows) == []
      assert :boids.related_to(space, :a, :follows) == []
      assert :graph.topsort(:boids.relations(space)) == [:a, :b, :c]
    end

    test "the option relations is cyclic or acyclic" do
      assert {:ok, space} = :boids.start_space(relations: :cyclic)
      :boids.stop_space(space)
      assert :boids.start_space(relations: :tree) == {:error, {:bad_option, {:relations, :tree}}}
      assert catch_error(:boids.child_spec(relations: :tree)) == {:bad_option, {:relations, :tree}}
    end

    test "the relations of a boid go when the space removes the boid", %{space: space} do
      :ok = :boids.relate(space, :a, :follows, :b)
      :ok = :boids.relate(space, :b, :follows, :c)
      :ok = :boids.relate(space, :c, :fears, :a)
      assert :boids.remove(space, :b) == :ok
      assert :boids.related(space, :a, :follows) == []
      assert :boids.related_to(space, :c, :follows) == []
      assert :boids.related_to(space, :b, :follows) == []
      assert :boids.related(space, :b, :follows) == []
      # The other relations stay.
      assert :boids.related(space, :c, :fears) == [:a]
      assert :graph.edges(:boids.relations(space)) == [{:c, :a, :fears}]
      assert Enum.sort(:graph.vertices(:boids.relations(space))) == [:a, :c]
    end

    test "the relations of a boid go when its process stops", %{space: space} do
      :ok = :boids.relate(space, :a, :follows, :b)
      :ok = :boids.relate(space, :c, :follows, :a)
      :ok = GenServer.stop(:boids.whereis(space, :a))
      assert eventually(fn -> :boids.count(space) == 2 end)
      assert :boids.related_to(space, :b, :follows) == []
      assert :boids.related(space, :c, :follows) == []
      assert :graph.edges(:boids.relations(space)) == []
    end

    test "a process of yours with join/2 has relations, and they go when it leaves", %{space: space} do
      {:ok, map, me} = :boids.join(space, id: :me, pos: {1, 1})
      assert :boids.relate(space, :me, :follows, :a) == :ok
      assert :boids.relate(space, :b, :follows, :me) == :ok
      assert :boids.related(space, :me, :follows) == [:a]
      assert :boids.related_to(space, :me, :follows) == [:b]
      assert :boids.leave(map, me) == :ok
      assert :boids.related_to(space, :a, :follows) == []
      assert :boids.related(space, :b, :follows) == []
    end

    test "a rule with the target of a relation uses the related boid", %{space: space} do
      rules = [{:seek, 1, %{target: {:related, :follows}}}]
      :ok = :boids.update(space, :a, %{rules: rules, max_force: 100})
      :ok = :boids.update(space, :b, %{pos: {10, 0}})
      # No relation gives no force.
      :boids.step(space, 0.1)
      assert pos(space, :a) == {0, 0}
      :ok = :boids.relate(space, :a, :follows, :b)
      :boids.step(space, 0.1)
      {x, y} = pos(space, :a)
      assert x > 0 and y == 0
      # A process of yours uses the relation too, with advance/3.
      {:ok, map, me} = :boids.join(space, id: :me, pos: {0, 5}, rules: rules, max_force: 100)
      :ok = :boids.relate(space, :me, :follows, :c)
      :ok = :boids.update(space, :c, %{pos: {0, 20}})
      %{pos: {mx, my}} = :boids.advance(map, me, 0.1)
      assert mx == 0 and my > 5
    end
  end

  describe "flocks/2" do
    test "gives the groups of boids that see each other" do
      space = space()
      assert :boids.flocks(space, 5) == []
      {:ok, :a} = :boids.add(space, still(id: :a))
      {:ok, :b} = :boids.add(space, still(id: :b, pos: {3, 0}))
      {:ok, :c} = :boids.add(space, still(id: :c, pos: {6, 0}))
      {:ok, :d} = :boids.add(space, still(id: :d, pos: {50, 50}))
      # A chain of boids is one flock: a sees b, and b sees c.
      flocks = :boids.flocks(space, 5) |> Enum.map(&Enum.sort/1) |> Enum.sort()
      assert flocks == [[:a, :b, :c], [:d]]
      # A boid sees no other boid at a small radius, and all at a large one.
      assert length(:boids.flocks(space, 1)) == 4
      assert [[_, _, _, _]] = :boids.flocks(:boids.space(space), 100)
    end
  end

  describe "graph/2" do
    test "gives the boids that see each other as a graph" do
      space = space()
      {:ok, :a} = :boids.add(space, still(id: :a))
      {:ok, :b} = :boids.add(space, still(id: :b, pos: {3, 0}))
      {:ok, :c} = :boids.add(space, still(id: :c, pos: {50, 50}))
      graph = :boids.graph(space, 5)
      assert Enum.sort(:graph.vertices(graph)) == [:a, :b, :c]
      # The label of a boid is its row.
      assert :graph.vertex(graph, :b) == elem(:boids.lookup(space, :b), 1)
      assert :graph.has_edge(graph, :a, :b)
      assert :graph.has_edge(graph, :b, :a)
      assert :graph.no_edges(graph) == 2
      assert :graph.out_degree(graph, :c) == 0
      groups = graph |> :graph.components() |> Enum.map(&Enum.sort/1) |> Enum.sort()
      assert groups == [[:a, :b], [:c]]
      # With a large radius, each boid sees each other boid.
      all = :boids.graph(:boids.space(space), 100)
      assert :graph.no_edges(all) == 6
      assert [[_, _, _]] = :graph.components(all)
    end

    test "an empty space gives an empty graph" do
      assert :graph.vertices(:boids.graph(space(), 10)) == []
    end
  end

  describe "the process of a boid" do
    @tag :capture_log
    test "a boid that stops with an error goes from the space, and the other boids continue" do
      space = space()
      {:ok, :a} = :boids.add(space, still(id: :a, pos: {1, 1}))
      {:ok, other} = :boids.add(space, still())
      Process.exit(:boids.whereis(space, :a), :kill)
      assert eventually(fn -> :boids.whereis(space, :a) == :undefined end)
      assert :boids.count(space) == 1
      assert Process.alive?(other)
      # The id is free for a new boid.
      assert :boids.add(space, still(id: :a)) == {:ok, :a}
    end

    @tag :capture_log
    test "a boid with an error at each step does not stop the space" do
      space = space()
      {:ok, good} = :boids.populate(space, 20, area: @box, tick: 5)
      bad = fn _boid, _neighbors, _env -> raise "a fault of a rule" end
      for _ <- 1..15, do: {:ok, _} = :boids.add(space, pos: {1, 1}, rules: [{bad, 1}], tick: 5)
      assert eventually(fn -> :boids.count(space) == 20 end)
      assert Process.alive?(space)
      assert Enum.all?(good, &Process.alive?/1)
      assert Enum.sort(Enum.map(:boids.snapshot(space), & &1.id)) == Enum.sort(good)
    end

    @tag :capture_log
    test "the end of the process of a space stops all the space" do
      {:ok, space} = :boids.start_space()
      {:ok, id} = :boids.add(space, still())
      sup = :boids_space_server.sup(space)
      Process.exit(space, :kill)
      assert eventually(fn -> not Process.alive?(sup) end)
      refute Process.alive?(id)
      assert :boids.stop_space(space) == {:error, :not_found}
    end

    test "a boid whose process stopped is not found" do
      space = space()
      {:ok, id} = :boids.add(space, still())
      map = :boids.space(space)
      # The space does not see the end of the process before the call.
      :sys.suspend(space)
      ref = Process.monitor(id)
      :ok = GenServer.stop(id)
      assert_receive {:DOWN, ^ref, _, _, _}
      assert :boids.boid(map, id) == {:error, :not_found}
      assert :boids.update(map, id, %{max_speed: 1}) == {:error, :not_found}
      :sys.resume(space)
      assert eventually(fn -> :boids.count(space) == 0 end)
    end

    test "the space removes a boid whose process stops" do
      space = space()
      {:ok, id} = :boids.add(space, still())
      :ok = GenServer.stop(id)
      assert eventually(fn -> :boids.count(space) == 0 end)
      assert :boids.lookup(space, id) == :error
      assert :boids.near(space, {0, 0}, 5) == []
    end

    test "other messages change nothing" do
      space = space()
      {:ok, id} = :boids.add(space, still())
      send(id, :hello)
      GenServer.cast(id, :hello)
      send(space, :hello)
      send(space, {:DOWN, make_ref(), :process, self(), :normal})
      GenServer.cast(space, :hello)
      assert {:ok, %{pos: {0, 0}}} = :boids.boid(space, id)
      assert :boids.count(space) == 1
    end
  end

  describe "a boid below a supervisor of yours" do
    @describetag :capture_log

    setup do
      name = :"boids_test_own_#{System.unique_integer([:positive])}"

      children = [
        {:boids, name: name, defaults: %{tick: :manual, rules: []}},
        {:gen_boid, {Mouse, [id: :hawk, pos: {1, 1}, vel: {1, 0}], [space: name]}}
      ]

      start = {Supervisor, :start_link, [children, [strategy: :rest_for_one]]}
      sup = start_supervised!(%{id: :own, start: start, type: :supervisor})
      %{space: name, sup: sup}
    end

    test "is a boid of the space, with the defaults of the space", %{space: space} do
      assert {:ok, %{id: :hawk, pos: {1, 1}, rules: []}} = :boids.boid(space, :hawk)
      assert :boids.update(space, :hawk, %{max_speed: 3}) == :ok
      :boids.step(space, 1)
      assert pos(space, :hawk) == {2.0, 1.0}
    end

    test "starts again with its id after an error", %{space: space} do
      first = :boids.whereis(space, :hawk)
      :boids.step(space, 1)
      Process.exit(first, :kill)
      assert eventually(fn -> :boids.whereis(space, :hawk) not in [:undefined, first] end)
      assert pos(space, :hawk) == {1, 1}
      assert :boids.count(space) == 1
    end

    test "finds its space again when the space starts again", %{space: space} do
      first = :boids.whereis(space, :hawk)
      Process.exit(Process.whereis(space), :kill)

      # The supervisor starts the space again, then the boid.
      again = fn ->
        try do
          :boids.whereis(space, :hawk) not in [:undefined, first]
        catch
          :exit, _ -> false
        end
      end

      assert eventually(again)
    end

    test "boids:remove/2 does not stop it", %{space: space} do
      assert :boids.remove(space, :hawk) == {:error, :not_found}
      assert Process.alive?(:boids.whereis(space, :hawk))
      {:ok, other} = :boids.add(space, pos: {5, 5})
      assert :boids.remove(space, other) == :ok
      assert :boids.count(space) == 1
    end

    test "the specification of the child has the module and its arguments" do
      assert :gen_boid.child_spec({Mouse, %{id: :hawk}, %{space: :f}}) == %{
               id: {:gen_boid, Mouse, %{id: :hawk}},
               start: {:gen_boid, :start_link, [Mouse, %{id: :hawk}, %{space: :f}]}
             }
    end

    test "start_link/3 refuses a bad option and an id of the space", %{space: space} do
      Process.flag(:trap_exit, true)
      start = fn options -> :gen_boid.start_link(Mouse, options, space: space) end
      assert start.(pos: {0, 0}, mass: 0) == {:error, {:shutdown, {:bad_option, {:mass, 0}}}}
      assert start.(:bird) == {:error, {:shutdown, {:bad_option, :bird}}}
      assert start.(id: :hawk, pos: {0, 0}) == {:error, {:shutdown, {:exists, :hawk}}}
      assert {:ok, pid} = start.(pos: {0, 0})
      assert :boids.whereis(space, pid) == pid
    end
  end

  describe "the clock of a boid" do
    test "a boid moves in real time" do
      space = space()
      {:ok, id} = :boids.add(space, pos: {0, 0}, vel: {10, 0}, rules: [], tick: 5)
      Process.sleep(200)
      {x, y} = pos(space, id)
      # 2 units in 200 ms. The limits accept a slow computer.
      assert x > 1.0 and x < 10.0
      assert y == 0.0
      later = eventually(fn -> elem(pos(space, id), 0) > x end)
      assert later
    end

    test "with a manual tick, a boid moves only with step/2" do
      space = space()
      {:ok, id} = :boids.add(space, still(vel: {10, 0}))
      Process.sleep(50)
      assert pos(space, id) == {0, 0}
    end

    test "the scale of the time makes the boids slow, fast or stopped" do
      space = space()
      assert :boids.set_time_scale(space, 0) == :ok
      {:ok, id} = :boids.add(space, pos: {0, 0}, vel: {1, 0}, rules: [], tick: 5)
      Process.sleep(50)
      assert pos(space, id) == {0, 0}
      assert :boids.set_time_scale(space, 100) == :ok
      # 100 units for each second of the clock.
      assert eventually(fn -> elem(pos(space, id), 0) > 5.0 end)
    end

    test "a step has the maximum time at most" do
      space = space()
      {:ok, id} = :boids.add(space, pos: {0, 0}, vel: {10, 0}, rules: [], tick: 20, max_dt: 0.001)
      Process.sleep(200)
      {x, _} = pos(space, id)
      # 10 ticks of 0.01 unit at most, and not 2 units.
      assert x > 0.0 and x < 0.5
    end

    test "a boid hibernates between two steps" do
      space = space()

      sleeps? = &hibernates?/1

      {:ok, timed} = :boids.add(space, pos: {0, 0}, vel: {1, 0}, rules: [], tick: 20)
      assert eventually(fn -> sleeps?.(timed) end)
      before = pos(space, timed)
      assert eventually(fn -> pos(space, timed) != before end)
      {:ok, manual} = :boids.add(space, still())
      refute sleeps?.(manual)
      :boids.step(space, 0.1)
      assert eventually(fn -> sleeps?.(manual) end)
      # A boid that hibernates answers.
      assert {:ok, %{id: ^manual}} = :boids.boid(space, manual)
    end

    test "without hibernate, a boid keeps its heap" do
      space = space()

      sleeps? = &hibernates?/1

      {:ok, timed} = :boids.add(space, pos: {0, 0}, vel: {1, 0}, rules: [], tick: 5, hibernate: false)
      {:ok, manual} = :boids.add(space, still(hibernate: false))
      assert eventually(fn -> pos(space, timed) != {0, 0} end)
      :boids.step(space, 0.1)
      refute sleeps?.(timed)
      refute sleeps?.(manual)
    end

    test "a boid whose tick comes late waits longer before its next tick" do
      space = space()
      {:ok, id} = :boids.add(space, pos: {0, 0}, vel: {10, 0}, rules: [], tick: 10)
      # The tick comes 100 ms late, as with processors that have too much work.
      :erlang.suspend_process(id)
      Process.sleep(110)
      late = pos(space, id)
      :erlang.resume_process(id)
      assert eventually(fn -> pos(space, id) != late end)
      # The boid waits 8 times the delay more: about 0.7 second.
      moved = pos(space, id)
      Process.sleep(300)
      assert pos(space, id) == moved
      assert eventually(fn -> pos(space, id) != moved end)
      # Then the ticks come at the usual time again.
      again = pos(space, id)
      Process.sleep(200)
      assert elem(pos(space, id), 0) - elem(again, 0) > 0.5
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
      space = space()
      rules = [wander: 1]
      {:ok, a} = :boids.add(space, still(seed: 42, rules: rules, id: :a))
      {:ok, b} = :boids.add(space, still(seed: 42, rules: rules, id: :b, pos: {50, 50}))
      {:ok, c} = :boids.add(space, still(seed: 43, rules: rules, id: :c, pos: {90, 90}))
      for _ <- 1..10, do: :boids.step(space, 0.1)
      assert_vec(:boids_vec.sub(pos(space, b), {50, 50}), pos(space, a))
      refute :boids_vec.sub(pos(space, c), {90, 90}) == pos(space, a)
    end
  end

  describe "step/2" do
    test "moves each boid for the time of the step" do
      space = space()
      {:ok, a} = :boids.add(space, still(vel: {1, 0}))
      {:ok, b} = :boids.add(space, still(pos: {5, 5}, vel: {0, -2}))
      assert :boids.step(space, 0.5) == :ok
      assert pos(space, a) == {0.5, 0.0}
      assert pos(space, b) == {5.0, 4.0}
      assert {:ok, %{pos: {0.5, +0.0}}} = :boids.boid(space, a)
      assert :boids.step(space, 0) == :ok
      assert pos(space, a) == {0.5, 0.0}
    end

    test "each boid calculates its step before a boid moves" do
      space = space()
      me = self()

      rule = fn boid, neighbors, _env ->
        send(me, {boid.id, Enum.map(neighbors, & &1.pos)})
        {0, 0}
      end

      for {id, x} <- [a: 0, b: 1, c: 2],
          do: {:ok, _} = :boids.add(space, still(id: id, pos: {x, 0}, vel: {1, 0}, rules: [{rule, 1}]))

      :boids.step(space, 1)
      assert_received {:a, [{1, 0}, {2, 0}]}
      assert_received {:b, [{0, 0}, {2, 0}]}
      assert_received {:c, [{1, 0}, {0, 0}]}
      assert pos(space, :a) == {1.0, 0.0}
      :boids.step(space, 1)
      assert_received {:c, [{2.0, +0.0}, {1.0, +0.0}]}
    end

    test "uses the scale of the time" do
      space = space()
      {:ok, a} = :boids.add(space, still(vel: {1, 0}))
      :boids.set_time_scale(space, 10)
      :boids.step(space, 0.5)
      assert pos(space, a) == {5.0, 0.0}
      :boids.set_time_scale(space, 0)
      :boids.step(space, 0.5)
      assert pos(space, a) == {5.0, 0.0}
    end

    test "a step does not change the clock of a boid" do
      space = space()
      {:ok, id} = :boids.add(space, still(vel: {1, 0}))
      %{last: last} = :sys.get_state(id)
      Process.sleep(5)
      :boids.step(space, 0.5)
      assert %{last: ^last, pending: :undefined} = :sys.get_state(id)
    end

    test "a commit with no plan changes nothing" do
      space = space()
      {:ok, id} = :boids.add(space, still(vel: {1, 0}))
      assert GenServer.call(id, :commit) == :ok
      assert pos(space, id) == {0, 0}
      # An update removes the plan.
      assert GenServer.call(id, {:plan, 1}) == :ok
      :ok = :boids.update(space, id, %{pos: {7, 7}})
      assert GenServer.call(id, :commit) == :ok
      assert pos(space, id) == {7, 7}
    end

    test "refuses a bad time" do
      space = space()
      assert_raise FunctionClauseError, fn -> :boids.step(space, -1) end
      assert_raise FunctionClauseError, fn -> :boids.step(space, :long) end
    end

    test "with a seed for each boid, two runs give the same result" do
      run = fn ->
        {:ok, space} = :boids.start_space(bounds: {{0, 0}, {60, 60}}, wrap: true)
        rules = [separation: 1.5, alignment: 1.0, cohesion: 1.0, wander: 0.5]

        for n <- 1..40 do
          pos = {rem(n * 17, 60), rem(n * 29, 60)}
          vel = {rem(n, 7) - 3, rem(n, 5) - 2}
          {:ok, ^n} = :boids.add(space, id: n, pos: pos, vel: vel, rules: rules, tick: :manual, seed: n)
        end

        for _ <- 1..60, do: :boids.step(space, 0.05)
        rows = Enum.sort_by(:boids.snapshot(space), & &1.id)
        :ok = :boids.stop_space(space)
        Enum.map(rows, &Map.take(&1, [:id, :pos, :vel]))
      end

      first = run.()
      assert first == run.()
      assert length(first) == 40
    end
  end

  describe "populate/3" do
    test "adds boids at random positions of the box of the space" do
      space = space(bounds: {{10, 20}, {30, 50}})
      {:ok, ids} = :boids.populate(space, 30, %{tick: :manual, min_speed: 2, max_speed: 5})
      assert length(Enum.uniq(ids)) == 30
      assert :boids.count(space) == 30

      for %{pos: {x, y}, vel: vel} <- :boids.snapshot(space) do
        assert x >= 10 and x <= 30 and y >= 20 and y <= 50
        speed = :boids_vec.norm(vel)
        assert speed >= 2 - 1.0e-9 and speed <= 5 + 1.0e-9
      end

      positions = Enum.uniq(Enum.map(:boids.snapshot(space), & &1.pos))
      assert length(positions) == 30
    end

    test "uses an area, in two or three dimensions" do
      space = space()
      {:ok, _} = :boids.populate(space, 10, tick: :manual, area: {{0, 0, 0}, {1, 2, 3}}, vel: {0, 0, 1})

      for %{pos: {x, y, z}, vel: vel} <- :boids.snapshot(space) do
        assert x >= 0 and x <= 1 and y >= 0 and y <= 2 and z >= 0 and z <= 3
        assert vel == {0, 0, 1}
      end
    end

    test "the area comes before the box of the space" do
      space = space(bounds: @box)
      {:ok, [id]} = :boids.populate(space, 1, tick: :manual, area: {{200, 200}, {201, 201}})
      {x, y} = pos(space, id)
      assert x >= 200 and y >= 200
    end

    test "no boid" do
      space = space(bounds: @box)
      assert :boids.populate(space, 0, %{}) == {:ok, []}
    end

    test "gives new ids, and a seed to each boid" do
      space = space(bounds: @box)
      {:ok, [a, b]} = :boids.populate(space, 2, id: :same, tick: :manual, seed: 5, rules: [wander: 1])
      assert a != b
      :boids.step(space, 0.1)
      {:ok, %{memory: %{wander: first}}} = :boids.boid(space, a)
      {:ok, %{memory: %{wander: second}}} = :boids.boid(space, b)
      assert first != second
    end

    test "the boid number N has the seed plus N" do
      space = space(bounds: @box, defaults: %{tick: :manual, rules: [wander: 1]})
      {:ok, [first, second]} = :boids.populate(space, 2, seed: 100)
      {:ok, one} = :boids.add(space, pos: {1, 1}, seed: 101)
      {:ok, two} = :boids.add(space, pos: {1, 1}, seed: 102)
      :boids.step(space, 0.1)
      point = fn id -> elem(:boids.boid(space, id), 1).memory.wander end
      assert point.(first) == point.(one)
      assert point.(second) == point.(two)
      assert point.(first) != point.(second)
    end

    test "refuses a bad option" do
      space = space()
      assert :boids.populate(space, 3, %{}) == {:error, {:bad_option, {:area, :undefined}}}

      assert :boids.populate(space, 3, area: {{0, 0}, {1, 1, 1}}) ==
               {:error, {:bad_option, {:area, {{0, 0}, {1, 1, 1}}}}}

      assert :boids.populate(space, 3, area: {{0}, {1}}) == {:error, {:bad_option, {:area, {{0}, {1}}}}}
      assert :boids.populate(space, 3, area: @box, mass: 0) == {:error, {:bad_option, {:mass, 0}}}
      assert :boids.populate(space, 3, area: @box, tick: -1) == {:error, {:bad_option, {:tick, -1}}}
      assert :boids.populate(space, 3, :many) == {:error, {:bad_option, :many}}
      assert :boids.count(space) == 0
      assert_raise FunctionClauseError, fn -> :boids.populate(space, -1, area: @box) end
    end
  end

  describe "the obstacles" do
    test "set_obstacle/4, obstacles/1 and remove_obstacle/2" do
      space = space()
      assert :boids.obstacles(space) == []
      assert :boids.set_obstacle(space, :rock, {5, 5}, 2) == :ok
      assert :boids.obstacles(space) == [%{id: :rock, pos: {5, 5}, radius: 2}]
      assert :boids.set_obstacle(:boids.space(space), :rock, {6, 5}, 2) == :ok
      assert :boids.obstacles(space) == [%{id: :rock, pos: {6, 5}, radius: 2}]
      assert :boids.remove_obstacle(space, :rock) == :ok
      assert :boids.obstacles(space) == []
    end

    test "a boid with the rule avoid moves around an obstacle" do
      space = space()
      :boids.set_obstacle(space, :rock, {30, 0}, 5)
      rules = [{:avoid, 3, lookahead: 2}, {:seek, 1, target: {60, 0.5}}]
      {:ok, id} = :boids.add(space, still(pos: {0, 0.5}, vel: {10, 0}, rules: rules, combine: :priority))

      nearest =
        Enum.reduce(1..200, 1.0e9, fn _, nearest ->
          :boids.step(space, 0.05)
          min(nearest, :boids_vec.dist(pos(space, id), {30, 0}))
        end)

      assert nearest > 5.0
      assert :boids_vec.dist(pos(space, id), {60, 0.5}) < 10
    end

    test "a boid without the rule goes through the obstacle" do
      space = space()
      :boids.set_obstacle(space, :rock, {30, 0}, 5)

      {:ok, id} =
        :boids.add(space, still(pos: {0, 0.5}, vel: {10, 0}, rules: [{:seek, 1, target: {60, 0.5}}]))

      nearest =
        Enum.reduce(1..200, 1.0e9, fn _, nearest ->
          :boids.step(space, 0.05)
          min(nearest, :boids_vec.dist(pos(space, id), {30, 0}))
        end)

      assert nearest < 1.0
    end
  end

  describe "a space" do
    # Boids at fixed positions, so that each run is the same.
    defp scatter(space, count, size, opts) do
      for n <- 1..count do
        pos = {rem(n * 37, size) + rem(n, 3) / 4, rem(n * 61, size) + rem(n, 5) / 6}
        angle = n * 2.399963
        vel = {4 * :math.cos(angle), 4 * :math.sin(angle)}

        {:ok, ^n} =
          :boids.add(space, Map.merge(%{id: n, pos: pos, vel: vel, tick: :manual, seed: n}, Map.new(opts)))
      end
    end

    test "with alignment, the boids move in one direction" do
      space = space(bounds: {{0, 0}, {50, 50}}, wrap: true)
      scatter(space, 50, 50, min_speed: 3)
      assert order(:boids.snapshot(space)) < 0.3
      for _ <- 1..400, do: :boids.step(space, 0.05)
      assert order(:boids.snapshot(space)) > 0.9
    end

    test "without alignment, the boids do not move in one direction" do
      space = space(bounds: {{0, 0}, {50, 50}}, wrap: true)
      scatter(space, 50, 50, min_speed: 3, rules: [separation: 1.5, wander: 1.0])
      for _ <- 1..400, do: :boids.step(space, 0.05)
      assert order(:boids.snapshot(space)) < 0.5
    end

    test "with separation, the boids keep a distance" do
      space = space()
      scatter(space, 30, 6, rules: [separation: 1.0], vel: {0, 0})

      nearest = fn ->
        Enum.min(for a <- :boids.snapshot(space), [_, b | _] = :boids.near(space, a.pos, 100), do: b.dist)
      end

      assert nearest.() < 0.5
      for _ <- 1..200, do: :boids.step(space, 0.05)
      assert nearest.() > 2.0
    end

    test "with cohesion, the boids come together" do
      space = space()
      scatter(space, 30, 40, rules: [cohesion: 1.0], perception: 100, vel: {0, 0})

      spread = fn ->
        rows = :boids.snapshot(space)
        center = :boids_vec.scale(Enum.reduce(rows, {0, 0}, &:boids_vec.add(&1.pos, &2)), 1 / length(rows))
        Enum.sum(for row <- rows, do: :boids_vec.dist(row.pos, center)) / length(rows)
      end

      before = spread.()
      for _ <- 1..100, do: :boids.step(space, 0.05)
      assert spread.() < before / 3
    end

    test "with contain, the boids stay in the box" do
      # The boids start 5 units or more from the sides.
      space = space(bounds: {{-5, -5}, {45, 45}})
      scatter(space, 30, 40, rules: [contain: 3.0, wander: 1.0], min_speed: 5, max_force: 40)

      for _ <- 1..400 do
        :boids.step(space, 0.05)
        for %{pos: {x, y}} <- :boids.snapshot(space), do: assert(x > -5 and x < 45 and y > -5 and y < 45)
      end
    end

    test "without contain, the boids go out of the box" do
      space = space(bounds: {{-5, -5}, {45, 45}})
      scatter(space, 30, 40, rules: [wander: 1.0], min_speed: 5, max_force: 40)
      for _ <- 1..400, do: :boids.step(space, 0.05)
      assert Enum.any?(:boids.snapshot(space), fn %{pos: {x, y}} -> x < -5 or x > 45 or y < -5 or y > 45 end)
    end

    test "with wrap, the boids stay in the box" do
      space = space(bounds: {{0, 0}, {40, 40}}, wrap: true)
      scatter(space, 30, 40, min_speed: 5)

      for _ <- 1..200 do
        :boids.step(space, 0.05)
        for %{pos: {x, y}} <- :boids.snapshot(space), do: assert(x >= 0 and x < 40 and y >= 0 and y < 40)
      end
    end

    test "a boid pursues a boid of another group, which flees" do
      space = space()

      {:ok, :cat} =
        :boids.add(
          space,
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
          space,
          still(id: :mouse, group: :mice, pos: {20, 0}, max_speed: 4, perception: 50, rules: mouse)
        )

      :boids.step(space, 0.05)
      # The cat is too far: the mouse does not move.
      assert pos(space, :mouse) == {20, 0}
      for _ <- 1..40, do: :boids.step(space, 0.05)
      {x, _} = pos(space, :mouse)
      assert x > 20
      for _ <- 1..100, do: :boids.step(space, 0.05)
      assert :boids_vec.dist(pos(space, :cat), pos(space, :mouse)) < 1.0
    end

    test "boids in three dimensions" do
      space = space(bounds: {{0, 0, 0}, {30, 30, 30}}, wrap: true)
      {:ok, ids} = :boids.populate(space, 40, tick: :manual, seed: 1, min_speed: 3)
      for _ <- 1..100, do: :boids.step(space, 0.05)

      for %{pos: {x, y, z}, vel: vel} <- :boids.snapshot(space) do
        assert x >= 0 and x < 30 and y >= 0 and y < 30 and z >= 0 and z < 30
        assert :boids_vec.norm(vel) <= 10.0 + 1.0e-9
      end

      assert length(ids) == 40
    end
  end

  describe "a process of yours as a boid" do
    test "join/2 adds the process to the space" do
      space = space(defaults: %{max_speed: 3, tick: :manual, seed: 1})
      assert {:ok, map, boid} = :boids.join(space, pos: {1, 2}, vel: {1, 0}, rules: [])
      assert map == :boids.space(space)
      assert %{id: id, pos: {1, 2}, max_speed: 3} = boid
      assert id == self()

      assert :boids.lookup(space, self()) ==
               {:ok, %{id: self(), pos: {1, 2}, vel: {1, 0}, group: :default, data: :undefined, pid: self()}}

      assert :boids.whereis(space, self()) == self()
    end

    test "plan/3 calculates a step, and commit/2 writes it" do
      space = space()
      {:ok, map, boid} = :boids.join(space, id: :me, pos: {1, 2}, vel: {2, 0}, rules: [])
      planned = :boids.plan(map, boid, 0.5)
      assert planned.pos == {2.0, 2.0}
      assert pos(space, :me) == {1, 2}
      assert :boids.commit(map, planned) == :ok
      assert pos(space, :me) == {2.0, 2.0}
    end

    test "advance/3 makes a step, with the scale of the time" do
      space = space()
      {:ok, map, boid} = :boids.join(space, id: :me, pos: {1, 2}, vel: {2, 0}, rules: [])
      boid = :boids.advance(map, boid, 0.5)
      assert boid.pos == {2.0, 2.0}
      assert pos(space, :me) == {2.0, 2.0}
      :boids.set_time_scale(space, 2)
      assert :boids.advance(map, boid, 0.5).pos == {4.0, 2.0}
    end

    test "a change of the boid goes to the space with commit/2" do
      space = space()
      {:ok, map, boid} = :boids.join(space, id: :me, pos: {1, 2})
      changed = :boids_boid.update(boid, %{group: :leaders, data: :gold, pos: {40, 40}})
      :ok = :boids.commit(map, changed)
      assert {:ok, %{group: :leaders, data: :gold, pos: {40, 40}}} = :boids.lookup(space, :me)
    end

    test "leave/2 removes the boid" do
      space = space()
      {:ok, map, boid} = :boids.join(space, pos: {1, 2})
      assert :boids.leave(map, boid) == :ok
      assert :boids.count(space) == 0
      assert :boids.leave(map, boid) == :ok
      # After leave/2, a commit adds no row.
      assert :boids.commit(map, boid) == :ok
      assert :boids.count(space) == 0
      assert {:ok, _, _} = :boids.join(space, pos: {1, 2})
    end

    test "refuses an id that is in the space, and a bad option" do
      space = space()
      {:ok, _, _} = :boids.join(space, id: :me, pos: {1, 2})
      assert :boids.join(space, id: :me, pos: {3, 4}) == {:error, {:exists, :me}}
      assert :boids.join(space, id: :other) == {:error, {:bad_option, {:pos, :undefined}}}
      assert :boids.join(space, id: :other, pos: {0, 0}, tick: 0) == {:error, {:bad_option, {:tick, 0}}}
      # The options of the process of add/2 are permitted, and not used.
      assert {:ok, _, _} =
               :boids.join(space, id: :other, pos: {0, 0}, tick: 5, priority: :normal, hibernate: false)

      :ok = :boids_space_server.leave(:boids.space(space), :other, self())
      assert :boids.join(space, :me) == {:error, {:bad_option, :me}}
      assert :boids.count(space) == 1
    end

    test "one process can have many boids" do
      space = space()
      {:ok, _, _} = :boids.join(space, id: :a, pos: {1, 2})
      {:ok, _, _} = :boids.join(space, id: :b, pos: {1, 2})
      assert :boids.count(space) == 2
    end

    test "the space removes the boid when the process stops" do
      space = space()
      me = self()

      pid =
        spawn(fn ->
          {:ok, _, _} = :boids.join(space, id: :a, pos: {1, 2})
          {:ok, _, _} = :boids.join(space, id: :b, pos: {1, 2})
          send(me, :joined)
          Process.sleep(:infinity)
        end)

      assert_receive :joined
      assert :boids.count(space) == 2
      assert :boids.whereis(space, :a) == pid
      Process.exit(pid, :kill)
      assert eventually(fn -> :boids.count(space) == 0 end)
    end

    test "the functions for a boid of add/2 do not find it" do
      space = space()
      {:ok, _, _} = :boids.join(space, id: :me, pos: {1, 2})
      assert :boids.boid(space, :me) == {:error, :not_found}
      assert :boids.update(space, :me, %{max_speed: 1}) == {:error, :not_found}
      assert :boids.remove(space, :me) == {:error, :not_found}
      assert :boids.step(space, 1) == :ok
      assert pos(space, :me) == {1, 2}
    end

    test "the boids of add/2 see it" do
      space = space()
      {:ok, map, me} = :boids.join(space, id: :leader, pos: {10, 0}, vel: {0, 1}, rules: [])

      {:ok, id} =
        :boids.add(space, still(perception: 5, rules: [{:pursue, 1, target: {:boid, :leader}, max_time: 0}]))

      :boids.step(space, 0.1)
      {x, y} = pos(space, id)
      assert x > 0 and y == 0
      # It also sees the boids of add/2.
      assert [%{id: ^id}] = :boids_boid.perceive(me, :boids.near(map, me.pos, 100))
    end

    test "a new process can use the id of a process that stopped" do
      space = space()
      map = :boids.space(space)
      {pid, ref} = spawn_monitor(fn -> :ok end)
      assert_receive {:DOWN, ^ref, _, _, _}
      # The row of a process that stopped, before the space sees its end.
      true = :boids_space.insert_new(map, %{id: :a, pos: {9, 9}, vel: {0, 0}, pid: pid})
      assert {:ok, _, _} = :boids.join(space, id: :a, pos: {1, 2})
      assert {:ok, %{pos: {1, 2}, pid: owner}} = :boids.lookup(space, :a)
      assert owner == self()
      assert :boids.count(space) == 1
    end

    test "a row with no process keeps its id" do
      space = space()
      true = :boids_space.insert_new(:boids.space(space), %{id: :a, pos: {9, 9}, vel: {0, 0}})
      assert :boids.join(space, id: :a, pos: {1, 2}) == {:error, {:exists, :a}}
    end
  end
end
