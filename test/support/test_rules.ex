defmodule Boids.TestRules do
  @moduledoc false

  defmodule Push do
    @moduledoc "A rule with options: a constant force."
    @behaviour :boids_rule

    @impl true
    def options(options) do
      %{force: force} = options = Map.merge(%{force: {0, 1}}, options)
      true = :boids_vec.is_vec(force)
      options
    end

    @impl true
    def force(_boid, _neighbors, _env, %{force: force}), do: force
  end

  defmodule Turn do
    @moduledoc "A rule with a memory and no check of its options: the force turns at each step."
    @behaviour :boids_rule

    @impl true
    def force(_boid, _neighbors, %{memory: memory}, options) do
      # The first call has no memory.
      {x, y} = if memory == :undefined, do: Map.get(options, :start, {1, 0}), else: memory
      {{x, y}, {-y, x}}
    end
  end

  defmodule NoMap do
    @moduledoc "A rule whose check does not give a map."
    @behaviour :boids_rule

    @impl true
    def options(_options), do: :ok

    @impl true
    def force(_boid, _neighbors, _env, _options), do: {0, 0}
  end
end
