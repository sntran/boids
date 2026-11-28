defmodule BoidsFactsTest do
  # The facts of a world (the obstacles and the scale of the time) with
  # their versions, on one node: the node takes the last change, keeps a
  # mark for a fact that was removed, and drops the mark after some time.
  # The messages of another node come from the test.
  use ExUnit.Case, async: false
  import Boids.Helpers
  import ExUnit.CaptureLog

  @moduletag :capture_log

  setup do
    name = :"world#{System.unique_integer([:positive])}"
    {:ok, world} = :boids.start_world(name: name)
    on_exit(fn -> :boids.stop_world(world) end)
    %{world: world}
  end

  defp facts(world), do: :boids_world.facts(world)

  # The world gets facts of another node. The answer of facts/1 comes
  # after the world took them.
  defp learn(world, facts) do
    send(world, {:facts, facts})
    facts(world)
  end

  # The fact of the obstacle rock, with a version.
  defp rock(pos, version), do: {{:obstacle, :rock}, {pos, 1}, version}
  defp rocks(world), do: for(%{id: :rock, pos: pos} <- :boids.obstacles(world), do: pos)
  defp now, do: System.system_time(:microsecond)

  test "each change of a fact has a version: a counter and the node", %{world: world} do
    start = now()
    assert facts(world) == []
    assert :boids.set_time_scale(world, 2) == :ok
    assert :boids.set_obstacle(world, :rock, {5, 5}, 1) == :ok
    assert :boids.set_obstacle(world, :rock, {6, 5}, 1) == :ok
    me = node()

    assert [scale = {:time_scale, 2, {first, ^me}}, {{:obstacle, :rock}, {{6, 5}, 1}, {third, ^me}}] =
             facts(world)

    # The counter is the time of the system in microseconds, or more:
    # each change of a node has a larger counter than its last change.
    assert start <= first and first + 2 <= third and third <= now() + 2
    assert facts(:boids.space(world)) == facts(world)
    # A fact that is removed stays as a mark, with its version.
    assert :boids.remove_obstacle(world, :rock) == :ok
    assert [^scale, {{:obstacle, :rock}, :none, {fourth, ^me}}] = facts(world)
    assert fourth > third
    assert :boids.obstacles(world) == []
    # A bad value is no change, and it has no version.
    assert_raise ArgumentError, fn -> :boids.set_time_scale(world, -1) end
    assert [^scale, _mark] = facts(world)
    assert :boids.set_time_scale(world, 3) == :ok
    assert [{:time_scale, 3, {fifth, ^me}}, _mark] = facts(world)
    assert fifth > fourth
  end

  test "a world with no name is on one node only, and keeps no mark" do
    {:ok, alone} = :boids.start_world()
    on_exit(fn -> :boids.stop_world(alone) end)
    :ok = :boids.set_obstacle(alone, :rock, {5, 5}, 1)
    [{_, _, {first, _}}] = facts(alone)
    :ok = :boids.remove_obstacle(alone, :rock)
    assert facts(alone) == []
    # The counter continues after the removal.
    :ok = :boids.set_obstacle(alone, :rock, {6, 5}, 1)
    assert [{{:obstacle, :rock}, {{6, 5}, 1}, {third, _}}] = facts(alone)
    assert third >= first + 2
  end

  test "a node takes a fact of another node only when its version is larger", %{world: world} do
    :ok = :boids.set_obstacle(world, :rock, {5, 5}, 1)
    assert [{_, _, {c, me}}] = facts(world)
    # The same counter: the node with the larger name wins.
    assert :a@host < me and me < :z@host
    assert learn(world, [rock({1, 1}, {c, :a@host})]) == [rock({5, 5}, {c, me})]
    assert learn(world, [rock({2, 2}, {c, :z@host})]) == [rock({2, 2}, {c, :z@host})]
    assert rocks(world) == [{2, 2}]
    # A smaller counter loses, and a larger counter wins, from each node.
    assert learn(world, [rock({3, 3}, {c - 1, :z@host})]) == [rock({2, 2}, {c, :z@host})]
    assert learn(world, [rock({4, 4}, {c + 7, :a@host})]) == [rock({4, 4}, {c + 7, :a@host})]
    # The same fact again changes nothing.
    assert learn(world, [rock({4, 4}, {c + 7, :a@host})]) == [rock({4, 4}, {c + 7, :a@host})]
    assert rocks(world) == [{4, 4}]
    # The next change of this node is after each change that it knows,
    # also when the counter of that change is after the time of the
    # system: the clock of another computer is ahead.
    far = now() + 1_000_000_000
    assert {:time_scale, 2, {far, :a@host}} in learn(world, [{:time_scale, 2, {far, :a@host}}])
    :ok = :boids.set_obstacle(world, :rock, {6, 6}, 1)
    assert rock({6, 6}, {far + 1, me}) in facts(world)
    :ok = :boids.set_time_scale(world, 3)
    assert {:time_scale, 3, {far + 2, me}} in facts(world)
  end

  test "merge/2 gives facts with their versions to a world, as the facts of another node", %{world: world} do
    :ok = :boids.set_obstacle(world, :rock, {5, 5}, 1)
    :ok = :boids.set_obstacle(world, :tree, {7, 7}, 1)
    :ok = :boids.remove_obstacle(world, :tree)
    assert [mine = {_, _, {c, me}}, mark = {_, :none, {t, me}}] = facts(world)
    # The facts of a save: an older rock, an older tree, a pole, and a scale of the time.
    tree = {{:obstacle, :tree}, {{2, 2}, 1}, {t - 1, :z@host}}
    pole = {{:obstacle, :pole}, {{1, 1}, 1}, {c - 9, :a@host}}
    scale = {:time_scale, 0.5, {c - 8, :a@host}}
    assert :boids_world.merge(world, [rock({1, 1}, {c - 5, :z@host}), tree, pole, scale]) == :ok
    # The world keeps its rock and the removal of its tree, and it takes the other facts.
    assert facts(world) == [scale, pole, mine, mark]
    assert rocks(world) == [{5, 5}]
    assert [%{id: :pole}, %{id: :rock}] = :boids.obstacles(world)
    assert %{time_scale: 0.5} = :boids_space.env(:boids.space(world))
    # A newer fact wins. The space of the world is the world too.
    far = now() + 1_000_000_000
    assert :boids_world.merge(:boids.space(world), [rock({3, 3}, {far, :a@host})]) == :ok
    assert rocks(world) == [{3, 3}]
    # The next change of the world is after the facts that it got.
    :ok = :boids.set_obstacle(world, :rock, {6, 6}, 1)
    assert rock({6, 6}, {far + 1, me}) in facts(world)
  end

  test "merge/2 of a term that is not a list of facts gives badarg, and the world continues", %{world: world} do
    for bad <- [
          :facts,
          [:fact],
          [{:time_scale, 1.0, 5}],
          [{:time_scale, 1.0, {0, node()}}],
          [{:a, 1, {1, "n"}}]
        ] do
      assert :boids_world.merge(world, bad) == {:error, :badarg}

      assert :boids_world.merge(:boids.space(world), [rock({1, 1}, {5, node()}) | List.wrap(bad)]) ==
               {:error, :badarg}
    end

    assert facts(world) == []
    assert Process.alive?(world)
    # A fact with a value that this world cannot write: the world keeps
    # it for the other nodes, with an error in its log.
    log = capture_log(fn -> assert :boids_world.merge(world, [{:time_scale, :fast, {5, node()}}]) == :ok end)
    assert log =~ "cannot write the fact"
    assert facts(world) == [{:time_scale, :fast, {5, node()}}]
    assert %{time_scale: 1.0} = :boids_space.env(:boids.space(world))
  end

  test "an older change does not bring back a fact that was removed", %{world: world} do
    :ok = :boids.set_obstacle(world, :rock, {5, 5}, 1)
    :ok = :boids.remove_obstacle(world, :rock)
    assert [mark = {{:obstacle, :rock}, :none, {c, _}}] = facts(world)
    assert learn(world, [rock({1, 1}, {c - 1, :z@host})]) == [mark]
    assert rocks(world) == []
    # A removal of another node is a mark too, also for a key that this node did not have.
    gone = {{:obstacle, :pole}, :none, {c + 5, :z@host}}
    assert learn(world, [gone]) == [gone, mark]
    assert learn(world, [{{:obstacle, :pole}, {{1, 1}, 1}, {c + 4, :z@host}}]) == [gone, mark]
    assert :boids.obstacles(world) == []
    # A newer change makes the fact again.
    assert rock({3, 3}, {c + 1, :a@host}) in learn(world, [rock({3, 3}, {c + 1, :a@host})])
    assert rocks(world) == [{3, 3}]
  end

  test "a node drops a mark after the time of a mark, and then an older change brings the fact back", %{
    world: world
  } do
    assert :boids.mark_time() == 600_000
    # With the time infinity, a node never drops a mark.
    Application.put_env(:boids, :mark_time, :infinity)
    on_exit(fn -> Application.delete_env(:boids, :mark_time) end)
    :ok = :boids.set_obstacle(world, :rock, {5, 5}, 1)
    :ok = :boids.remove_obstacle(world, :rock)
    # A key that has a fact again keeps that fact when its old mark goes.
    :ok = :boids.set_obstacle(world, :pole, {5, 5}, 1)
    :ok = :boids.remove_obstacle(world, :pole)
    :ok = :boids.set_obstacle(world, :pole, {6, 6}, 1)

    assert [pole = {{:obstacle, :pole}, {{6, 6}, 1}, _}, mark = {{:obstacle, :rock}, :none, {c, _}}] =
             facts(world)

    # The world looks for old marks four times in a second.
    Process.sleep(600)
    assert facts(world) == [pole, mark]

    Application.put_env(:boids, :mark_time, 100)
    assert eventually(fn -> facts(world) == [pole] end)
    # The limit: this node does not know now that the rock was removed.
    assert learn(world, [rock({1, 1}, {c - 1, :z@host})]) == [pole, rock({1, 1}, {c - 1, :z@host})]
    assert rocks(world) == [{1, 1}]
  end

  test "a fact that this node cannot write stays for the other nodes, with an error in the log", %{
    world: world
  } do
    # A kind of fact that this version of the library does not know.
    far = now() + 1_000_000_000
    grid = {{:grid, :walls}, <<1, 2, 3>>, {far, :z@host}}

    log =
      capture_log(fn ->
        assert learn(world, [grid]) == [grid]
      end)

    assert log =~ "cannot write the fact" and log =~ "grid" and log =~ "z@host"
    # The world continues, and its next change is after that fact.
    :ok = :boids.set_time_scale(world, 2)
    assert facts(world) == [{:time_scale, 2, {far + 1, node()}}, grid]
    assert :boids_world.set(world, {:grid, :walls}, <<1>>) == {:error, :badarg}
  end

  test "a world answers a change of another node to the process that asked for the change", %{world: world} do
    # The alias of the process that waits in boids_world:set/3.
    ack = :erlang.alias()
    pid = world
    send(world, {:fact, rock({5, 5}, {1, :z@host}), ack})
    assert_receive {^ack, ^pid}
    assert rocks(world) == [{5, 5}]
    # An older change gets an answer too: the node has a newer fact.
    send(world, {:fact, rock({1, 1}, {1, :a@host}), ack})
    assert_receive {^ack, ^pid}
    assert rocks(world) == [{5, 5}]
  end
end
