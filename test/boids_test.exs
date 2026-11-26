defmodule BoidsTest do
  use ExUnit.Case, async: true
  import Boids.Helpers

  @box {{0, 0}, {100, 100}}

  # A flock that stops at the end of the test.
  defp flock(opts \\ %{}) do
    {:ok, flock} = :boids.start_flock(opts)
    on_exit(fn -> :boids.stop_flock(flock) end)
    flock
  end

  # A boid with no rule and no clock: it moves only with step/2.
  defp still(more \\ %{}), do: Map.merge(%{pos: {0, 0}, rules: [], tick: :manual}, Map.new(more))

  # Only a process that hibernates has a heap smaller than the minimum
  # heap of a new process.
  defp hibernates?(pid) do
    {:total_heap_size, words} = Process.info(pid, :total_heap_size)
    words < 233
  end

  defp pos(flock, id) do
    {:ok, %{pos: pos}} = :boids.lookup(flock, id)
    pos
  end

  describe "start_flock/1 and stop_flock/1" do
    test "starts the process of a flock, with its space" do
      {:ok, flock} = :boids.start_flock()
      assert Process.alive?(flock)
      space = :boids.space(flock)
      assert %{owner: ^flock, cell_size: 10.0, bounds: :undefined, wrap: false, defaults: %{}} = space
      assert :boids.space(space) == space
      assert :boids.count(flock) == 0
      assert :boids.snapshot(flock) == []
      assert :boids.stop_flock(flock) == :ok
      refute Process.alive?(flock)
      assert :ets.info(space.rows) == :undefined
      assert :boids.stop_flock(flock) == {:error, :not_found}
      assert :boids.stop_flock(space) == {:error, :not_found}
    end

    test "the processes that control a flock have a high priority" do
      flock = flock()
      space = :boids.space(flock)
      assert Process.info(flock, :priority) == {:priority, :high}
      assert Process.info(:boids_flock.sup(flock), :priority) == {:priority, :high}
      assert Process.info(:boids_flock.boid_sup(space), :priority) == {:priority, :high}
      # A boid has a low priority, or the priority of the other processes.
      {:ok, id} = :boids.add(flock, still())
      assert Process.info(id, :priority) == {:priority, :low}
      {:ok, id} = :boids.add(flock, still(priority: :normal))
      assert Process.info(id, :priority) == {:priority, :normal}
    end

    test "accepts a list of options" do
      flock = flock(bounds: @box, wrap: true, cell_size: 5, defaults: %{max_speed: 3})
      assert %{bounds: @box, wrap: true, cell_size: 5, defaults: %{max_speed: 3}} = :boids.space(flock)
    end

    test "gives a name to the flock" do
      flock = flock(name: :boids_test_named)
      assert Process.whereis(:boids_test_named) == flock
      assert :boids.count(:boids_test_named) == 0
      global = flock(name: {:global, :boids_test_global})
      assert :global.whereis_name(:boids_test_global) == global
      assert :boids.count({:global, :boids_test_global}) == 0
      via = flock(name: {:via, :global, :boids_test_via})
      assert :boids.count({:via, :global, :boids_test_via}) == 0
      assert :boids.stop_flock({:via, :global, :boids_test_via}) == :ok
      refute Process.alive?(via)
    end

    @tag :capture_log
    test "refuses a name that another process has" do
      flock = flock(name: :boids_test_twice)
      assert :boids.start_flock(name: :boids_test_twice) == {:error, {:already_started, flock}}
    end

    test "refuses a bad option" do
      for {key, value} <- [
            cell_size: 0,
            wrap: true,
            bounds: {{0, 0}, {0, 0}},
            name: "flock",
            name: {:local, :flock},
            name: {:via, "module", :flock},
            defaults: [max_speed: 1],
            color: :red
          ] do
        assert :boids.start_flock(%{key => value}) == {:error, {:bad_option, {key, value}}}
      end

      assert :boids.start_flock(defaults: %{max_speed: -1}) == {:error, {:bad_option, {:max_speed, -1}}}
      assert :boids.start_flock(defaults: %{tick: 0}) == {:error, {:bad_option, {:tick, 0}}}
      assert :boids.start_flock(defaults: %{shape: :bird}) == {:error, {:bad_option, {:shape, :bird}}}
      assert :boids.start_flock(:big) == {:error, {:bad_option, :big}}
      assert :boids.start_flock([:big]) == {:error, {:bad_option, [:big]}}
    end

    test "stops the boids of the flock" do
      {:ok, flock} = :boids.start_flock()
      {:ok, id} = :boids.add(flock, still())
      pid = :boids.whereis(flock, id)
      assert Process.alive?(pid)
      assert :boids.stop_flock(:boids.space(flock)) == :ok
      refute Process.alive?(pid)
    end
  end

  describe "child_spec/1" do
    test "starts a flock below a supervisor of yours" do
      {:ok, sup} =
        Supervisor.start_link([{:boids, name: :boids_test_child, bounds: @box}], strategy: :one_for_one)

      assert %{bounds: @box} = :boids.space(:boids_test_child)
      {:ok, id} = :boids.add(:boids_test_child, still())
      assert :boids.count(:boids_test_child) == 1
      assert :boids.stop_flock(:boids_test_child) == {:error, :not_found}
      pid = :boids.whereis(:boids_test_child, id)
      Supervisor.stop(sup)
      refute Process.alive?(pid)
      assert Process.whereis(:boids_test_child) == nil
    end

    test "has the name of the flock in its id" do
      assert %{id: {:boids, :a}, start: {:boids_flock_sup, :start_link, [%{name: :a}]}, type: :supervisor} =
               :boids.child_spec(%{name: :a})

      assert %{id: {:boids, :undefined}} = :boids.child_spec([])
    end

    test "refuses a bad option" do
      assert catch_error(:boids.child_spec(%{cell_size: -1})) == {:bad_option, {:cell_size, -1}}
    end

    @tag :capture_log
    test "a flock that stops with an error starts again, with no boid" do
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
      flock = flock()
      {:ok, id} = :boids.add(flock, still(pos: {1, 2}, vel: {3, 4}, group: :birds, data: :blue))
      assert is_pid(id)
      assert :boids.whereis(flock, id) == id
      assert :boids.count(flock) == 1

      assert :boids.lookup(flock, id) ==
               {:ok, %{id: id, pos: {1, 2}, vel: {3, 4}, group: :birds, data: :blue, pid: id}}

      assert :boids.snapshot(flock) == [elem(:boids.lookup(flock, id), 1)]
      assert {:ok, %{id: ^id, pos: {1, 2}, max_speed: 10.0, rules: []}} = :boids.boid(flock, id)
    end

    test "accepts an id and a list of options" do
      flock = flock()
      assert :boids.add(flock, id: :a, pos: {1, 2}, tick: :manual) == {:ok, :a}
      pid = :boids.whereis(flock, :a)
      assert is_pid(pid)
      assert {:ok, %{id: :a, pid: ^pid}} = :boids.lookup(flock, :a)
    end

    test "refuses an id that is in the flock" do
      flock = flock()
      {:ok, :a} = :boids.add(flock, still(id: :a))
      assert :boids.add(flock, still(id: :a, pos: {5, 5})) == {:error, {:exists, :a}}
      assert :boids.count(flock) == 1
      assert pos(flock, :a) == {0, 0}
    end

    test "refuses a bad option" do
      flock = flock()
      assert :boids.add(flock, %{}) == {:error, {:bad_option, {:pos, :undefined}}}
      assert :boids.add(flock, still(max_speed: -1)) == {:error, {:bad_option, {:max_speed, -1}}}
      assert :boids.add(flock, still(tick: 0)) == {:error, {:bad_option, {:tick, 0}}}
      assert :boids.add(flock, still(tick: 1.5)) == {:error, {:bad_option, {:tick, 1.5}}}
      assert :boids.add(flock, still(max_dt: 0)) == {:error, {:bad_option, {:max_dt, 0}}}
      assert :boids.add(flock, still(seed: :random)) == {:error, {:bad_option, {:seed, :random}}}
      assert :boids.add(flock, still(priority: :high)) == {:error, {:bad_option, {:priority, :high}}}
      assert :boids.add(flock, still(hibernate: :yes)) == {:error, {:bad_option, {:hibernate, :yes}}}
      assert :boids.add(flock, still(wings: 2)) == {:error, {:bad_option, {:wings, 2}}}
      assert :boids.add(flock, :bird) == {:error, {:bad_option, :bird}}
      assert :boids.add(flock, [:bird]) == {:error, {:bad_option, [:bird]}}
      assert :boids.count(flock) == 0
    end

    test "uses the defaults of the flock" do
      flock = flock(defaults: %{max_speed: 3, group: :fish, tick: :manual, rules: []})
      {:ok, a} = :boids.add(flock, pos: {0, 0})
      {:ok, b} = :boids.add(flock, pos: {0, 0}, max_speed: 4)
      assert {:ok, %{max_speed: 3, group: :fish, rules: []}} = :boids.boid(flock, a)
      assert {:ok, %{max_speed: 4, group: :fish}} = :boids.boid(flock, b)
    end

    test "refuses a position that does not have the size of the flock" do
      flock = flock()
      {:ok, a} = :boids.add(flock, still())
      assert :boids.add(flock, still(pos: {0, 0, 0})) == {:error, {:bad_option, {:pos, {0, 0, 0}}}}
      assert :boids.join(flock, pos: {0, 0, 0}) == {:error, {:bad_option, {:pos, {0, 0, 0}}}}
      assert :boids.populate(flock, 2, area: {{0, 0, 0}, {1, 1, 1}}, tick: :manual) |> elem(0) == :error

      assert :boids.update(flock, a, %{pos: {0, 0, 0}, vel: {0, 0, 0}}) ==
               {:error, {:bad_option, {:pos, {0, 0, 0}}}}

      assert_raise ArgumentError, fn -> :boids.set_obstacle(flock, :rock, {0, 0, 0}, 1) end
      assert :boids.count(flock) == 1
      # An empty flock with no box accepts each size.
      :ok = :boids.remove(flock, a)
      assert {:ok, _} = :boids.add(flock, still(pos: {0, 0, 0}))
      # A flock with a box has the size of its box.
      box = flock(bounds: {{0, 0, 0}, {9, 9, 9}})
      assert :boids.add(box, still()) == {:error, {:bad_option, {:pos, {0, 0}}}}
      assert_raise ArgumentError, fn -> :boids.set_obstacle(box, :rock, {0, 0}, 1) end
      assert :boids.set_obstacle(box, :rock, {0, 0, 0}, 1) == :ok
    end

    test "functions for a boid that is not in the flock" do
      flock = flock()
      assert :boids.lookup(flock, :nobody) == :error
      assert :boids.whereis(flock, :nobody) == :undefined
      assert :boids.boid(flock, :nobody) == {:error, :not_found}
      assert :boids.update(flock, :nobody, %{max_speed: 1}) == {:error, :not_found}
      assert :boids.remove(flock, :nobody) == {:error, :not_found}
    end
  end

  describe "remove/2" do
    test "stops the process of a boid, and removes its row" do
      flock = flock()
      {:ok, id} = :boids.add(flock, still())
      {:ok, other} = :boids.add(flock, still())
      assert :boids.remove(flock, id) == :ok
      refute Process.alive?(id)
      assert :boids.lookup(flock, id) == :error
      assert :boids.count(flock) == 1
      assert :boids.remove(flock, id) == {:error, :not_found}
      assert Process.alive?(other)
    end

    test "a late leave for a process that stopped does not take the row of a new process" do
      flock = flock()
      {:ok, :a} = :boids.add(flock, still(id: :a))
      first = :boids.whereis(flock, :a)
      :ok = :boids.remove(flock, :a)
      {:ok, :a} = :boids.add(flock, still(id: :a))
      second = :boids.whereis(flock, :a)
      # The message of remove/2 for the first process, after the start of the second.
      assert :boids_flock.leave(:boids.space(flock), :a, first) == :ok
      assert :boids.whereis(flock, :a) == second
      assert :boids.remove(flock, :a) == :ok
      assert :boids.count(flock) == 0
    end

    test "only the process of a boid of join/2 removes it with leave/2" do
      flock = flock()
      {:ok, space, boid} = :boids.join(flock, id: :me, pos: {1, 2})
      assert Task.await(Task.async(fn -> :boids.leave(space, boid) end)) == :ok
      assert :boids.whereis(flock, :me) == self()
      assert :boids.leave(space, boid) == :ok
      assert :boids.count(flock) == 0
    end

    test "the id is free again" do
      flock = flock()
      {:ok, :a} = :boids.add(flock, still(id: :a))
      :ok = :boids.remove(flock, :a)
      assert :boids.add(flock, still(id: :a, pos: {5, 5})) == {:ok, :a}
      assert pos(flock, :a) == {5, 5}
    end
  end

  describe "update/3" do
    test "changes options of a boid, and its row" do
      flock = flock()
      {:ok, id} = :boids.add(flock, still())
      assert :boids.update(flock, id, %{pos: {50, 60}, vel: {1, 0}, group: :b, data: 1, max_speed: 2}) == :ok
      assert {:ok, %{pos: {50, 60}, vel: {1, 0}, group: :b, data: 1}} = :boids.lookup(flock, id)
      assert {:ok, %{max_speed: 2, pos: {50, 60}}} = :boids.boid(flock, id)
      assert [%{id: ^id}] = :boids.near(flock, {50, 60}, 1)
      assert :boids.update(flock, id, rules: [wander: 1]) == :ok
      assert {:ok, %{rules: [{:wander, 1, %{}}]}} = :boids.boid(flock, id)
    end

    test "refuses a bad option, and changes nothing" do
      flock = flock()
      {:ok, id} = :boids.add(flock, still())

      assert :boids.update(flock, id, %{pos: {1, 1}, max_speed: -1}) ==
               {:error, {:bad_option, {:max_speed, -1}}}

      assert :boids.update(flock, id, %{id: :other}) == {:error, {:bad_option, {:id, :other}}}
      assert :boids.update(flock, id, %{tick: 5}) == {:error, {:bad_option, {:tick, 5}}}
      assert pos(flock, id) == {0, 0}
    end
  end

  describe "the process of a boid" do
    @tag :capture_log
    test "a boid that stops with an error starts again, with its id" do
      flock = flock()
      {:ok, :a} = :boids.add(flock, still(id: :a, pos: {1, 1}))
      :ok = :boids.update(flock, :a, %{pos: {9, 9}})
      first = :boids.whereis(flock, :a)
      Process.exit(first, :kill)
      assert eventually(fn -> :boids.whereis(flock, :a) not in [:undefined, first] end)
      assert Process.alive?(:boids.whereis(flock, :a))
      assert pos(flock, :a) == {1, 1}
      assert :boids.count(flock) == 1
    end

    test "a boid that starts again when another process has its id stops, and its supervisor continues" do
      flock = flock()
      {:ok, :a} = :boids.add(flock, still(id: :a))
      {:ok, other} = :boids.add(flock, still())
      sup = :boids_flock.boid_sup(:boids.space(flock))
      # The supervisor starts the boid again only after the join of this process.
      :sys.suspend(sup)
      Process.exit(:boids.whereis(flock, :a), :kill)
      assert eventually(fn -> :boids.whereis(flock, :a) == :undefined end)
      {:ok, _, _} = :boids.join(flock, id: :a, pos: {1, 1})
      :sys.resume(sup)
      assert eventually(fn -> Supervisor.count_children(sup).active == 1 end)
      assert Process.alive?(sup)
      assert Process.alive?(other)
      assert :boids.whereis(flock, :a) == self()
    end

    test "a boid whose process stopped is not found" do
      flock = flock()
      {:ok, id} = :boids.add(flock, still())
      space = :boids.space(flock)
      # The flock does not see the end of the process before the call.
      :sys.suspend(flock)
      ref = Process.monitor(id)
      :ok = GenServer.stop(id)
      assert_receive {:DOWN, ^ref, _, _, _}
      assert :boids.boid(space, id) == {:error, :not_found}
      assert :boids.update(space, id, %{max_speed: 1}) == {:error, :not_found}
      :sys.resume(flock)
      assert eventually(fn -> :boids.count(flock) == 0 end)
    end

    test "the flock removes a boid whose process stops" do
      flock = flock()
      {:ok, id} = :boids.add(flock, still())
      :ok = GenServer.stop(id)
      assert eventually(fn -> :boids.count(flock) == 0 end)
      assert :boids.lookup(flock, id) == :error
      assert :boids.near(flock, {0, 0}, 5) == []
    end

    test "other messages change nothing" do
      flock = flock()
      {:ok, id} = :boids.add(flock, still())
      send(id, :hello)
      GenServer.cast(id, :hello)
      send(flock, :hello)
      send(flock, {:DOWN, make_ref(), :process, self(), :normal})
      GenServer.cast(flock, :hello)
      assert {:ok, %{pos: {0, 0}}} = :boids.boid(flock, id)
      assert :boids.count(flock) == 1
    end
  end

  describe "the clock of a boid" do
    test "a boid moves in real time" do
      flock = flock()
      {:ok, id} = :boids.add(flock, pos: {0, 0}, vel: {10, 0}, rules: [], tick: 5)
      Process.sleep(200)
      {x, y} = pos(flock, id)
      # 2 units in 200 ms. The limits accept a slow computer.
      assert x > 1.0 and x < 10.0
      assert y == 0.0
      later = eventually(fn -> elem(pos(flock, id), 0) > x end)
      assert later
    end

    test "with a manual tick, a boid moves only with step/2" do
      flock = flock()
      {:ok, id} = :boids.add(flock, still(vel: {10, 0}))
      Process.sleep(50)
      assert pos(flock, id) == {0, 0}
    end

    test "the scale of the time makes the boids slow, fast or stopped" do
      flock = flock()
      assert :boids.set_time_scale(flock, 0) == :ok
      {:ok, id} = :boids.add(flock, pos: {0, 0}, vel: {1, 0}, rules: [], tick: 5)
      Process.sleep(50)
      assert pos(flock, id) == {0, 0}
      assert :boids.set_time_scale(flock, 100) == :ok
      # 100 units for each second of the clock.
      assert eventually(fn -> elem(pos(flock, id), 0) > 5.0 end)
    end

    test "a step has the maximum time at most" do
      flock = flock()
      {:ok, id} = :boids.add(flock, pos: {0, 0}, vel: {10, 0}, rules: [], tick: 20, max_dt: 0.001)
      Process.sleep(200)
      {x, _} = pos(flock, id)
      # 10 ticks of 0.01 unit at most, and not 2 units.
      assert x > 0.0 and x < 0.5
    end

    test "a boid hibernates between two steps" do
      flock = flock()

      sleeps? = &hibernates?/1

      {:ok, timed} = :boids.add(flock, pos: {0, 0}, vel: {1, 0}, rules: [], tick: 20)
      assert eventually(fn -> sleeps?.(timed) end)
      before = pos(flock, timed)
      assert eventually(fn -> pos(flock, timed) != before end)
      {:ok, manual} = :boids.add(flock, still())
      refute sleeps?.(manual)
      :boids.step(flock, 0.1)
      assert eventually(fn -> sleeps?.(manual) end)
      # A boid that hibernates answers.
      assert {:ok, %{id: ^manual}} = :boids.boid(flock, manual)
    end

    test "without hibernate, a boid keeps its heap" do
      flock = flock()

      sleeps? = &hibernates?/1

      {:ok, timed} = :boids.add(flock, pos: {0, 0}, vel: {1, 0}, rules: [], tick: 5, hibernate: false)
      {:ok, manual} = :boids.add(flock, still(hibernate: false))
      assert eventually(fn -> pos(flock, timed) != {0, 0} end)
      :boids.step(flock, 0.1)
      refute sleeps?.(timed)
      refute sleeps?.(manual)
    end

    test "a boid whose tick comes late waits longer before its next tick" do
      flock = flock()
      {:ok, id} = :boids.add(flock, pos: {0, 0}, vel: {10, 0}, rules: [], tick: 10)
      # The tick comes 100 ms late, as with processors that have too much work.
      :erlang.suspend_process(id)
      Process.sleep(110)
      late = pos(flock, id)
      :erlang.resume_process(id)
      assert eventually(fn -> pos(flock, id) != late end)
      # The boid waits 8 times the delay more: about 0.7 second.
      moved = pos(flock, id)
      Process.sleep(300)
      assert pos(flock, id) == moved
      assert eventually(fn -> pos(flock, id) != moved end)
      # Then the ticks come at the usual time again.
      again = pos(flock, id)
      Process.sleep(200)
      assert elem(pos(flock, id), 0) - elem(again, 0) > 0.5
    end

    test "a seed gives the same random numbers" do
      flock = flock()
      rules = [wander: 1]
      {:ok, a} = :boids.add(flock, still(seed: 42, rules: rules, id: :a))
      {:ok, b} = :boids.add(flock, still(seed: 42, rules: rules, id: :b, pos: {50, 50}))
      {:ok, c} = :boids.add(flock, still(seed: 43, rules: rules, id: :c, pos: {90, 90}))
      for _ <- 1..10, do: :boids.step(flock, 0.1)
      assert_vec(:boids_vec.sub(pos(flock, b), {50, 50}), pos(flock, a))
      refute :boids_vec.sub(pos(flock, c), {90, 90}) == pos(flock, a)
    end
  end

  describe "step/2" do
    test "moves each boid for the time of the step" do
      flock = flock()
      {:ok, a} = :boids.add(flock, still(vel: {1, 0}))
      {:ok, b} = :boids.add(flock, still(pos: {5, 5}, vel: {0, -2}))
      assert :boids.step(flock, 0.5) == :ok
      assert pos(flock, a) == {0.5, 0.0}
      assert pos(flock, b) == {5.0, 4.0}
      assert {:ok, %{pos: {0.5, +0.0}}} = :boids.boid(flock, a)
      assert :boids.step(flock, 0) == :ok
      assert pos(flock, a) == {0.5, 0.0}
    end

    test "each boid calculates its step before a boid moves" do
      flock = flock()
      me = self()

      rule = fn boid, neighbors, _env ->
        send(me, {boid.id, Enum.map(neighbors, & &1.pos)})
        {0, 0}
      end

      for {id, x} <- [a: 0, b: 1, c: 2],
          do: {:ok, _} = :boids.add(flock, still(id: id, pos: {x, 0}, vel: {1, 0}, rules: [{rule, 1}]))

      :boids.step(flock, 1)
      assert_received {:a, [{1, 0}, {2, 0}]}
      assert_received {:b, [{0, 0}, {2, 0}]}
      assert_received {:c, [{1, 0}, {0, 0}]}
      assert pos(flock, :a) == {1.0, 0.0}
      :boids.step(flock, 1)
      assert_received {:c, [{2.0, +0.0}, {1.0, +0.0}]}
    end

    test "uses the scale of the time" do
      flock = flock()
      {:ok, a} = :boids.add(flock, still(vel: {1, 0}))
      :boids.set_time_scale(flock, 10)
      :boids.step(flock, 0.5)
      assert pos(flock, a) == {5.0, 0.0}
      :boids.set_time_scale(flock, 0)
      :boids.step(flock, 0.5)
      assert pos(flock, a) == {5.0, 0.0}
    end

    test "a commit with no plan changes nothing" do
      flock = flock()
      {:ok, id} = :boids.add(flock, still(vel: {1, 0}))
      assert GenServer.call(id, :commit) == :ok
      assert pos(flock, id) == {0, 0}
      # An update removes the plan.
      assert GenServer.call(id, {:plan, 1}) == :ok
      :ok = :boids.update(flock, id, %{pos: {7, 7}})
      assert GenServer.call(id, :commit) == :ok
      assert pos(flock, id) == {7, 7}
    end

    test "refuses a bad time" do
      flock = flock()
      assert_raise FunctionClauseError, fn -> :boids.step(flock, -1) end
      assert_raise FunctionClauseError, fn -> :boids.step(flock, :long) end
    end

    test "with a seed for each boid, two runs give the same result" do
      run = fn ->
        {:ok, flock} = :boids.start_flock(bounds: {{0, 0}, {60, 60}}, wrap: true)
        rules = [separation: 1.5, alignment: 1.0, cohesion: 1.0, wander: 0.5]

        for n <- 1..40 do
          pos = {rem(n * 17, 60), rem(n * 29, 60)}
          vel = {rem(n, 7) - 3, rem(n, 5) - 2}
          {:ok, ^n} = :boids.add(flock, id: n, pos: pos, vel: vel, rules: rules, tick: :manual, seed: n)
        end

        for _ <- 1..60, do: :boids.step(flock, 0.05)
        rows = Enum.sort_by(:boids.snapshot(flock), & &1.id)
        :ok = :boids.stop_flock(flock)
        Enum.map(rows, &Map.take(&1, [:id, :pos, :vel]))
      end

      first = run.()
      assert first == run.()
      assert length(first) == 40
    end
  end

  describe "populate/3" do
    test "adds boids at random positions of the box of the flock" do
      flock = flock(bounds: {{10, 20}, {30, 50}})
      {:ok, ids} = :boids.populate(flock, 30, %{tick: :manual, min_speed: 2, max_speed: 5})
      assert length(Enum.uniq(ids)) == 30
      assert :boids.count(flock) == 30

      for %{pos: {x, y}, vel: vel} <- :boids.snapshot(flock) do
        assert x >= 10 and x <= 30 and y >= 20 and y <= 50
        speed = :boids_vec.norm(vel)
        assert speed >= 2 - 1.0e-9 and speed <= 5 + 1.0e-9
      end

      positions = Enum.uniq(Enum.map(:boids.snapshot(flock), & &1.pos))
      assert length(positions) == 30
    end

    test "uses an area, in two or three dimensions" do
      flock = flock()
      {:ok, _} = :boids.populate(flock, 10, tick: :manual, area: {{0, 0, 0}, {1, 2, 3}}, vel: {0, 0, 1})

      for %{pos: {x, y, z}, vel: vel} <- :boids.snapshot(flock) do
        assert x >= 0 and x <= 1 and y >= 0 and y <= 2 and z >= 0 and z <= 3
        assert vel == {0, 0, 1}
      end
    end

    test "the area comes before the box of the flock" do
      flock = flock(bounds: @box)
      {:ok, [id]} = :boids.populate(flock, 1, tick: :manual, area: {{200, 200}, {201, 201}})
      {x, y} = pos(flock, id)
      assert x >= 200 and y >= 200
    end

    test "no boid" do
      flock = flock(bounds: @box)
      assert :boids.populate(flock, 0, %{}) == {:ok, []}
    end

    test "gives new ids, and a seed to each boid" do
      flock = flock(bounds: @box)
      {:ok, [a, b]} = :boids.populate(flock, 2, id: :same, tick: :manual, seed: 5, rules: [wander: 1])
      assert a != b
      :boids.step(flock, 0.1)
      {:ok, %{memory: %{wander: first}}} = :boids.boid(flock, a)
      {:ok, %{memory: %{wander: second}}} = :boids.boid(flock, b)
      assert first != second
    end

    test "refuses a bad option" do
      flock = flock()
      assert :boids.populate(flock, 3, %{}) == {:error, {:bad_option, {:area, :undefined}}}

      assert :boids.populate(flock, 3, area: {{0, 0}, {1, 1, 1}}) ==
               {:error, {:bad_option, {:area, {{0, 0}, {1, 1, 1}}}}}

      assert :boids.populate(flock, 3, area: {{0}, {1}}) == {:error, {:bad_option, {:area, {{0}, {1}}}}}
      assert :boids.populate(flock, 3, area: @box, mass: 0) == {:error, {:bad_option, {:mass, 0}}}
      assert :boids.populate(flock, 3, area: @box, tick: -1) == {:error, {:bad_option, {:tick, -1}}}
      assert :boids.populate(flock, 3, :many) == {:error, {:bad_option, :many}}
      assert :boids.count(flock) == 0
      assert_raise FunctionClauseError, fn -> :boids.populate(flock, -1, area: @box) end
    end
  end

  describe "the obstacles" do
    test "set_obstacle/4, obstacles/1 and remove_obstacle/2" do
      flock = flock()
      assert :boids.obstacles(flock) == []
      assert :boids.set_obstacle(flock, :rock, {5, 5}, 2) == :ok
      assert :boids.obstacles(flock) == [%{id: :rock, pos: {5, 5}, radius: 2}]
      assert :boids.set_obstacle(:boids.space(flock), :rock, {6, 5}, 2) == :ok
      assert :boids.obstacles(flock) == [%{id: :rock, pos: {6, 5}, radius: 2}]
      assert :boids.remove_obstacle(flock, :rock) == :ok
      assert :boids.obstacles(flock) == []
    end

    test "a boid with the rule avoid moves around an obstacle" do
      flock = flock()
      :boids.set_obstacle(flock, :rock, {30, 0}, 5)
      rules = [{:avoid, 3, lookahead: 2}, {:seek, 1, target: {60, 0.5}}]
      {:ok, id} = :boids.add(flock, still(pos: {0, 0.5}, vel: {10, 0}, rules: rules, combine: :priority))

      nearest =
        Enum.reduce(1..200, 1.0e9, fn _, nearest ->
          :boids.step(flock, 0.05)
          min(nearest, :boids_vec.dist(pos(flock, id), {30, 0}))
        end)

      assert nearest > 5.0
      assert :boids_vec.dist(pos(flock, id), {60, 0.5}) < 10
    end

    test "a boid without the rule goes through the obstacle" do
      flock = flock()
      :boids.set_obstacle(flock, :rock, {30, 0}, 5)

      {:ok, id} =
        :boids.add(flock, still(pos: {0, 0.5}, vel: {10, 0}, rules: [{:seek, 1, target: {60, 0.5}}]))

      nearest =
        Enum.reduce(1..200, 1.0e9, fn _, nearest ->
          :boids.step(flock, 0.05)
          min(nearest, :boids_vec.dist(pos(flock, id), {30, 0}))
        end)

      assert nearest < 1.0
    end
  end

  describe "a flock" do
    # Boids at fixed positions, so that each run is the same.
    defp scatter(flock, count, size, opts) do
      for n <- 1..count do
        pos = {rem(n * 37, size) + rem(n, 3) / 4, rem(n * 61, size) + rem(n, 5) / 6}
        angle = n * 2.399963
        vel = {4 * :math.cos(angle), 4 * :math.sin(angle)}

        {:ok, ^n} =
          :boids.add(flock, Map.merge(%{id: n, pos: pos, vel: vel, tick: :manual, seed: n}, Map.new(opts)))
      end
    end

    test "with alignment, the boids move in one direction" do
      flock = flock(bounds: {{0, 0}, {50, 50}}, wrap: true)
      scatter(flock, 50, 50, min_speed: 3)
      assert order(:boids.snapshot(flock)) < 0.3
      for _ <- 1..400, do: :boids.step(flock, 0.05)
      assert order(:boids.snapshot(flock)) > 0.9
    end

    test "without alignment, the boids do not move in one direction" do
      flock = flock(bounds: {{0, 0}, {50, 50}}, wrap: true)
      scatter(flock, 50, 50, min_speed: 3, rules: [separation: 1.5, wander: 1.0])
      for _ <- 1..400, do: :boids.step(flock, 0.05)
      assert order(:boids.snapshot(flock)) < 0.5
    end

    test "with separation, the boids keep a distance" do
      flock = flock()
      scatter(flock, 30, 6, rules: [separation: 1.0], vel: {0, 0})

      nearest = fn ->
        Enum.min(for a <- :boids.snapshot(flock), [_, b | _] = :boids.near(flock, a.pos, 100), do: b.dist)
      end

      assert nearest.() < 0.5
      for _ <- 1..200, do: :boids.step(flock, 0.05)
      assert nearest.() > 2.0
    end

    test "with cohesion, the boids come together" do
      flock = flock()
      scatter(flock, 30, 40, rules: [cohesion: 1.0], perception: 100, vel: {0, 0})

      spread = fn ->
        rows = :boids.snapshot(flock)
        center = :boids_vec.scale(Enum.reduce(rows, {0, 0}, &:boids_vec.add(&1.pos, &2)), 1 / length(rows))
        Enum.sum(for row <- rows, do: :boids_vec.dist(row.pos, center)) / length(rows)
      end

      before = spread.()
      for _ <- 1..100, do: :boids.step(flock, 0.05)
      assert spread.() < before / 3
    end

    test "with contain, the boids stay in the box" do
      # The boids start 5 units or more from the sides.
      flock = flock(bounds: {{-5, -5}, {45, 45}})
      scatter(flock, 30, 40, rules: [contain: 3.0, wander: 1.0], min_speed: 5, max_force: 40)

      for _ <- 1..400 do
        :boids.step(flock, 0.05)
        for %{pos: {x, y}} <- :boids.snapshot(flock), do: assert(x > -5 and x < 45 and y > -5 and y < 45)
      end
    end

    test "without contain, the boids go out of the box" do
      flock = flock(bounds: {{-5, -5}, {45, 45}})
      scatter(flock, 30, 40, rules: [wander: 1.0], min_speed: 5, max_force: 40)
      for _ <- 1..400, do: :boids.step(flock, 0.05)
      assert Enum.any?(:boids.snapshot(flock), fn %{pos: {x, y}} -> x < -5 or x > 45 or y < -5 or y > 45 end)
    end

    test "with wrap, the boids stay in the box" do
      flock = flock(bounds: {{0, 0}, {40, 40}}, wrap: true)
      scatter(flock, 30, 40, min_speed: 5)

      for _ <- 1..200 do
        :boids.step(flock, 0.05)
        for %{pos: {x, y}} <- :boids.snapshot(flock), do: assert(x >= 0 and x < 40 and y >= 0 and y < 40)
      end
    end

    test "a boid pursues a boid of another group, which flees" do
      flock = flock()

      {:ok, :cat} =
        :boids.add(
          flock,
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
          flock,
          still(id: :mouse, group: :mice, pos: {20, 0}, max_speed: 4, perception: 50, rules: mouse)
        )

      :boids.step(flock, 0.05)
      # The cat is too far: the mouse does not move.
      assert pos(flock, :mouse) == {20, 0}
      for _ <- 1..40, do: :boids.step(flock, 0.05)
      {x, _} = pos(flock, :mouse)
      assert x > 20
      for _ <- 1..100, do: :boids.step(flock, 0.05)
      assert :boids_vec.dist(pos(flock, :cat), pos(flock, :mouse)) < 1.0
    end

    test "boids in three dimensions" do
      flock = flock(bounds: {{0, 0, 0}, {30, 30, 30}}, wrap: true)
      {:ok, ids} = :boids.populate(flock, 40, tick: :manual, seed: 1, min_speed: 3)
      for _ <- 1..100, do: :boids.step(flock, 0.05)

      for %{pos: {x, y, z}, vel: vel} <- :boids.snapshot(flock) do
        assert x >= 0 and x < 30 and y >= 0 and y < 30 and z >= 0 and z < 30
        assert :boids_vec.norm(vel) <= 10.0 + 1.0e-9
      end

      assert length(ids) == 40
    end
  end

  describe "a process of yours as a boid" do
    test "join/2 adds the process to the flock" do
      flock = flock(defaults: %{max_speed: 3, tick: :manual, seed: 1})
      assert {:ok, space, boid} = :boids.join(flock, pos: {1, 2}, vel: {1, 0}, rules: [])
      assert space == :boids.space(flock)
      assert %{id: id, pos: {1, 2}, max_speed: 3} = boid
      assert id == self()

      assert :boids.lookup(flock, self()) ==
               {:ok, %{id: self(), pos: {1, 2}, vel: {1, 0}, group: :default, data: :undefined, pid: self()}}

      assert :boids.whereis(flock, self()) == self()
    end

    test "plan/3 calculates a step, and commit/2 writes it" do
      flock = flock()
      {:ok, space, boid} = :boids.join(flock, id: :me, pos: {1, 2}, vel: {2, 0}, rules: [])
      planned = :boids.plan(space, boid, 0.5)
      assert planned.pos == {2.0, 2.0}
      assert pos(flock, :me) == {1, 2}
      assert :boids.commit(space, planned) == :ok
      assert pos(flock, :me) == {2.0, 2.0}
    end

    test "advance/3 makes a step, with the scale of the time" do
      flock = flock()
      {:ok, space, boid} = :boids.join(flock, id: :me, pos: {1, 2}, vel: {2, 0}, rules: [])
      boid = :boids.advance(space, boid, 0.5)
      assert boid.pos == {2.0, 2.0}
      assert pos(flock, :me) == {2.0, 2.0}
      :boids.set_time_scale(flock, 2)
      assert :boids.advance(space, boid, 0.5).pos == {4.0, 2.0}
    end

    test "a change of the boid goes to the flock with commit/2" do
      flock = flock()
      {:ok, space, boid} = :boids.join(flock, id: :me, pos: {1, 2})
      changed = :boids_boid.update(boid, %{group: :leaders, data: :gold, pos: {40, 40}})
      :ok = :boids.commit(space, changed)
      assert {:ok, %{group: :leaders, data: :gold, pos: {40, 40}}} = :boids.lookup(flock, :me)
    end

    test "leave/2 removes the boid" do
      flock = flock()
      {:ok, space, boid} = :boids.join(flock, pos: {1, 2})
      assert :boids.leave(space, boid) == :ok
      assert :boids.count(flock) == 0
      assert :boids.leave(space, boid) == :ok
      # After leave/2, a commit adds no row.
      assert :boids.commit(space, boid) == :ok
      assert :boids.count(flock) == 0
      assert {:ok, _, _} = :boids.join(flock, pos: {1, 2})
    end

    test "refuses an id that is in the flock, and a bad option" do
      flock = flock()
      {:ok, _, _} = :boids.join(flock, id: :me, pos: {1, 2})
      assert :boids.join(flock, id: :me, pos: {3, 4}) == {:error, {:exists, :me}}
      assert :boids.join(flock, id: :other) == {:error, {:bad_option, {:pos, :undefined}}}
      assert :boids.join(flock, id: :other, pos: {0, 0}, tick: 0) == {:error, {:bad_option, {:tick, 0}}}
      # The options of the process of add/2 are permitted, and not used.
      assert {:ok, _, _} =
               :boids.join(flock, id: :other, pos: {0, 0}, tick: 5, priority: :normal, hibernate: false)

      :ok = :boids_flock.leave(:boids.space(flock), :other, self())
      assert :boids.join(flock, :me) == {:error, {:bad_option, :me}}
      assert :boids.count(flock) == 1
    end

    test "one process can have many boids" do
      flock = flock()
      {:ok, _, _} = :boids.join(flock, id: :a, pos: {1, 2})
      {:ok, _, _} = :boids.join(flock, id: :b, pos: {1, 2})
      assert :boids.count(flock) == 2
    end

    test "the flock removes the boid when the process stops" do
      flock = flock()
      me = self()

      pid =
        spawn(fn ->
          {:ok, _, _} = :boids.join(flock, id: :a, pos: {1, 2})
          {:ok, _, _} = :boids.join(flock, id: :b, pos: {1, 2})
          send(me, :joined)
          Process.sleep(:infinity)
        end)

      assert_receive :joined
      assert :boids.count(flock) == 2
      assert :boids.whereis(flock, :a) == pid
      Process.exit(pid, :kill)
      assert eventually(fn -> :boids.count(flock) == 0 end)
    end

    test "the functions for a boid of add/2 do not find it" do
      flock = flock()
      {:ok, _, _} = :boids.join(flock, id: :me, pos: {1, 2})
      assert :boids.boid(flock, :me) == {:error, :not_found}
      assert :boids.update(flock, :me, %{max_speed: 1}) == {:error, :not_found}
      assert :boids.remove(flock, :me) == {:error, :not_found}
      assert :boids.step(flock, 1) == :ok
      assert pos(flock, :me) == {1, 2}
    end

    test "the boids of add/2 see it" do
      flock = flock()
      {:ok, space, me} = :boids.join(flock, id: :leader, pos: {10, 0}, vel: {0, 1}, rules: [])

      {:ok, id} =
        :boids.add(flock, still(perception: 5, rules: [{:pursue, 1, target: {:boid, :leader}, max_time: 0}]))

      :boids.step(flock, 0.1)
      {x, y} = pos(flock, id)
      assert x > 0 and y == 0
      # It also sees the boids of add/2.
      assert [%{id: ^id}] = :boids_boid.perceive(me, :boids.near(space, me.pos, 100))
    end

    test "a new process can use the id of a process that stopped" do
      flock = flock()
      space = :boids.space(flock)
      {pid, ref} = spawn_monitor(fn -> :ok end)
      assert_receive {:DOWN, ^ref, _, _, _}
      # The row of a process that stopped, before the flock sees its end.
      true = :boids_space.insert_new(space, %{id: :a, pos: {9, 9}, vel: {0, 0}, pid: pid})
      assert {:ok, _, _} = :boids.join(flock, id: :a, pos: {1, 2})
      assert {:ok, %{pos: {1, 2}, pid: owner}} = :boids.lookup(flock, :a)
      assert owner == self()
      assert :boids.count(flock) == 1
    end

    test "a row with no process keeps its id" do
      flock = flock()
      true = :boids_space.insert_new(:boids.space(flock), %{id: :a, pos: {9, 9}, vel: {0, 0}})
      assert :boids.join(flock, id: :a, pos: {1, 2}) == {:error, {:exists, :a}}
    end
  end
end
