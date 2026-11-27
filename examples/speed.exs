# The speed of a flock on this computer.
#
#     mix run examples/speed.exs [BOIDS] [NEIGHBORS] [OBSTACLES]
#
# The script starts boids that make 20 steps in a second
# (`tick => 50`), and counts the steps that they make. With too many
# boids for the computer, each boid makes fewer steps. It does this for
# boids that search their neighbors at each step, and for boids that
# search them at one step of 4 (`search => 4`).
#
# With OBSTACLES, the world has that number of obstacles (circles of
# radius 1 at random places), and each boid also has the rule `avoid`.

defmodule Speed do
  # A boid that counts its steps.
  defmodule Counter do
    @behaviour :gen_boid

    @impl true
    def init(options), do: {:ok, options}

    @impl true
    def handle_act(%{state: steps} = boid) do
      :counters.add(steps, 1, 1)
      {:ok, boid}
    end
  end

  def run(count, neighbors, obstacles) do
    # The boids see the distance 10: this side gives the number of
    # neighbors.
    side = :math.sqrt(count / neighbors * :math.pi() * 100)
    IO.puts("#{count} boids with the three rules of a flock, about #{neighbors} neighbors for each boid")
    if obstacles > 0, do: IO.puts("#{obstacles} obstacles, and the rule avoid for each boid")
    IO.puts("\n| Search | Boid steps in a second | Steps of each boid in a second |")
    IO.puts("|---|---|---|")

    rules =
      [{:separation, 1.5}, {:alignment, 1.0}, {:cohesion, 1.0}] ++
        if obstacles > 0, do: [{:avoid, 3.0}], else: []

    for search <- [1, 4] do
      {:ok, world} = :boids.start_world(bounds: {{0, 0}, {side, side}}, wrap: true)
      steps = :counters.new(1, [:write_concurrency])

      for id <- 1..obstacles//1,
          do: :ok = :boids.set_obstacle(world, id, {:rand.uniform() * side, :rand.uniform() * side}, 1)

      for _ <- 1..count do
        pos = {:rand.uniform() * side, :rand.uniform() * side}
        vel = :boids_vec.scale(:boids_vec.random_unit(2), 5.0)
        options = %{pos: pos, vel: vel, search: search, rules: rules, state: steps}
        {:ok, _} = :gen_boid.start(world, Counter, options)
      end

      # The first seconds move the boids from random positions to flocks.
      Process.sleep(3000)
      before = :counters.get(steps, 1)
      Process.sleep(5000)
      rate = (:counters.get(steps, 1) - before) / 5
      IO.puts("| each #{search} steps | #{round(rate)} | #{Float.round(rate / count, 1)} |")
      :ok = :boids.stop_world(world)
    end
  end
end

{count, neighbors, obstacles} =
  case Enum.map(System.argv(), &String.to_integer/1) do
    [] -> {4000, 15, 0}
    [count] -> {count, 15, 0}
    [count, neighbors] -> {count, neighbors, 0}
    [count, neighbors, obstacles] -> {count, neighbors, obstacles}
  end

Speed.run(count, neighbors, obstacles)
