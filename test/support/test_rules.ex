defmodule Boids.TestRules do
  @moduledoc false

  defmodule Push do
    @moduledoc "A rule with only the necessary callbacks: a constant force."
    @behaviour :gen_boid

    @impl true
    def init(args) do
      force = if is_map(args), do: Map.get(args, :force, {0, 1}), else: args
      if :boids_vec.is_vec(force), do: {:ok, force}, else: {:error, {:bad_force, force}}
    end

    @impl true
    def handle_step(_boid, _neighbors, _env, force), do: {:force, force, force}
  end

  defmodule Turn do
    @moduledoc "A rule with a state: the force turns a quarter of a circle at each step."
    @behaviour :gen_boid

    @impl true
    def init(_args), do: {:ok, {1, 0}}

    @impl true
    def handle_step(_boid, _neighbors, _env, {x, y}), do: {:force, {x, y}, {-y, x}}
  end

  defmodule Mind do
    @moduledoc """
    A rule with each callback. It gives no force. It counts the steps of
    the boid, and does what its state `plan` tells at a step: a map from
    the number of a step to a result of handle_step/4.
    """
    @behaviour :gen_boid

    @impl true
    def init(:refuse), do: {:error, :refused}
    def init(:crash), do: raise("no start")
    def init(:nonsense), do: :nonsense
    def init(:exit), do: exit(:no_start)
    def init({args, last}), do: init(Map.put(args, :last, last))
    def init(args), do: {:ok, Map.merge(%{owner: nil, steps: 0, plan: %{}}, args)}

    @impl true
    def handle_step(boid, neighbors, env, state) do
      state = %{state | steps: state.steps + 1}
      if state.owner, do: send(state.owner, {:step, state.steps, boid.pos, length(neighbors), env})

      case Map.get(state.plan, state.steps) do
        nil -> {:ok, state}
        :crash -> raise "a fault of a rule"
        :throw -> throw(:a_fault)
        :exit -> exit(:a_fault)
        {:force, force} -> {:force, force, state}
        {:force, force, actions} -> {:force, force, state, actions}
        {:actions, actions} -> {:ok, state, actions}
        other -> other
      end
    end

    @impl true
    def handle_call(:steps, _boid, state), do: {:ok, state.steps, state}
    def handle_call(:where, boid, state), do: {:ok, boid.pos, state}
    def handle_call({:plan, plan}, _boid, state), do: {:ok, :ok, %{state | plan: plan}}
    def handle_call({:actions, actions}, _boid, state), do: {:ok, :done, state, actions}
    def handle_call(:leave, _boid, _state), do: {:remove_rule, :bye}
    def handle_call(:crash, _boid, _state), do: raise("a fault of a call")
    def handle_call(:nonsense, _boid, _state), do: :nonsense

    @impl true
    def handle_info({:count, n}, _boid, state), do: {:ok, %{state | steps: state.steps + n}}
    def handle_info({:actions, actions}, _boid, state), do: {:ok, state, actions}
    def handle_info(:leave, _boid, _state), do: :remove_rule
    def handle_info(:crash, _boid, _state), do: raise("a fault of a message")
    def handle_info(:nonsense, _boid, _state), do: :nonsense
    def handle_info(_info, _boid, state), do: {:ok, state}

    @impl true
    def terminate(arg, state) do
      if state.owner, do: send(state.owner, {:terminated, arg, state.steps})
      if arg == :crash or Map.get(state, :last) == :crash, do: raise("a fault of the end")
      {:ended, state.steps}
    end
  end
end
