defmodule GenBoidTest do
  use ExUnit.Case, async: true
  import Boids.Helpers

  alias Boids.TestRules.{Mind, Push, Turn}

  @moduletag :capture_log

  setup do
    {:ok, flock} = :boids.start_flock(defaults: %{tick: :manual, rules: []})
    on_exit(fn -> :boids.stop_flock(flock) end)
    %{flock: flock}
  end

  defp start(flock, options \\ []) do
    {:ok, pid} = :gen_boid.start(flock, Keyword.merge([pos: {0, 0}], options))
    pid
  end

  defp row(flock, id) do
    {:ok, row} = :boids.lookup(flock, id)
    row
  end

  describe "start/2" do
    test "starts a boid below the supervisor of its flock", %{flock: flock} do
      pid = start(flock, id: :hawk, pos: {1, 2}, max_speed: 3, rules: [{:wander, 1}, {Push, 1}])
      assert :boids.whereis(flock, :hawk) == pid
      assert {:ok, %{id: :hawk, pos: {1, 2}, max_speed: 3}} = :boids.boid(flock, :hawk)
      assert :gen_boid.which_rules(pid) == [:wander, Push]
      assert :proc_lib.get_label(pid) == {:boids, :boid, :hawk}
      # The supervisor of the flock stops it with the flock.
      assert :boids.stop_flock(flock) == :ok
      refute Process.alive?(pid)
    end

    test "accepts the space of the flock, a map of options, and a name", %{flock: flock} do
      assert {:ok, pid} = :gen_boid.start(:boids.space(flock), %{pos: {0, 0}, name: :boids_test_mouse})
      assert Process.whereis(:boids_test_mouse) == pid
      assert {:ok, other} = :gen_boid.start(flock, pos: {0, 0}, name: {:global, :boids_test_mouse})
      assert :global.whereis_name(:boids_test_mouse) == other
      assert :gen_boid.which_rules(:boids_test_mouse) == []
      assert :gen_boid.stop({:global, :boids_test_mouse}) == :ok
      assert :gen_boid.stop(:boids_test_mouse) == :ok
      assert eventually(fn -> :boids.count(flock) == 0 end)
    end

    test "the rules that are modules start in the process of the boid", %{flock: flock} do
      pid = start(flock, rules: [{Mind, 1, %{owner: self()}}])
      :boids.step(flock, 1)
      assert_receive {:step, 1, _, _, _}
      # The end of the process stops the rule.
      :gen_boid.stop(pid)
      assert_receive {:terminated, {:stop, :normal}, 1}
    end

    test "refuses a bad option, a rule that does not start, and an id of the flock", %{flock: flock} do
      assert :gen_boid.start(flock, %{}) == {:error, {:bad_option, {:pos, :undefined}}}
      assert :gen_boid.start(flock, pos: {0, 0}, tick: 0) == {:error, {:bad_option, {:tick, 0}}}
      assert :gen_boid.start(flock, :cheese) == {:error, {:bad_option, :cheese}}

      assert :gen_boid.start(flock, pos: {0, 0}, rules: [{Mind, 1, :refuse}]) ==
               {:error, {:bad_option, {:rules, {Mind, 1, :refuse}}}}

      # A rule that exits at its start stops the process of the boid.
      assert :gen_boid.start(flock, pos: {0, 0}, rules: [{Mind, 1, :exit}]) == {:error, :no_start}
      start(flock, id: :a)
      # The rules of a boid that the flock refuses stop.
      assert :gen_boid.start(flock, id: :a, pos: {0, 0}, rules: [{Mind, 1, %{owner: self()}}]) ==
               {:error, {:exists, :a}}

      assert_receive {:terminated, {:stop, {:exists, :a}}, 0}
      assert :boids.count(flock) == 1
    end
  end

  describe "start_link/2 and child_spec/1" do
    test "starts a boid with a link to the caller", %{flock: flock} do
      assert {:ok, pid} = :gen_boid.start_link(flock, pos: {0, 0})
      assert {:links, links} = Process.info(self(), :links)
      assert pid in links
      assert {:ok, named} = :gen_boid.start_link(flock, pos: {0, 0}, name: :boids_test_link)
      assert Process.whereis(:boids_test_link) == named
      assert {:ok, via} = :gen_boid.start_link(flock, %{pos: {0, 0}, name: {:via, :global, :boids_test_link}})
      assert :global.whereis_name(:boids_test_link) == via
      for boid <- [pid, named, via], do: :gen_boid.stop(boid)
    end

    test "refuses a bad option and an id of the flock", %{flock: flock} do
      Process.flag(:trap_exit, true)

      assert :gen_boid.start_link(flock, pos: {0, 0}, mass: 0) ==
               {:error, {:shutdown, {:bad_option, {:mass, 0}}}}

      assert :gen_boid.start_link(flock, :bird) == {:error, {:shutdown, {:bad_option, :bird}}}
      start(flock, id: :hawk)
      assert :gen_boid.start_link(flock, id: :hawk, pos: {0, 0}) == {:error, {:shutdown, {:exists, :hawk}}}
    end

    test "the specification of the child has the id of the boid" do
      assert :gen_boid.child_spec({:f, %{id: :hawk}}) ==
               %{id: {:gen_boid, :hawk}, start: {:gen_boid, :start_link, [:f, %{id: :hawk}]}}

      assert %{id: {:gen_boid, ref}} = :gen_boid.child_spec({:f, pos: {0, 0}})
      assert is_reference(ref)
    end
  end

  describe "add_rule/2, delete_rule/3 and which_rules/1" do
    test "a boid gets rules and loses them while it runs", %{flock: flock} do
      pid = start(flock, id: :a, max_force: 100)
      :boids.step(flock, 1)
      assert row(flock, :a).pos == {0.0, 0.0}
      assert :gen_boid.add_rule(pid, {Push, 1, {2, 0}}) == :ok
      assert :gen_boid.add_rule(pid, {{:seek, :home}, 0, target: {9, 9}}) == :ok
      assert :gen_boid.which_rules(pid) == [Push, {:seek, :home}]
      :boids.step(flock, 1)
      assert row(flock, :a).pos == {2.0, 0.0}
      assert :gen_boid.delete_rule(pid, Push, []) == :ok
      assert :gen_boid.delete_rule(pid, {:seek, :home}, []) == :ok
      assert :gen_boid.which_rules(pid) == []
      assert :gen_boid.delete_rule(pid, Push, []) == {:error, :not_found}
    end

    test "a module starts and stops in the process of the boid", %{flock: flock} do
      pid = start(flock)
      assert :gen_boid.add_rule(pid, {Mind, 1, %{owner: self()}}) == :ok
      :boids.step(flock, 1)
      assert_receive {:step, 1, _, _, _}
      assert :gen_boid.delete_rule(pid, Mind, :done) == {:ended, 1}
      assert_receive {:terminated, :done, 1}
    end

    test "refuses a bad rule, and a module that does not start", %{flock: flock} do
      pid = start(flock)
      assert :gen_boid.add_rule(pid, {:fly, 1}) == {:error, {:bad_option, {:rules, {:fly, 1, %{}}}}}
      assert :gen_boid.add_rule(pid, {Mind, 1, :refuse}) == {:error, :refused}
      assert :gen_boid.which_rules(pid) == []
    end

    test "a change of the rules removes a plan of boids:step/2", %{flock: flock} do
      pid = start(flock, id: :a, vel: {1, 0})
      assert GenServer.call(pid, {:plan, 1}) == :ok
      assert :gen_boid.add_rule(pid, {Turn, 1}) == :ok
      assert GenServer.call(pid, :commit) == :ok
      assert row(flock, :a).pos == {0, 0}
    end
  end

  describe "call/3 and call/4" do
    test "gives the answer of a rule, which sees the boid", %{flock: flock} do
      pid = start(flock, pos: {3, 4}, rules: [{Mind, 1}, {{Mind, 2}, 1, %{steps: 7}}])
      assert :gen_boid.call(pid, Mind, :where) == {3, 4}
      assert :gen_boid.call(pid, {Mind, 2}, :steps, 1000) == 7
      :boids.step(flock, 1)
      assert :gen_boid.call(pid, Mind, :steps) == 1
    end

    test "an answer can change the boid, and can stop it", %{flock: flock} do
      pid = start(flock, id: :a, rules: [{Mind, 1, %{owner: self()}}])
      assert :gen_boid.call(pid, Mind, {:actions, [{:set, %{pos: {7, 7}, data: :here}}]}) == :done
      assert %{pos: {7, 7}, data: :here} = row(flock, :a)
      assert :gen_boid.call(pid, Mind, {:actions, [{:stop, :asked}]}) == :done
      assert_receive {:terminated, {:stop, :asked}, 0}
      assert eventually(fn -> :boids.count(flock) == 0 end)
    end

    test "a boid with no such rule, and a rule that fails", %{flock: flock} do
      pid = start(flock, rules: [{Mind, 1}, {Push, 1}])
      assert :gen_boid.call(pid, Turn, :hello) == {:error, :bad_rule}
      assert :gen_boid.call(pid, Push, :hello) == {:error, :bad_rule}
      assert {:error, {:failed, %RuntimeError{}}} = :gen_boid.call(pid, Mind, :crash)
      # The boid continues with its other rules.
      assert :gen_boid.which_rules(pid) == [Push]
      assert :gen_boid.call(pid, Mind, :steps) == {:error, :bad_rule}
    end
  end

  describe "the steps of a boid with rules that are modules" do
    test "a rule gives its force at each step of boids:step/2 and at each tick", %{flock: flock} do
      start(flock, id: :manual, rules: [{Push, 1, {1, 0}}], max_force: 100)
      :boids.step(flock, 1)
      assert row(flock, :manual).pos == {1.0, 0.0}
      start(flock, id: :timed, rules: [{Push, 1, {0, 1}}], tick: 5)
      assert eventually(fn -> elem(row(flock, :timed).pos, 1) > 0 end)
    end

    test "a rule that is the mind of a boid adds and removes rules for what the boid sees", %{flock: flock} do
      # At the step 2, the boid starts to go to a point.
      plan = %{2 => {:actions, [{:add_rule, {:seek, 1, %{target: {10, 0}}}}, {:set, %{data: :goes}}]}}
      pid = start(flock, id: :a, max_speed: 2, max_force: 100, rules: [{Mind, 1, %{plan: plan}}])
      :boids.step(flock, 1)
      :boids.step(flock, 1)
      assert row(flock, :a).pos == {0.0, 0.0}
      :boids.step(flock, 1)
      assert %{pos: {2.0, +0.0}, data: :goes} = row(flock, :a)
      assert :gen_boid.which_rules(pid) == [Mind, :seek]
    end

    test "a rule can stop the boid, at a step of boids:step/2 and at a tick", %{flock: flock} do
      plan = %{2 => {:actions, [{:stop, :eaten}]}}
      manual = start(flock, rules: [{Mind, 1, %{owner: self(), plan: plan}}])
      :boids.step(flock, 1)
      assert Process.alive?(manual)
      assert :boids.step(flock, 1) == :ok
      assert_receive {:terminated, {:stop, :eaten}, 2}
      timed = start(flock, tick: 5, rules: [{Mind, 1, %{owner: self(), plan: %{3 => {:actions, [:stop]}}}}])
      assert_receive {:terminated, {:stop, :normal}, 3}
      assert eventually(fn -> not Process.alive?(timed) and :boids.count(flock) == 0 end)
    end

    test "a rule that fails does not stop the boid", %{flock: flock} do
      pid =
        start(flock, id: :a, max_force: 100, rules: [{Mind, 1, %{plan: %{1 => :crash}}}, {Push, 1, {1, 0}}])

      :boids.step(flock, 1)
      :boids.step(flock, 1)
      assert Process.alive?(pid)
      assert :gen_boid.which_rules(pid) == [Push]
      # The force 1 for two steps of 1 second: the speeds 1 and 2.
      assert row(flock, :a).pos == {3.0, 0.0}
    end
  end

  describe "the other messages to a boid" do
    test "go to each rule with handle_info/3", %{flock: flock} do
      pid = start(flock, id: :a, rules: [{Mind, 1}, {Push, 1}])
      send(pid, {:count, 5})
      assert :gen_boid.call(pid, Mind, :steps) == 5
      send(pid, {:actions, [{:set, %{data: :told}}]})
      assert eventually(fn -> row(flock, :a).data == :told end)
      send(pid, :leave)
      assert eventually(fn -> :gen_boid.which_rules(pid) == [Push] end)
      GenServer.cast(pid, :hello)
      assert Process.alive?(pid)
    end

    test "a rule can stop the boid", %{flock: flock} do
      pid = start(flock, rules: [{Mind, 1, %{owner: self()}}])
      send(pid, {:actions, [:stop]})
      assert_receive {:terminated, {:stop, :normal}, 0}
      assert eventually(fn -> not Process.alive?(pid) end)
    end
  end

  test "the example of the documentation: a hawk with the rule hunger", %{flock: flock} do
    defmodule Hunger do
      @behaviour :gen_boid
      def init(%{prey: prey}), do: {:ok, %{prey: prey, meals: 0}}

      def handle_step(boid, neighbors, _env, %{prey: prey, meals: meals} = state) do
        case Enum.filter(neighbors, &(&1.group == prey)) do
          [] -> {:ok, state}
          [%{dist: dist} | _] when dist < 1 -> {:ok, %{state | meals: meals + 1}}
          [%{pos: pos} | _] -> {:force, :boids_steer.seek(boid, pos), state}
        end
      end

      def handle_call(:meals, _boid, %{meals: meals} = state), do: {:ok, meals, state}
    end

    {:ok, hawk} =
      :gen_boid.start(flock,
        pos: {50, 50},
        group: :hawks,
        perception: 25,
        max_force: 100,
        rules: [{:wander, 1.0}]
      )

    assert :gen_boid.add_rule(hawk, {Hunger, 1.0, %{prey: :birds}}) == :ok
    assert :gen_boid.which_rules(hawk) == [:wander, Hunger]
    assert :gen_boid.call(hawk, Hunger, :meals) == 0
    assert :gen_boid.delete_rule(hawk, :wander, []) == :ok
    {:ok, _} = :boids.add(flock, id: :bird, pos: {60, 50}, group: :birds)
    for _ <- 1..60, do: :boids.step(flock, 0.05)
    assert :gen_boid.call(hawk, Hunger, :meals) > 0
  end
end
