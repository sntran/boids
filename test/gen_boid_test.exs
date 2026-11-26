defmodule GenBoidTest do
  use ExUnit.Case, async: true
  import Boids.Helpers

  alias Boids.TestBoids.{Hawk, Mouse}

  @moduletag :capture_log

  setup do
    {:ok, flock} = :boids.start_flock(tick: :manual)
    on_exit(fn -> :boids.stop_flock(flock) end)
    %{flock: flock}
  end

  # A flock with a clock: its boids move in real time.
  defp timed do
    {:ok, flock} = :boids.start_flock(tick: 5)
    on_exit(fn -> :boids.stop_flock(flock) end)
    flock
  end

  # Only a process that hibernates has a heap smaller than the minimum
  # heap of a new process.
  defp hibernates?(pid) do
    {:total_heap_size, words} = Process.info(pid, :total_heap_size)
    words < 233
  end

  defp hawk(flock, args \\ %{}) do
    {:ok, pid} = :gen_boid.start(Hawk, Map.new(args), flock: flock)
    pid
  end

  defp row(flock, id) do
    {:ok, row} = :boids.lookup(flock, id)
    row
  end

  describe "start/3" do
    test "starts a boid below the supervisor of its flock, with the options of init/1", %{flock: flock} do
      pid = hawk(flock, boid: %{id: :hawk, pos: {1, 2}, max_speed: 3})
      assert :boids.whereis(flock, :hawk) == pid
      assert {:ok, %{id: :hawk, pos: {1, 2}, group: :hawks, max_speed: 3}} = :boids.boid(flock, :hawk)
      space = :boids.space(flock)
      assert :boids_space.owner(space, :hawk) == {:server, pid}
      assert {:ok, %{id: :hawk, pid: ^pid}} = :boids.lookup(flock, :hawk)
      # The clock of the flock moves it.
      assert Map.keys(:sys.get_state(space.clock).servers) == [pid]
      assert :proc_lib.get_label(pid) == {:boids, :boid, :hawk}
      # The supervisor of the flock stops it with the flock.
      assert :boids.stop_flock(flock) == :ok
      refute Process.alive?(pid)
    end

    test "accepts the space of the flock, a map of options, and a name", %{flock: flock} do
      assert {:ok, pid} =
               :gen_boid.start(Mouse, %{pos: {0, 0}}, %{flock: :boids.space(flock), name: :boids_test_mouse})

      assert Process.whereis(:boids_test_mouse) == pid

      assert {:ok, other} =
               :gen_boid.start(Mouse, %{pos: {0, 0}}, flock: flock, name: {:global, :boids_test_mouse})

      assert :global.whereis_name(:boids_test_mouse) == other
      assert :gen_boid.stop({:global, :boids_test_mouse}) == :ok
      assert :gen_boid.stop(:boids_test_mouse) == :ok
      assert eventually(fn -> :boids.count(flock) == 0 end)
    end

    test "gives what init/1 gives when the boid does not start", %{flock: flock} do
      assert :gen_boid.start(Hawk, :ignore, flock: flock) == :ignore
      assert :gen_boid.start(Hawk, {:stop, :no_sky}, flock: flock) == {:error, :no_sky}
      assert :gen_boid.start(Mouse, %{}, flock: flock) == {:error, {:bad_option, {:pos, :undefined}}}

      # The tick is an option of the flock, and not of a boid.
      assert :gen_boid.start(Mouse, %{pos: {0, 0}, tick: 5}, flock: flock) ==
               {:error, {:bad_option, {:tick, 5}}}

      assert :gen_boid.start(Mouse, %{pos: {0, 0}, priority: :low}, flock: flock) ==
               {:error, {:bad_option, {:priority, :low}}}

      assert :gen_boid.start(Mouse, %{pos: {0, 0}, seed: :random}, flock: flock) ==
               {:error, {:bad_option, {:seed, :random}}}

      assert :gen_boid.start(Mouse, :cheese, flock: flock) == {:error, {:bad_option, :cheese}}
      {:ok, _} = :gen_boid.start(Mouse, %{id: :a, pos: {0, 0}}, flock: flock)
      assert :gen_boid.start(Mouse, %{id: :a, pos: {0, 0}}, flock: flock) == {:error, {:exists, :a}}
      assert :boids.count(flock) == 1
    end

    test "refuses bad options of the start", %{flock: flock} do
      assert catch_error(:gen_boid.start(Mouse, %{pos: {0, 0}}, [])) == {:bad_option, {:flock, :undefined}}
      assert catch_error(:gen_boid.start(Mouse, %{}, flock: flock, speed: 1)) == {:bad_option, {:speed, 1}}
      assert catch_error(:gen_boid.start_link(Mouse, %{}, :here)) == {:bad_option, :here}

      assert catch_error(:gen_boid.start(Mouse, %{pos: {0, 0}}, flock: flock, hibernate: :yes)) ==
               {:bad_option, {:hibernate, :yes}}

      assert :boids.count(flock) == 0
    end

    test "the process hibernates after each step", %{flock: flock} do
      {:ok, pid} = :gen_boid.start(Mouse, %{id: :mouse, pos: {0, 0}, vel: {1, 0}}, flock: flock)
      refute hibernates?(pid)
      :boids.step(flock, 0.1)
      assert eventually(fn -> hibernates?(pid) end)
      # A boid that hibernates answers, and moves.
      assert {:ok, %{id: :mouse}} = :boids.boid(flock, :mouse)
      :boids.step(flock, 0.1)
      assert_vec(row(flock, :mouse).pos, {0.2, 0.0})
      late = timed()
      {:ok, pid} = :gen_boid.start(Mouse, %{id: :mouse, pos: {0, 0}, vel: {1, 0}}, flock: late)
      assert eventually(fn -> hibernates?(pid) and row(late, :mouse).pos != {0, 0} end)
    end

    test "without hibernate, the process keeps its heap", %{flock: flock} do
      options = %{id: :mouse, pos: {0, 0}, vel: {1, 0}, rules: []}
      {:ok, pid} = :gen_boid.start(Mouse, options, flock: flock, hibernate: false)
      {:ok, other} = :gen_boid.start(Mouse, %{options | id: :other}, %{flock: flock, hibernate: true})
      for _ <- 1..3, do: :boids.step(flock, 0.1)
      assert eventually(fn -> hibernates?(other) end)
      refute hibernates?(pid)
      assert_vec(row(flock, :mouse).pos, {0.3, 0.0})
    end

    test "a seed in the options of init/1 gives the random numbers of the process", %{flock: flock} do
      start = fn id, pos, seed ->
        {:ok, _} = :gen_boid.start(Mouse, %{id: id, pos: pos, seed: seed, rules: [wander: 1]}, flock: flock)
      end

      start.(:a, {0, 0}, 42)
      start.(:b, {50, 50}, 42)
      start.(:c, {90, 90}, 43)
      for _ <- 1..10, do: :boids.step(flock, 0.1)
      assert_vec(:boids_vec.sub(row(flock, :b).pos, {50, 50}), row(flock, :a).pos)
      refute :boids_vec.sub(row(flock, :c).pos, {90, 90}) == row(flock, :a).pos
      # The boid has no random numbers of its own.
      assert {:ok, %{rand: :undefined}} = :boids.boid(flock, :a)
    end
  end

  describe "start_link/3" do
    test "starts a boid with a link to the caller", %{flock: flock} do
      assert {:ok, pid} = :gen_boid.start_link(Mouse, %{pos: {0, 0}}, flock: flock)
      assert {:links, links} = Process.info(self(), :links)
      assert pid in links
      assert {:ok, named} = :gen_boid.start_link(Mouse, %{pos: {0, 0}}, flock: flock, name: :boids_test_link)
      assert Process.whereis(:boids_test_link) == named

      assert {:ok, via} =
               :gen_boid.start_link(Mouse, %{pos: {0, 0}},
                 flock: flock,
                 name: {:via, :global, :boids_test_link}
               )

      assert :global.whereis_name(:boids_test_link) == via
      assert :gen_boid.start_link(Hawk, :ignore, flock: flock) == :ignore
      for boid <- [pid, named, via], do: :gen_boid.stop(boid)
    end
  end

  describe "handle_step/3" do
    test "runs at each step, with the boid and the neighbors that it sees", %{flock: flock} do
      pid = hawk(flock, boid: %{id: :hawk, max_speed: 2})
      :boids.step(flock, 1)
      :boids.step(flock, 1)
      assert :gen_boid.call(pid, :steps) == 2
      # With no mouse, the hawk does not move.
      assert row(flock, :hawk).pos == {0.0, 0.0}
    end

    test "its changes are for this step and the next steps", %{flock: flock} do
      pid = hawk(flock, boid: %{id: :hawk, max_speed: 2, max_force: 100})
      {:ok, _} = :gen_boid.start(Mouse, %{id: :mouse, pos: {5, 0}, group: :mice, rules: []}, flock: flock)
      :boids.step(flock, 1)
      assert %{pos: {2.0, +0.0}, data: {:hunts, :mouse}} = row(flock, :hawk)
      assert {:ok, %{rules: [{:seek, 1, %{target: {5, 0}}}]}} = :boids.boid(flock, :hawk)
      :boids.step(flock, 1)
      assert row(flock, :hawk).pos == {4.0, 0.0}
      assert :gen_boid.call(pid, :steps) == 2
    end

    test "runs at each tick of the clock of the flock" do
      pid = hawk(timed())
      assert eventually(fn -> :gen_boid.call(pid, :steps) > 3 end)
    end

    test "can stop the boid, at a step of boids:step/2 and at a tick", %{flock: flock} do
      manual = hawk(flock, owner: self(), stop_at: 1, boid: %{id: :manual})
      {:ok, id} = :boids.add(flock, pos: {5, 5}, vel: {1, 0}, rules: [])
      :boids.step(flock, 1)
      assert Process.alive?(manual)
      # The step continues for the other boids.
      assert :boids.step(flock, 1) == :ok
      assert_receive {:terminated, :normal, :manual, 1}
      assert row(flock, id).pos == {7.0, 5.0}
      assert eventually(fn -> not Process.alive?(manual) and :boids.count(flock) == 1 end)
      assert :boids.step(flock, 1) == :ok
      late = timed()
      timed = hawk(late, owner: self(), stop_at: 2, boid: %{id: :timed})
      assert_receive {:terminated, :normal, :timed, 2}
      assert eventually(fn -> not Process.alive?(timed) and :boids.count(late) == 0 end)
    end

    test "a module without it has the rules of its options only", %{flock: flock} do
      {:ok, _} = :gen_boid.start(Mouse, %{id: :mouse, pos: {0, 0}, vel: {1, 0}, rules: []}, flock: flock)
      :boids.step(flock, 1)
      assert row(flock, :mouse).pos == {1.0, 0.0}
    end
  end

  describe "call/2, call/3 and handle_call/4" do
    test "gives the answer of the module, which sees the boid", %{flock: flock} do
      pid = hawk(flock, boid: %{pos: {3, 4}})
      assert :gen_boid.call(pid, :where) == {3, 4}
      assert :gen_boid.call(pid, :steps, 1000) == 0
    end

    test "an answer can change the boid", %{flock: flock} do
      pid = hawk(flock, boid: %{id: :hawk})
      assert :gen_boid.call(pid, {:go, {7, 7}}) == :ok
      assert row(flock, :hawk).pos == {7, 7}
      assert :gen_boid.call(pid, :where) == {7, 7}
    end

    test "the module can answer later, with reply/2", %{flock: flock} do
      pid = hawk(flock, boid: %{id: :hawk})
      assert :gen_boid.call(pid, :later) == {:later, :hawks}
      assert :gen_boid.call(pid, {:later, :eagles}) == {:later, :eagles}
      assert row(flock, :hawk).group == :eagles
    end

    test "the module can stop the boid, with or without an answer", %{flock: flock} do
      first = hawk(flock, owner: self(), boid: %{id: :first})
      assert :gen_boid.call(first, :stop) == :bye
      assert_receive {:terminated, :normal, :first, 0}
      second = hawk(flock, owner: self(), boid: %{id: :second})

      assert catch_exit(:gen_boid.call(second, :fail)) ==
               {:normal, {:gen_server, :call, [second, {:"$gen_boid", :fail}]}}

      assert_receive {:terminated, :normal, :second, 0}
      assert eventually(fn -> :boids.count(flock) == 0 end)
    end

    test "a module without it stops the boid at a call", %{flock: flock} do
      {:ok, pid} = :gen_boid.start(Mouse, %{pos: {0, 0}}, flock: flock)
      assert {{:bad_call, :hello}, _} = catch_exit(:gen_boid.call(pid, :hello))
      assert eventually(fn -> :boids.count(flock) == 0 end)
    end

    test "the functions of boids for a boid do not go to the module", %{flock: flock} do
      {:ok, pid} = :gen_boid.start(Mouse, %{id: :mouse, pos: {0, 0}}, flock: flock)
      assert {:ok, %{id: :mouse}} = :boids.boid(flock, :mouse)
      assert :boids.update(flock, :mouse, %{max_speed: 2}) == :ok
      assert :boids.update(flock, :mouse, %{max_speed: -2}) == {:error, {:bad_option, {:max_speed, -2}}}
      assert {:ok, %{max_speed: 2}} = :boids.boid(flock, :mouse)
      assert :boids.remove(flock, :mouse) == :ok
      refute Process.alive?(pid)
    end
  end

  describe "add_rule/2, delete_rule/2 and which_rules/1" do
    test "change the rules of a boid, from its next step", %{flock: flock} do
      {:ok, pid} = :gen_boid.start(Mouse, %{id: :mouse, pos: {0, 0}, max_force: 100, rules: []}, flock: flock)
      assert :gen_boid.which_rules(pid) == []
      assert :gen_boid.add_rule(pid, {{:seek, :home}, 1, target: {10, 0}}) == :ok
      assert :gen_boid.add_rule(pid, {:wander, 0}) == :ok
      assert :gen_boid.which_rules(pid) == [{:seek, :home}, :wander]
      :boids.step(flock, 0.1)
      {x, y} = row(flock, :mouse).pos
      assert x > 0 and y == 0
      assert :gen_boid.delete_rule(pid, {:seek, :home}) == :ok
      assert :gen_boid.delete_rule(pid, :cruise) == :ok
      assert :gen_boid.which_rules(pid) == [:wander]
      assert :gen_boid.add_rule(pid, {:seek, 1}) == {:error, {:bad_option, {:rules, {:seek, 1, %{}}}}}
      assert :gen_boid.which_rules(pid) == [:wander]
    end

    test "the functions of boids with the id of the boid do the same", %{flock: flock} do
      {:ok, pid} = :gen_boid.start(Mouse, %{id: :mouse, pos: {0, 0}, rules: [avoid: 1]}, flock: flock)
      assert :boids.add_rule(flock, :mouse, {{:seek, :home}, 1, target: {10, 0}}) == :ok
      assert :boids.which_rules(flock, :mouse) == {:ok, [:avoid, {:seek, :home}]}
      assert :boids.delete_rule(flock, :mouse, :avoid) == :ok
      assert :gen_boid.which_rules(pid) == [{:seek, :home}]
      assert :boids.add_rule(flock, :mouse, :seek) == {:error, {:bad_option, {:rules, :seek}}}
    end

    test "a change after the first part of a step removes the step", %{flock: flock} do
      {:ok, pid} = :gen_boid.start(Mouse, %{id: :mouse, pos: {0, 0}, vel: {1, 0}, rules: []}, flock: flock)
      # The messages of the clock of the flock, and the answers of the boid.
      part = fn request ->
        ref = make_ref()
        send(pid, {:"$boids_clock", self(), ref, request})
        assert_receive {^ref, ^pid}
      end

      part.(:commit)
      assert row(flock, :mouse).pos == {0, 0}
      part.({:plan, 1})
      assert row(flock, :mouse).pos == {0, 0}
      :ok = :boids.update(flock, :mouse, %{pos: {7, 7}})
      part.(:commit)
      assert row(flock, :mouse).pos == {7, 7}
    end
  end

  describe "cast/2 and handle_cast/3" do
    test "the module gets the request, and can change the boid or its state", %{flock: flock} do
      pid = hawk(flock, boid: %{id: :hawk})
      assert :gen_boid.cast(pid, {:data, :blue}) == :ok
      assert :gen_boid.cast(pid, :count) == :ok
      assert :gen_boid.call(pid, :steps) == 100
      assert row(flock, :hawk).data == :blue
    end

    test "the module can stop the boid", %{flock: flock} do
      pid = hawk(flock, owner: self(), boid: %{id: :hawk})
      :gen_boid.cast(pid, :stop)
      assert_receive {:terminated, :normal, :hawk, 0}
    end

    test "a module without it stops the boid at a cast, and other casts change nothing", %{flock: flock} do
      {:ok, pid} = :gen_boid.start(Mouse, %{pos: {0, 0}}, flock: flock)
      GenServer.cast(pid, :hello)
      assert {:ok, _} = :boids.boid(flock, pid)
      ref = Process.monitor(pid)
      :gen_boid.cast(pid, :hello)
      assert_receive {:DOWN, ^ref, _, _, {:bad_cast, :hello}}
    end
  end

  describe "handle_info/3" do
    test "the module gets each other message, and can change the boid", %{flock: flock} do
      pid = hawk(flock, boid: %{id: :hawk})
      send(pid, {:speed, 4})
      send(pid, :hello)
      assert {:ok, %{max_speed: 4}} = :boids.boid(flock, :hawk)
    end

    test "the module can stop the boid", %{flock: flock} do
      pid = hawk(flock, owner: self(), boid: %{id: :hawk})
      send(pid, :stop)
      assert_receive {:terminated, :normal, :hawk, 0}
    end

    test "a module without it does not see the messages", %{flock: flock} do
      {:ok, pid} = :gen_boid.start(Mouse, %{pos: {0, 0}}, flock: flock)
      send(pid, :hello)
      assert {:ok, _} = :boids.boid(flock, pid)
    end
  end

  describe "terminate/3" do
    test "runs at stop/1, with the reason, the boid and the state", %{flock: flock} do
      pid = hawk(flock, owner: self(), boid: %{id: :hawk})
      assert :gen_boid.stop(pid) == :ok
      assert_receive {:terminated, :normal, :hawk, 0}
    end

    test "runs when the flock stops, for a module that traps exits", %{flock: flock} do
      hawk(flock, owner: self(), trap: true, boid: %{id: :hawk})
      :boids.stop_flock(flock)
      assert_receive {:terminated, :shutdown, :hawk, 0}
    end

    test "a module without it stops with no call", %{flock: flock} do
      {:ok, pid} = :gen_boid.start(Mouse, %{pos: {0, 0}}, flock: flock)
      assert :gen_boid.stop(pid) == :ok
      refute Process.alive?(pid)
    end
  end

  test "the example of the documentation: a hawk that hunts the birds that it sees", %{flock: flock} do
    defmodule HawkOfTheDocs do
      @behaviour :gen_boid
      def init(pos) do
        {:ok, %{pos: pos, group: :hawks, perception: 25, max_force: 100, rules: [{:wander, 1.0}]},
         %{meals: 0}}
      end

      def handle_step(_boid, neighbors, %{meals: meals} = state) do
        case Enum.filter(neighbors, &(&1.group == :birds)) do
          [] -> {:ok, %{rules: [{:wander, 1.0}]}, state}
          [%{dist: dist} | _] when dist < 1 -> {:ok, %{state | meals: meals + 1}}
          [_ | _] -> {:ok, %{rules: [{:pursue, 1.0, %{target: {:group, :birds}}}]}, state}
        end
      end

      def handle_call(:meals, _from, _boid, %{meals: meals} = state), do: {:reply, meals, state}
    end

    {:ok, hawk} = :gen_boid.start_link(HawkOfTheDocs, {50, 50}, flock: flock)
    assert :gen_boid.call(hawk, :meals) == 0
    {:ok, _} = :boids.add(flock, id: :bird, pos: {60, 50}, group: :birds, rules: [])
    for _ <- 1..60, do: :boids.step(flock, 0.05)
    assert :gen_boid.call(hawk, :meals) > 0
    :gen_boid.stop(hawk)
  end
end
