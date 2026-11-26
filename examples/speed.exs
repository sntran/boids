# The speed of a flock on this computer.
#
#     mix run examples/speed.exs [BOIDS] [NEIGHBORS]
#
# The script makes steps with `boids:step/2`, as fast as the computer can,
# for 1 worker, then 2, then 4, to the number of the schedulers. It shows
# the boid steps in a second, and the boids that the flock can move at 20
# and at 60 steps in a second.

defmodule Speed do
  @steps 20

  def run(count, neighbors) do
    # The boids see the distance 10: this side gives the number of
    # neighbors.
    side = :math.sqrt(count / neighbors * :math.pi() * 100)
    IO.puts("#{count} boids with the three rules of a flock, about #{neighbors} neighbors for each boid\n")
    IO.puts("| Workers | Boid steps in a second | Boids at 20 steps in a second | Boids at 60 |")
    IO.puts("|---|---|---|---|")

    for workers <- workers(1, System.schedulers_online()) do
      {:ok, flock} =
        :boids.start_flock(bounds: {{0, 0}, {side, side}}, wrap: true, tick: :manual, workers: workers)

      {:ok, _ids} = :boids.populate(flock, count, %{})
      # The first steps move the boids from random positions to a flock.
      for _ <- 1..@steps, do: :boids.step(flock, 0.05)
      {time, _} = :timer.tc(fn -> for _ <- 1..@steps, do: :boids.step(flock, 0.05) end)
      rate = count * @steps / (time / 1.0e6)
      IO.puts("| #{workers} | #{round(rate)} | #{round(rate / 20)} | #{round(rate / 60)} |")
      :ok = :boids.stop_flock(flock)
    end
  end

  defp workers(n, max) when n >= max, do: [max]
  defp workers(n, max), do: [n | workers(n * 2, max)]
end

{count, neighbors} =
  case System.argv() do
    [] -> {10_000, 15}
    [count] -> {String.to_integer(count), 15}
    [count, neighbors] -> {String.to_integer(count), String.to_integer(neighbors)}
  end

Speed.run(count, neighbors)
