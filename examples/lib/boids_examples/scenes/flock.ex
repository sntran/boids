defmodule BoidsExamples.Scenes.Flock do
  @moduledoc """
  The scene of the home page: birds that flock, a hawk that hunts them
  and then rests, and two rocks.
  """
  @behaviour BoidsExamples.Scene

  defmodule Hawk do
    @moduledoc "A hawk hunts the birds that it sees while it has energy. Then it rests."
    @behaviour :gen_boid

    @hunt [{:avoid, 4.0, %{lookahead: 1.5}}, {:pursue, 1.0, %{target: {:group, :birds}}}]
    @rest [{:avoid, 4.0, %{lookahead: 1.5}}, {:wander, 1.0}, {:cruise, 0.5, %{speed: 4.0}}]

    @impl true
    def init(pos) do
      {:ok,
       %{
         id: :hawk,
         pos: pos,
         group: :hawks,
         perception: 28,
         rules: @rest,
         combine: :priority,
         state: %{mode: :rests, energy: 6.0}
       }}
    end

    # Sense: the prey are the birds that the hawk sees.
    @impl true
    def handle_sense(%{neighbors: neighbors} = seen, boid) do
      {:ok, Map.put(seen, :prey, Enum.filter(neighbors, &(&1.group == :birds))), boid}
    end

    # Decide: hunt with energy and prey, rest with no energy.
    @impl true
    def handle_decide(%{prey: prey}, %{state: %{mode: mode, energy: energy} = state} = boid) do
      case {mode, energy, prey} do
        {:hunts, energy, _} when energy <= 0.5 ->
          {:ok, %{:boids_boid.update(boid, %{rules: @rest, max_speed: 6.0}) | state: %{state | mode: :rests}}}

        {:rests, energy, [_ | _]} when energy >= 9.5 ->
          {:ok, %{:boids_boid.update(boid, %{rules: @hunt, max_speed: 15.0}) | state: %{state | mode: :hunts}}}

        _ ->
          {:ok, boid}
      end
    end

    # Act: a hunt uses energy, and a rest gives it. The data of the hawk
    # shows its mode and its energy to the page.
    @impl true
    def handle_act(%{state: %{mode: mode, energy: energy} = state} = boid) do
      step = BoidsExamples.Scene.tick() / 1000
      energy = if mode == :hunts, do: max(energy - 0.8 * step, 0.0), else: min(energy + 0.6 * step, 10.0)
      {:ok, %{boid | state: %{state | energy: energy}, data: {mode, energy}}}
    end
  end

  @impl true
  def start(_definition) do
    {:ok, world} =
      :boids.start_world(bounds: {{0, 0}, {160, 60}}, wrap: true, defaults: %{tick: BoidsExamples.Scene.tick()})

    space = :boids.space(world)
    :ok = :boids.set_obstacle(space, :west, {42, 38}, 6)
    :ok = :boids.set_obstacle(space, :east, {118, 20}, 7)

    birds = [
      {:avoid, 4.0, %{lookahead: 1.5}},
      {:evade, 3.0, %{target: {:group, :hawks}, radius: 16}},
      {:separation, 1.5, %{radius: 3}},
      {:alignment, 1.0},
      {:cohesion, 1.0}
    ]

    {:ok, _} =
      :boids.populate(space, 60,
        group: :birds,
        rules: birds,
        min_speed: 6,
        max_speed: 12,
        combine: :priority,
        search: 2
      )

    {:ok, _hawk} = :gen_boid.start(space, Hawk, {20, 20})
    {:ok, %{space: space}}
  end

  @impl true
  def kinds(_scene) do
    [%{name: "birds", shape: "bird", color: "ink", size: 1.4}, %{name: "hawk", shape: "bird", color: "warm", size: 2.8}]
  end

  @impl true
  def look(_scene, %{group: :hawks, vel: vel}), do: {1, BoidsExamples.Scene.angle(vel), 0}
  def look(_scene, %{vel: vel}), do: {0, BoidsExamples.Scene.angle(vel), 0}

  @impl true
  def more(%{space: space}, _number) do
    case :boids.lookup(space, :hawk) do
      {:ok, %{data: {mode, energy}}} -> %{r: [["The hawk", to_string(mode)], ["Its energy", Float.round(energy, 1)]]}
      _ -> %{}
    end
  end
end
