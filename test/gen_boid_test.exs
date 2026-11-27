defmodule GenBoidTest do
  use ExUnit.Case, async: true
  import Boids.Helpers

  alias Boids.TestBoids.{Hawk, Mouse}

  @moduletag :capture_log

  setup do
    {:ok, space} = :boids.start_space(defaults: %{tick: :manual})
    on_exit(fn -> :boids.stop_space(space) end)
    %{space: space}
  end

  defp hawk(space, args \\ %{}) do
    {:ok, pid} = :gen_boid.start(Hawk, Map.new(args), space: space)
    pid
  end

  defp row(space, id) do
    {:ok, row} = :boids.lookup(space, id)
    row
  end

  describe "start/3" do
    test "starts a boid below the supervisor of its space, with the options of init/1", %{space: space} do
      pid = hawk(space, boid: %{id: :hawk, pos: {1, 2}, max_speed: 3})
      assert :boids.whereis(space, :hawk) == pid
      assert {:ok, %{id: :hawk, pos: {1, 2}, group: :hawks, max_speed: 3}} = :boids.boid(space, :hawk)
      assert :boids_space.owner(:boids.space(space), :hawk) == {:server, pid}
      assert {:ok, %{id: :hawk, pid: ^pid}} = :boids.lookup(space, :hawk)
      assert :proc_lib.get_label(pid) == {:boids, :boid, :hawk}
      # The supervisor of the space stops it with the space.
      assert :boids.stop_space(space) == :ok
      refute Process.alive?(pid)
    end

    test "accepts the map of the space, a map of options, and a name", %{space: space} do
      assert {:ok, pid} =
               :gen_boid.start(Mouse, %{pos: {0, 0}}, %{space: :boids.space(space), name: :boids_test_mouse})

      assert Process.whereis(:boids_test_mouse) == pid

      assert {:ok, other} =
               :gen_boid.start(Mouse, %{pos: {0, 0}}, space: space, name: {:global, :boids_test_mouse})

      assert :global.whereis_name(:boids_test_mouse) == other
      assert :gen_boid.stop({:global, :boids_test_mouse}) == :ok
      assert :gen_boid.stop(:boids_test_mouse) == :ok
      assert eventually(fn -> :boids.count(space) == 0 end)
    end

    test "gives what init/1 gives when the boid does not start", %{space: space} do
      assert :gen_boid.start(Hawk, :ignore, space: space) == :ignore
      assert :gen_boid.start(Hawk, {:stop, :no_sky}, space: space) == {:error, :no_sky}
      assert :gen_boid.start(Mouse, %{}, space: space) == {:error, {:bad_option, {:pos, :undefined}}}

      assert :gen_boid.start(Mouse, %{pos: {0, 0}, tick: 0}, space: space) ==
               {:error, {:bad_option, {:tick, 0}}}

      assert :gen_boid.start(Mouse, %{pos: {0, 0}, seed: :random}, space: space) ==
               {:error, {:bad_option, {:seed, :random}}}

      assert :gen_boid.start(Mouse, :cheese, space: space) == {:error, {:bad_option, :cheese}}
      {:ok, _} = :gen_boid.start(Mouse, %{id: :a, pos: {0, 0}}, space: space)
      assert :gen_boid.start(Mouse, %{id: :a, pos: {0, 0}}, space: space) == {:error, {:exists, :a}}
      assert :boids.count(space) == 1
    end

    test "refuses bad options of the start", %{space: space} do
      assert catch_error(:gen_boid.start(Mouse, %{pos: {0, 0}}, [])) == {:bad_option, {:space, :undefined}}
      assert catch_error(:gen_boid.start(Mouse, %{}, space: space, speed: 1)) == {:bad_option, {:speed, 1}}
      assert catch_error(:gen_boid.start_link(Mouse, %{}, :here)) == {:bad_option, :here}
      assert :boids.count(space) == 0
    end

    test "a seed in the options of init/1 gives the random numbers of the process", %{space: space} do
      start = fn id, pos, seed ->
        {:ok, _} = :gen_boid.start(Mouse, %{id: id, pos: pos, seed: seed, rules: [wander: 1]}, space: space)
      end

      start.(:a, {0, 0}, 42)
      start.(:b, {50, 50}, 42)
      start.(:c, {90, 90}, 43)
      for _ <- 1..10, do: :boids.step(space, 0.1)
      assert_vec(:boids_vec.sub(row(space, :b).pos, {50, 50}), row(space, :a).pos)
      refute :boids_vec.sub(row(space, :c).pos, {90, 90}) == row(space, :a).pos
    end
  end

  describe "start_link/3" do
    test "starts a boid with a link to the caller", %{space: space} do
      assert {:ok, pid} = :gen_boid.start_link(Mouse, %{pos: {0, 0}}, space: space)
      assert {:links, links} = Process.info(self(), :links)
      assert pid in links
      assert {:ok, named} = :gen_boid.start_link(Mouse, %{pos: {0, 0}}, space: space, name: :boids_test_link)
      assert Process.whereis(:boids_test_link) == named

      assert {:ok, via} =
               :gen_boid.start_link(Mouse, %{pos: {0, 0}},
                 space: space,
                 name: {:via, :global, :boids_test_link}
               )

      assert :global.whereis_name(:boids_test_link) == via
      assert :gen_boid.start_link(Hawk, :ignore, space: space) == :ignore
      for boid <- [pid, named, via], do: :gen_boid.stop(boid)
    end
  end

  describe "the boid is the state" do
    test "the key state of the options of init/1 is the state of the module", %{space: space} do
      pid = hawk(space, boid: %{id: :hawk})
      assert %{steps: 0, acts: 0} = :gen_boid.call(pid, :state)
      assert {:ok, %{state: %{steps: 0}}} = :boids.boid(space, :hawk)
      # The other boids do not see it.
      refute Map.has_key?(row(space, :hawk), :state)
    end

    test "a module with only init/1 follows its rules", %{space: space} do
      {:ok, _} = :gen_boid.start(Mouse, %{id: :mouse, pos: {0, 0}, vel: {1, 0}, rules: []}, space: space)
      :boids.step(space, 1)
      assert row(space, :mouse).pos == {1.0, 0.0}
      assert {:ok, %{state: :undefined}} = :boids.boid(space, :mouse)
    end
  end

  describe "handle_sense/2" do
    test "runs at each step, with what the boid perceives", %{space: space} do
      me = self()

      defmodule Looks do
        @behaviour :gen_boid
        def init({owner, options}), do: {:ok, Map.put(options, :state, owner)}

        def handle_sense(seen, boid) do
          send(boid.state, {:seen, seen})
          {:ok, seen, boid}
        end
      end

      {:ok, _} = :gen_boid.start(Looks, {me, %{id: :a, pos: {0, 0}}}, space: space)
      {:ok, :b} = :boids.add(space, id: :b, pos: {3, 0})
      :ok = :boids.set_obstacle(space, :rock, {5, 5}, 1)
      :boids.step(space, 0.5)

      assert_received {:seen,
                       %{
                         neighbors: [%{id: :b, pos: {3, 0}, dist: 3.0}],
                         obstacles: [%{id: :rock}],
                         bounds: :undefined,
                         wrap: false,
                         dt: 0.5
                       }}
    end

    test "adds keys of yours, which handle_decide/2 and the rules get", %{space: space} do
      me = self()

      defmodule Smells do
        @behaviour :gen_boid
        def init(options), do: {:ok, options}
        def handle_sense(seen, boid), do: {:ok, Map.put(seen, :food, {10, 0}), boid}

        def handle_decide(%{food: food}, boid), do: {:ok, %{boid | data: {:goes_to, food}}}
      end

      to_food = fn boid, _neighbors, env ->
        send(me, {:rule, env.food})
        :boids_steer.seek(boid, env.food)
      end

      {:ok, _} =
        :gen_boid.start(Smells, %{id: :a, pos: {0, 0}, max_force: 100, rules: [{to_food, 1}]}, space: space)

      :boids.step(space, 0.1)
      assert_received {:rule, {10, 0}}
      assert %{pos: {x, +0.0}, data: {:goes_to, {10, 0}}} = row(space, :a)
      assert x > 0
    end

    test "can change the neighbors that the rules get", %{space: space} do
      defmodule Blind do
        @behaviour :gen_boid
        def init(options), do: {:ok, options}
        def handle_sense(seen, boid), do: {:ok, %{seen | neighbors: []}, boid}
      end

      options = %{pos: {0, 0}, max_force: 100, rules: [cohesion: 1]}
      {:ok, _} = :gen_boid.start(Blind, Map.put(options, :id, :blind), space: space)
      {:ok, _} = :gen_boid.start(Mouse, %{options | pos: {0, 4}} |> Map.put(:id, :mouse), space: space)
      :boids.step(space, 0.1)
      # The boid that sees its neighbor moves to it. The other boid stays.
      assert row(space, :blind).pos == {0, 0}
      assert {+0.0, y} = row(space, :mouse).pos
      assert y < 4
    end
  end

  describe "handle_decide/2" do
    test "runs at each step, before the forces", %{space: space} do
      pid = hawk(space, boid: %{id: :hawk, max_speed: 2})
      :boids.step(space, 1)
      :boids.step(space, 1)
      assert :gen_boid.call(pid, :steps) == 2
      # With no mouse, the hawk does not move.
      assert row(space, :hawk).pos == {0.0, 0.0}
    end

    test "its changes are for this step and the next steps", %{space: space} do
      pid = hawk(space, boid: %{id: :hawk, max_speed: 2, max_force: 100})
      {:ok, _} = :gen_boid.start(Mouse, %{id: :mouse, pos: {5, 0}, group: :mice, rules: []}, space: space)
      :boids.step(space, 1)
      assert %{pos: {2.0, +0.0}, data: {:hunts, :mouse}} = row(space, :hawk)
      assert {:ok, %{rules: [{:seek, 1, %{target: {5, 0}}}]}} = :boids.boid(space, :hawk)
      :boids.step(space, 1)
      assert row(space, :hawk).pos == {4.0, 0.0}
      assert :gen_boid.call(pid, :steps) == 2
    end

    test "runs at each tick of the clock of the boid", %{space: space} do
      pid = hawk(space, boid: %{tick: 5})
      assert eventually(fn -> :gen_boid.call(pid, :steps) > 3 end)
    end
  end

  describe "handle_act/1" do
    test "runs at each step, after the movement", %{space: space} do
      pid = hawk(space, boid: %{id: :hawk, vel: {1, 0}})
      :boids.step(space, 1)
      # The module saw the boid at its new position.
      assert %{acts: 1, at: {1.0, +0.0}} = :gen_boid.call(pid, :state)
      :boids.step(space, 1)
      assert %{acts: 2, at: {2.0, +0.0}} = :gen_boid.call(pid, :state)
      assert row(space, :hawk).pos == {2.0, 0.0}
    end

    test "its change of the boid is in the row of the boid", %{space: space} do
      defmodule Counts do
        @behaviour :gen_boid
        def init(options), do: {:ok, options}
        def handle_act(boid), do: {:ok, %{boid | data: (boid.data || 0) + 1}}
      end

      {:ok, _} =
        :gen_boid.start(Counts, %{id: :a, pos: {0, 0}, vel: {1, 0}, rules: [], data: nil}, space: space)

      :boids.step(space, 1)
      assert %{pos: {1.0, +0.0}, data: 1} = row(space, :a)
      :boids.step(space, 1)
      assert %{pos: {2.0, +0.0}, data: 2} = row(space, :a)
    end
  end

  describe "a callback of a step" do
    test "can stop the boid in a step of boids:step/2, and the step continues", %{space: space} do
      for stage <- [:sense, :decide, :act] do
        pid = hawk(space, owner: self(), stop_at: 1, stop_in: stage, boid: %{id: stage})
        {:ok, other} = :boids.add(space, pos: {5, 5}, vel: {1, 0}, rules: [])
        assert :boids.step(space, 1) == :ok
        # The steps continue for the other boids.
        assert :boids.step(space, 1) == :ok
        assert_receive {:terminated, :normal, ^stage, 1}
        assert row(space, other).pos == {7.0, 5.0}
        assert eventually(fn -> not Process.alive?(pid) and :boids.whereis(space, stage) == :undefined end)
        assert :boids.step(space, 1) == :ok
        :ok = :boids.remove(space, other)
      end
    end

    test "can stop the boid at a tick", %{space: space} do
      for stage <- [:sense, :decide, :act] do
        pid = hawk(space, owner: self(), stop_at: 2, stop_in: stage, boid: %{id: stage, tick: 5})
        assert_receive {:terminated, :normal, ^stage, 2}
        assert eventually(fn -> not Process.alive?(pid) and :boids.count(space) == 0 end)
      end
    end

    test "that gives a boid with another id stops the process with an error", %{space: space} do
      for stage <- [:sense, :decide, :act] do
        pid = hawk(space, other_id_in: stage, boid: %{id: stage})
        ref = Process.monitor(pid)
        assert :boids.step(space, 1) == :ok
        assert_receive {:DOWN, ^ref, _, _, {reason, _stack}}
        assert elem(reason, 0) in [:else_clause, :case_clause]
        assert eventually(fn -> :boids.count(space) == 0 end)
      end

      pid = hawk(space)
      assert {{:function_clause, _}, _} = catch_exit(:gen_boid.call(pid, :other_id))
    end
  end

  describe "the neighbors that a boid knows" do
    # What the hawk saw at its last step: the ids and the positions.
    defp seen(pid), do: :gen_boid.call(pid, :state).seen

    test "with the option search, a boid searches the space at one step of some", %{space: space} do
      pid = hawk(space, boid: %{id: :hawk, search: 3, max_speed: 0})
      still = %{group: :mice, rules: [], max_speed: 0}
      {:ok, :m} = :boids.add(space, Map.merge(still, %{id: :m, pos: {5, 0}}))
      # The first step: a search.
      :boids.step(space, 0.1)
      assert seen(pid) == [m: {5, 0}]
      # Between two searches, the boid sees a neighbor that it knows where
      # that neighbor is now. It does not see a boid that came after the
      # search.
      :ok = :boids.update(space, :m, %{pos: {6, 0}})
      {:ok, :n} = :boids.add(space, Map.merge(still, %{id: :n, pos: {2, 0}}))
      :boids.step(space, 0.1)
      assert seen(pid) == [m: {6, 0}]
      # It does not see a neighbor that went from the space.
      :ok = :boids.remove(space, :m)
      :boids.step(space, 0.1)
      assert seen(pid) == []
      # The fourth step: a search again.
      :boids.step(space, 0.1)
      assert seen(pid) == [n: {2, 0}]
      # A neighbor that it knows and that is too far is not a neighbor.
      :ok = :boids.update(space, :n, %{pos: {50, 0}})
      :boids.step(space, 0.1)
      assert seen(pid) == []
    end

    test "with a search at each step, a boid sees each boid that comes", %{space: space} do
      pid = hawk(space, boid: %{id: :hawk, max_speed: 0})
      :boids.step(space, 0.1)
      assert seen(pid) == []
      {:ok, :n} = :boids.add(space, id: :n, pos: {2, 0}, rules: [], max_speed: 0)
      :boids.step(space, 0.1)
      assert seen(pid) == [n: {2, 0}]
    end

    test "a boid with a clock uses the option too", %{space: space} do
      pid = hawk(space, boid: %{id: :hawk, search: 2, tick: 5, max_speed: 0})
      {:ok, :n} = :boids.add(space, id: :n, pos: {2, 0}, rules: [], max_speed: 0)
      assert eventually(fn -> seen(pid) == [n: {2, 0}] end)
      steps = :gen_boid.call(pid, :steps)
      assert eventually(fn -> :gen_boid.call(pid, :steps) > steps + 4 end)
      assert seen(pid) == [n: {2, 0}]
    end

    test "the option is an integer of 1 or more", %{space: space} do
      for bad <- [0, -1, 1.5, :all] do
        assert :gen_boid.start(Mouse, %{pos: {0, 0}, search: bad}, space: space) ==
                 {:error, {:bad_option, {:search, bad}}}
      end

      assert {%{search: 4}, %{}} = :gen_boid.options(%{search: 4})
    end
  end

  describe "call/2, call/3 and handle_call/3" do
    test "gives the answer of the module, which sees the boid", %{space: space} do
      pid = hawk(space, boid: %{pos: {3, 4}})
      assert :gen_boid.call(pid, :where) == {3, 4}
      assert :gen_boid.call(pid, :steps, 1000) == 0
    end

    test "a boid that the module changed is in the space", %{space: space} do
      pid = hawk(space, boid: %{id: :hawk})
      assert :gen_boid.call(pid, {:go, {7, 7}}) == :ok
      assert row(space, :hawk).pos == {7, 7}
      assert :gen_boid.call(pid, :where) == {7, 7}
    end

    test "the module can answer later, with reply/2", %{space: space} do
      pid = hawk(space, boid: %{id: :hawk})
      assert :gen_boid.call(pid, :later) == {:later, :hawks}
      assert :gen_boid.call(pid, {:later, :eagles}) == {:later, :eagles}
      assert row(space, :hawk).group == :eagles
    end

    test "the module can stop the boid, with or without an answer", %{space: space} do
      first = hawk(space, owner: self(), boid: %{id: :first})
      assert :gen_boid.call(first, :stop) == :bye
      assert_receive {:terminated, :normal, :first, 0}
      second = hawk(space, owner: self(), boid: %{id: :second})

      assert catch_exit(:gen_boid.call(second, :fail)) ==
               {:normal, {:gen_server, :call, [second, {:"$gen_boid", :fail}]}}

      assert_receive {:terminated, :normal, :second, 0}
      assert eventually(fn -> :boids.count(space) == 0 end)
    end

    test "a module without it stops the boid at a call", %{space: space} do
      {:ok, pid} = :gen_boid.start(Mouse, %{pos: {0, 0}}, space: space)
      assert {{:bad_call, :hello}, _} = catch_exit(:gen_boid.call(pid, :hello))
      assert eventually(fn -> :boids.count(space) == 0 end)
    end

    test "the functions of boids for a boid do not go to the module", %{space: space} do
      {:ok, pid} = :gen_boid.start(Mouse, %{id: :mouse, pos: {0, 0}}, space: space)
      assert {:ok, %{id: :mouse}} = :boids.boid(space, :mouse)
      assert :boids.update(space, :mouse, %{max_speed: 2}) == :ok
      assert :boids.update(space, :mouse, %{max_speed: -2}) == {:error, {:bad_option, {:max_speed, -2}}}
      assert {:ok, %{max_speed: 2}} = :boids.boid(space, :mouse)
      assert :boids.remove(space, :mouse) == :ok
      refute Process.alive?(pid)
    end
  end

  describe "add_rule/2, delete_rule/2 and which_rules/1" do
    test "change the rules of a boid, from its next step", %{space: space} do
      {:ok, pid} = :gen_boid.start(Mouse, %{id: :mouse, pos: {0, 0}, max_force: 100, rules: []}, space: space)
      assert :gen_boid.which_rules(pid) == []
      assert :gen_boid.add_rule(pid, {{:seek, :home}, 1, target: {10, 0}}) == :ok
      assert :gen_boid.add_rule(pid, {:wander, 0}) == :ok
      assert :gen_boid.which_rules(pid) == [{:seek, :home}, :wander]
      :boids.step(space, 0.1)
      {x, y} = row(space, :mouse).pos
      assert x > 0 and y == 0
      assert :gen_boid.delete_rule(pid, {:seek, :home}) == :ok
      assert :gen_boid.delete_rule(pid, :cruise) == :ok
      assert :gen_boid.which_rules(pid) == [:wander]
      assert :gen_boid.add_rule(pid, {:seek, 1}) == {:error, {:bad_option, {:rules, {:seek, 1, %{}}}}}
      assert :gen_boid.which_rules(pid) == [:wander]
    end

    test "the functions of boids with the id of the boid do the same", %{space: space} do
      {:ok, pid} = :gen_boid.start(Mouse, %{id: :mouse, pos: {0, 0}, rules: [avoid: 1]}, space: space)
      assert :boids.add_rule(space, :mouse, {{:seek, :home}, 1, target: {10, 0}}) == :ok
      assert :boids.which_rules(space, :mouse) == {:ok, [:avoid, {:seek, :home}]}
      assert :boids.delete_rule(space, :mouse, :avoid) == :ok
      assert :gen_boid.which_rules(pid) == [{:seek, :home}]
      assert :boids.add_rule(space, :mouse, :seek) == {:error, {:bad_option, {:rules, :seek}}}
    end
  end

  describe "a change of the boid between the two parts of a step" do
    setup %{space: space} do
      pid = hawk(space, boid: %{id: :hawk, vel: {1, 0}})
      # A second part with no first part changes nothing.
      assert GenServer.call(pid, :commit) == :ok
      assert row(space, :hawk).pos == {0, 0}
      # The first part of a step: the boid calculates, and does not move.
      assert GenServer.call(pid, {:plan, 1}) == :ok
      assert row(space, :hawk).pos == {0, 0}
      %{pid: pid}
    end

    test "without a change, the boid moves in the second part", %{space: space, pid: pid} do
      assert GenServer.call(pid, :commit) == :ok
      assert row(space, :hawk).pos == {1.0, 0.0}
      assert %{acts: 1} = :gen_boid.call(pid, :state)
    end

    test "a change with update/3 removes the step", %{space: space, pid: pid} do
      :ok = :boids.update(space, :hawk, %{pos: {7, 7}})
      assert GenServer.call(pid, :commit) == :ok
      assert row(space, :hawk).pos == {7, 7}
      assert %{acts: 0} = :gen_boid.call(pid, :state)
    end

    test "a change in handle_call/3, handle_cast/2 or handle_info/2 removes the step", %{space: space} do
      for {change, key, value} <- [
            {&:gen_boid.call(&1, {:go, {7, 7}}), :pos, {7, 7}},
            {&:gen_boid.cast(&1, {:data, :blue}), :data, :blue},
            {&send(&1, {:speed, 4}), :vel, {1, 0}}
          ] do
        pid = hawk(space, boid: %{id: key, vel: {1, 0}})
        assert GenServer.call(pid, {:plan, 1}) == :ok
        change.(pid)
        assert GenServer.call(pid, :commit) == :ok
        row = row(space, key)
        assert Map.fetch!(row, key) == value
        assert row.pos in [{0, 0}, {7, 7}]
      end
    end

    test "a callback that does not change the boid keeps the step", %{space: space, pid: pid} do
      # Before the second part, the boid is as it was before the step.
      assert :gen_boid.call(pid, :steps) == 0
      send(pid, :hello)
      assert GenServer.call(pid, :commit) == :ok
      assert row(space, :hawk).pos == {1.0, 0.0}
      assert :gen_boid.call(pid, :steps) == 1
    end
  end

  describe "cast/2 and handle_cast/2" do
    test "the module gets the request, and can change the boid or its state", %{space: space} do
      pid = hawk(space, boid: %{id: :hawk})
      assert :gen_boid.cast(pid, {:data, :blue}) == :ok
      assert :gen_boid.cast(pid, :count) == :ok
      assert :gen_boid.call(pid, :steps) == 100
      assert row(space, :hawk).data == :blue
    end

    test "the module can stop the boid", %{space: space} do
      pid = hawk(space, owner: self(), boid: %{id: :hawk})
      :gen_boid.cast(pid, :stop)
      assert_receive {:terminated, :normal, :hawk, 0}
    end

    test "a module without it stops the boid at a cast, and other casts change nothing", %{space: space} do
      {:ok, pid} = :gen_boid.start(Mouse, %{pos: {0, 0}}, space: space)
      GenServer.cast(pid, :hello)
      assert {:ok, _} = :boids.boid(space, pid)
      ref = Process.monitor(pid)
      :gen_boid.cast(pid, :hello)
      assert_receive {:DOWN, ^ref, _, _, {:bad_cast, :hello}}
    end
  end

  describe "handle_info/2" do
    test "the module gets each other message, and can change the boid", %{space: space} do
      pid = hawk(space, boid: %{id: :hawk})
      send(pid, {:speed, 4})
      send(pid, :hello)
      assert {:ok, %{max_speed: 4}} = :boids.boid(space, :hawk)
    end

    test "the module can stop the boid", %{space: space} do
      pid = hawk(space, owner: self(), boid: %{id: :hawk})
      send(pid, :stop)
      assert_receive {:terminated, :normal, :hawk, 0}
    end

    test "a module without it does not see the messages", %{space: space} do
      {:ok, pid} = :gen_boid.start(Mouse, %{pos: {0, 0}}, space: space)
      send(pid, :hello)
      assert {:ok, _} = :boids.boid(space, pid)
    end
  end

  describe "terminate/2" do
    test "runs at stop/1, with the reason and the boid", %{space: space} do
      pid = hawk(space, owner: self(), boid: %{id: :hawk})
      assert :gen_boid.stop(pid) == :ok
      assert_receive {:terminated, :normal, :hawk, 0}
    end

    test "runs when the space stops, for a module that traps exits", %{space: space} do
      hawk(space, owner: self(), trap: true, boid: %{id: :hawk})
      :boids.stop_space(space)
      assert_receive {:terminated, :shutdown, :hawk, 0}
    end

    test "a module without it stops with no call", %{space: space} do
      {:ok, pid} = :gen_boid.start(Mouse, %{pos: {0, 0}}, space: space)
      assert :gen_boid.stop(pid) == :ok
      refute Process.alive?(pid)
    end
  end

  test "the example of the documentation: a hawk that hunts, and that uses its energy", %{space: space} do
    defmodule HawkOfTheDocs do
      @behaviour :gen_boid
      def init(pos) do
        {:ok,
         %{
           pos: pos,
           group: :hawks,
           perception: 25,
           max_force: 100,
           rules: [{:wander, 1.0}],
           state: %{energy: 10.0}
         }}
      end

      def handle_sense(%{neighbors: neighbors} = seen, boid) do
        {:ok, Map.put(seen, :prey, Enum.filter(neighbors, &(&1.group == :birds))), boid}
      end

      def handle_decide(%{prey: [_ | _]}, %{state: %{energy: energy}} = boid) when energy > 2 do
        {:ok, :boids_boid.update(boid, %{rules: [{:pursue, 1.0, %{target: {:group, :birds}}}]})}
      end

      def handle_decide(_seen, boid), do: {:ok, :boids_boid.update(boid, %{rules: [{:wander, 1.0}]})}

      def handle_act(%{vel: vel, state: %{energy: energy} = state} = boid) do
        {:ok, %{boid | state: %{state | energy: energy - 0.01 * :boids_vec.norm(vel)}}}
      end

      def handle_call(:energy, _from, %{state: %{energy: energy}} = boid), do: {:reply, energy, boid}
    end

    {:ok, hawk} = :gen_boid.start_link(HawkOfTheDocs, {50, 50}, space: space)
    assert :gen_boid.call(hawk, :energy) == 10.0
    {:ok, _} = :boids.add(space, id: :bird, pos: {60, 50}, group: :birds, rules: [])
    :boids.step(space, 0.05)
    assert :gen_boid.which_rules(hawk) == [:pursue]
    for _ <- 1..60, do: :boids.step(space, 0.05)
    # The hawk came to the bird, and it used energy.
    {:ok, %{pos: pos}} = :boids.boid(space, hawk)
    assert :boids_vec.dist(pos, {60, 50}) < 2
    energy = :gen_boid.call(hawk, :energy)
    assert energy < 10.0
    # With too little energy, the hawk wanders.
    for _ <- 1..2000, :gen_boid.call(hawk, :energy) > 2, do: :boids.step(space, 0.05)
    :boids.step(space, 0.05)
    assert :gen_boid.which_rules(hawk) == [:wander]
    :gen_boid.stop(hawk)
  end
end
