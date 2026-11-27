defmodule BoidsSite.Scene do
  @moduledoc """
  A scene: one flock that one visitor sees. A module of a scene starts
  the flock, and tells how the page draws its boids.

  The site has a limit of the scenes at one time (`BOIDS_SCENES`, default
  8), because all the scenes use the processor of one VM. A scene stops
  when the process of its visitor stops.
  """

  @typedoc "A scene: its flock, the space of the flock, and what its module keeps."
  @type t :: %{required(:flock) => pid(), required(:space) => map(), optional(atom()) => term()}

  @doc "Start the scene. The argument is the definition of a visitor, or nil."
  @callback start(term()) :: {:ok, t()} | {:error, String.t()}

  @doc "The kinds of boids of the scene, in the order of their numbers: how the page draws each one."
  @callback kinds(t()) :: [map()]

  @doc "The kind, the direction and the size of a boid, from its row."
  @callback look(t(), map()) :: {non_neg_integer(), number(), number()}

  @doc "More for a moment: `r` (readings for the page), and other keys."
  @callback more(t(), pos_integer()) :: map()

  @doc "A message of the visitor."
  @callback input(t(), map()) :: :ok

  @doc "The work of each second: for example new boids for boids that are gone."
  @callback direct(t()) :: :ok

  @optional_callbacks more: 2, input: 2, direct: 1

  @doc "The milliseconds between two steps of a boid, and between two moments for the page."
  def tick, do: String.to_integer(System.get_env("BOIDS_TICK", "50"))

  def setup do
    :persistent_term.put(__MODULE__, :counters.new(1, []))
  end

  @doc "Start a scene of a module for the process that calls this function."
  def start(module, arg) do
    count = :persistent_term.get(__MODULE__)
    limit = String.to_integer(System.get_env("BOIDS_SCENES", "8"))

    if :counters.get(count, 1) >= limit do
      {:error, "The site shows #{limit} scenes at one time, and all are in use. Try again in a minute."}
    else
      with {:ok, scene} <- module.start(arg) do
        :counters.add(count, 1, 1)
        visitor = self()
        # The scene stops with the process of its visitor.
        spawn(fn ->
          ref = Process.monitor(visitor)

          receive do
            {:DOWN, ^ref, :process, _pid, _reason} -> :ok
            :stop -> :ok
          end

          :boids.stop_flock(scene.flock)
          :counters.sub(count, 1, 1)
        end)
        |> then(&{:ok, Map.merge(scene, %{module: module, guard: &1})})
      end
    end
  end

  def stop(%{guard: guard}), do: send(guard, :stop)

  @doc "What does not change in a scene: the box, the kinds and the rocks."
  def header(%{module: module, space: space} = scene) do
    %{bounds: {_min, {width, height}}} = space

    %{
      box: [width, height],
      tick: tick(),
      kinds: module.kinds(scene),
      rocks: for(%{pos: {x, y}, radius: radius} <- :boids.obstacles(space), do: [x, y, radius])
    }
  end

  @doc """
  One moment of a scene: for each boid, a number in place of its id, its
  position, its direction, its kind and its size. Each second, the moment
  also has the relations between the boids.
  """
  def frame(%{module: module, space: space} = scene, number) do
    boids =
      Enum.flat_map(:boids.snapshot(space), fn %{id: id, pos: {x, y}} = row ->
        {kind, angle, size} = module.look(scene, row)
        [number(id), Float.round(x * 1.0, 1), Float.round(y * 1.0, 1), Float.round(angle * 1.0, 2), kind, size]
      end)

    frame = %{n: number, b: boids}
    frame = if function_exported?(module, :more, 2), do: Map.merge(frame, module.more(scene, number)), else: frame

    if rem(number * tick(), 1000) < tick() do
      if function_exported?(module, :direct, 1), do: module.direct(scene)
      links = for {from, to, _label} <- :graph.edges(:boids.relations(space)), do: [number(from), number(to)]
      Map.put(frame, :l, links)
    else
      frame
    end
  end

  def input(%{module: module} = scene, message) do
    if function_exported?(module, :input, 2), do: module.input(scene, message), else: :ok
  end

  @doc "The direction of a velocity, as an angle."
  def angle({vx, vy}), do: :math.atan2(vy, vx)

  # A small number for the page in place of the id of a boid.
  defp number(id), do: :erlang.phash2(id, 1_000_000)
end
