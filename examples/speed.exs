# The speed of a flock on this computer.
#
#     mix run examples/speed.exs [BOIDS] [NEIGHBORS]
#
# The script starts boids that make 20 steps in a second
# (`tick => 50`), and counts the steps that they make. With too many
# boids for the computer, each boid makes fewer steps. It does this for
# boids that search their neighbors at each step, and for boids that
# search them at one step of 4 (`search => 4`).

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

  def run(count, neighbors) do
    # The boids see the distance 10: this side gives the number of
    # neighbors.
    side = :math.sqrt(count / neighbors * :math.pi() * 100)
    IO.puts("#{count} boids with the three rules of a flock, about #{neighbors} neighbors for each boid\n")
    IO.puts("| Search | Boid steps in a second | Steps of each boid in a second |")
    IO.puts("|---|---|---|")

    for search <- [1, 4] do
      {:ok, environment} = :boids.start_environment(bounds: {{0, 0}, {side, side}}, wrap: true)
      steps = :counters.new(1, [:write_concurrency])

      for _ <- 1..count do
        pos = {:rand.uniform() * side, :rand.uniform() * side}
        vel = :boids_vec.scale(:boids_vec.random_unit(2), 5.0)
        {:ok, _} = :gen_boid.start(environment, Counter, %{pos: pos, vel: vel, search: search, state: steps})
      end

      # The first seconds move the boids from random positions to flocks.
      Process.sleep(3000)
      before = :counters.get(steps, 1)
      Process.sleep(5000)
      rate = (:counters.get(steps, 1) - before) / 5
      IO.puts("| each #{search} steps | #{round(rate)} | #{Float.round(rate / count, 1)} |")
      :ok = :boids.stop_environment(environment)
    end
  end
end

{count, neighbors} =
  case System.argv() do
    [] -> {4000, 15}
    [count] -> {String.to_integer(count), 15}
    [count, neighbors] -> {String.to_integer(count), String.to_integer(neighbors)}
  end

Speed.run(count, neighbors)
