defmodule BoidsReadmeTest do
  # The examples of README.md.
  use ExUnit.Case, async: true
  import Boids.Helpers

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

    assert [%{id: _, pos: {_, _}, vel: {_, _}, group: :default, data: :undefined, pid: _} | _] =
             :boids.snapshot(flock)

    before = Map.new(:boids.snapshot(flock), &{&1.id, &1.pos})
    assert eventually(fn -> Enum.all?(:boids.snapshot(flock), &(&1.pos != before[&1.id])) end)
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
