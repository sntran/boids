defmodule BoidsReadmeTest do
  # The examples of README.md.
  use ExUnit.Case, async: true
  import Boids.Helpers

  defmodule Hawk do
    @behaviour :gen_boid

    @impl true
    def init(pos) do
      {:ok,
       %{pos: pos, group: :hawks, perception: 25, rules: [wander: 1.0], state: %{energy: 10.0}, tick: :manual}}
    end

    @impl true
    def handle_sense(%{neighbors: neighbors} = seen, boid) do
      {:ok, Map.put(seen, :prey, Enum.filter(neighbors, &(&1.group == :birds))), boid}
    end

    @impl true
    def handle_decide(%{prey: [_ | _]}, %{state: %{energy: energy}} = boid) when energy > 2 do
      {:ok, :boids_boid.update(boid, %{rules: [{:pursue, 1.0, %{target: {:group, :birds}}}]})}
    end

    def handle_decide(_seen, boid), do: {:ok, :boids_boid.update(boid, %{rules: [wander: 1.0]})}

    @impl true
    def handle_act(%{vel: vel, state: %{energy: energy} = state} = boid) do
      {:ok, %{boid | state: %{state | energy: energy - 0.01 * :boids_vec.norm(vel)}}}
    end

    @impl true
    def handle_call(:energy, _from, %{state: %{energy: energy}} = boid), do: {:reply, energy, boid}
  end

  defmodule Person do
    use GenServer

    def init(flock) do
      {:ok, space, boid} = :boids.join(flock, pos: {0, 0}, vel: {1, 0})
      Process.send_after(self(), :tick, 5)
      {:ok, %{space: space, boid: boid}}
    end

    def handle_info(:tick, %{space: space, boid: boid} = state) do
      Process.send_after(self(), :tick, 5)
      {:noreply, %{state | boid: :boids.advance(space, boid, 0.05)}}
    end
  end

  setup do
    {:ok, flock} = :boids.start_flock(bounds: {{0, 0}, {100, 100}}, wrap: true)
    on_exit(fn -> :boids.stop_flock(flock) end)
    %{flock: flock}
  end

  test "a first flock", %{flock: flock} do
    {:ok, ids} = :boids.populate(flock, 200, max_speed: 12.0)
    assert length(ids) == 200

    assert [%{id: id, pos: {_, _}, vel: {_, _}, group: :default, data: :undefined, pid: id} | _] =
             :boids.snapshot(flock)

    assert is_pid(id)
    before = Map.new(:boids.snapshot(flock), &{&1.id, &1.pos})
    assert eventually(fn -> Enum.all?(:boids.snapshot(flock), &(&1.pos != before[&1.id])) end)
  end

  test "a boid with a behavior", %{flock: flock} do
    {:ok, hawk} = :gen_boid.start(Hawk, {50, 50}, flock: flock)
    assert :gen_boid.call(hawk, :energy) == 10.0
    assert :gen_boid.which_rules(hawk) == [:wander]

    # The hawk sees a bird: it pursues the bird, and it uses energy.
    {:ok, _bird} = :boids.add(flock, pos: {55, 50}, group: :birds, rules: [], tick: :manual)
    for _ <- 1..10, do: :boids.step(flock, 0.05)
    assert :gen_boid.which_rules(hawk) == [:pursue]
    assert :gen_boid.call(hawk, :energy) < 10.0
  end

  test "the rules of a boid", %{flock: flock} do
    birds = [
      {:avoid, 4.0},
      {:evade, 3.0, %{target: {:group, :hawks}, radius: 12}},
      {:separation, 1.5, %{radius: 3}},
      {:alignment, 1.0},
      {:cohesion, 1.0}
    ]

    assert {:ok, _} =
             :boids.populate(flock, 70, %{group: :birds, rules: birds, combine: :priority, tick: :manual})

    hawk = [{:avoid, 4.0}, {:pursue, 1.0, %{target: {:group, :birds}}}, {:wander, 0.5}]

    assert {:ok, id} =
             :boids.add(flock, %{pos: {50, 50}, group: :hawks, rules: hawk, perception: 25, tick: :manual})

    assert :boids.set_obstacle(flock, :rock, {30, 30}, 5) == :ok
    for _ <- 1..20, do: :boids.step(flock, 0.05)
    assert :boids.update(flock, id, %{rules: [{:arrive, 1.0, %{target: {10, 10}}}]}) == :ok
    for _ <- 1..400, do: :boids.step(flock, 0.05)
    {:ok, %{pos: pos}} = :boids.lookup(flock, id)
    assert_vec(pos, {10.0, 10.0}, 0.1)

    # One rule at a time, with a name for each of two rules of seek.
    assert :boids.add_rule(flock, id, {{:seek, :home}, 1.0, %{target: {0, 0}}}) == :ok
    assert :boids.add_rule(flock, id, {{:seek, :food}, 2.0, %{target: {40, 10}}}) == :ok
    assert :boids.which_rules(flock, id) == {:ok, [:arrive, {:seek, :home}, {:seek, :food}]}
    assert :boids.delete_rule(flock, id, {:seek, :food}) == :ok
    assert :boids.which_rules(flock, id) == {:ok, [:arrive, {:seek, :home}]}
  end

  test "a rule of your own", %{flock: flock} do
    gravity = fn _boid, _neighbors, _env -> {0, -9.81} end

    fear = fn boid, neighbors, _env ->
      case Enum.filter(neighbors, &(&1.group == :cats)) do
        [%{pos: pos} | _] -> :boids_steer.flee(boid, pos)
        [] -> {0, 0}
      end
    end

    {:ok, id} =
      :boids.add(flock, pos: {50, 50}, rules: [{gravity, 1.0}, {fear, 3.0}], max_speed: 5, tick: :manual)

    {:ok, _cat} = :boids.add(flock, pos: {53, 50}, group: :cats, rules: [], max_speed: 0, tick: :manual)
    for _ <- 1..10, do: :boids.step(flock, 0.05)
    {:ok, %{vel: {vx, vy}}} = :boids.lookup(flock, id)
    # The boid moves down, and away from the cat.
    assert vx < 0 and vy < 0
  end

  test "the relations between the boids", %{flock: flock} do
    {:ok, leader} =
      :boids.add(flock, pos: {50, 50}, vel: {2, 0}, rules: [cruise: 1.0], max_speed: 2, tick: :manual)

    {:ok, bird} = :boids.add(flock, pos: {20, 80}, rules: [], tick: :manual)

    assert :boids.relate(flock, bird, :follows, leader) == :ok
    assert :boids.update(flock, bird, %{rules: [{:leader, 1.0, %{target: {:related, :follows}}}]}) == :ok
    assert :boids.related(flock, bird, :follows) == [leader]
    assert :boids.related_to(flock, leader, :follows) == [bird]

    relations = :boids.relations(flock)
    assert :graph.in_neighbours(relations, leader) == [bird]
    assert :graph.get_path(relations, bird, leader) == [bird, leader]

    # The bird comes behind its leader.
    for _ <- 1..400, do: :boids.step(flock, 0.05)
    {:ok, %{pos: at}} = :boids.lookup(flock, bird)
    {:ok, %{pos: to}} = :boids.lookup(flock, leader)
    assert :boids_vec.norm(:boids_space.offset(:boids.space(flock), at, to)) < 10

    # The relations of a boid go with the boid.
    assert :boids.remove(flock, leader) == :ok
    assert :boids.related(flock, bird, :follows) == []
  end

  test "a hierarchy has no cycle" do
    {:ok, flock} = :boids.start_flock(relations: :acyclic)
    {:ok, a} = :boids.add(flock, pos: {0, 0}, tick: :manual)
    {:ok, b} = :boids.add(flock, pos: {1, 0}, tick: :manual)
    assert :boids.relate(flock, a, :follows, b) == :ok
    assert :boids.relate(flock, b, :follows, a) == {:error, :cycle}
    assert :graph.topsort(:boids.relations(flock)) == [a, b]
    :boids.stop_flock(flock)
  end

  test "the flock as a graph", %{flock: flock} do
    still = [rules: [], tick: :manual]
    {:ok, a} = :boids.add(flock, [pos: {10, 10}] ++ still)
    {:ok, b} = :boids.add(flock, [pos: {15, 10}] ++ still)
    {:ok, c} = :boids.add(flock, [pos: {60, 60}] ++ still)

    graph = :boids.graph(flock, 10)
    assert Enum.sort(Enum.map(:graph.components(graph), &Enum.sort/1)) == Enum.sort([Enum.sort([a, b]), [c]])
    assert for(id <- :graph.vertices(graph), :graph.out_degree(graph, id) == 0, do: id) == [c]
    assert :graph.has_path(graph, a, b)
    refute :graph.has_path(graph, a, c)
  end

  test "a process of yours as a boid", %{flock: flock} do
    {:ok, pid} = GenServer.start_link(Person, flock)
    assert {:ok, %{pos: {0, 0}}} = :boids.lookup(flock, pid)
    assert eventually(fn -> elem(:boids.lookup(flock, pid), 1).pos != {0, 0} end)
    GenServer.stop(pid)
    assert eventually(fn -> :boids.count(flock) == 0 end)
  end

  test "a flock below a supervisor of yours" do
    children = [{:boids, name: :boids_readme_flock, bounds: {{0, 0}, {100, 100}}}]
    {:ok, sup} = Supervisor.start_link(children, strategy: :one_for_one)
    assert :boids.count(:boids_readme_flock) == 0
    Supervisor.stop(sup)
  end
end
