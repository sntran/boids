defmodule Boids.TestBoids do
  @moduledoc false

  defmodule Hawk do
    @moduledoc """
    A boid with each callback of gen_boid. It wanders, hunts the mice that
    it sees, and counts its steps.
    """
    @behaviour :gen_boid

    @impl true
    def init(:ignore), do: :ignore
    def init({:stop, reason}), do: {:stop, reason}

    def init(args) do
      if args[:trap], do: Process.flag(:trap_exit, true)
      options = Map.merge(%{pos: {0, 0}, group: :hawks, rules: [], tick: :manual}, Map.get(args, :boid, %{}))
      {:ok, options, %{owner: args[:owner], steps: 0, stop_at: args[:stop_at]}}
    end

    @impl true
    def handle_step(_boid, _neighbors, %{steps: steps, stop_at: steps} = state), do: {:stop, :normal, state}

    def handle_step(_boid, neighbors, state) do
      state = %{state | steps: state.steps + 1}

      case Enum.find(neighbors, &(&1.group == :mice)) do
        nil -> {:ok, state}
        mouse -> {:ok, %{rules: [{:seek, 1, %{target: mouse.pos}}], data: {:hunts, mouse.id}}, state}
      end
    end

    @impl true
    def handle_call(:steps, _from, _boid, state), do: {:reply, state.steps, state}
    def handle_call(:where, _from, boid, state), do: {:reply, boid.pos, state}
    def handle_call({:go, pos}, _from, _boid, state), do: {:reply, :ok, %{pos: pos}, state}

    def handle_call(:later, from, _boid, state) do
      send(self(), {:answer, from})
      {:noreply, state}
    end

    def handle_call({:later, group}, from, _boid, state) do
      send(self(), {:answer, from})
      {:noreply, %{group: group}, state}
    end

    def handle_call(:stop, _from, _boid, state), do: {:stop, :normal, :bye, state}
    def handle_call(:fail, _from, _boid, state), do: {:stop, :normal, state}

    @impl true
    def handle_cast({:data, data}, _boid, state), do: {:noreply, %{data: data}, state}
    def handle_cast(:count, _boid, state), do: {:noreply, %{state | steps: state.steps + 100}}
    def handle_cast(:stop, _boid, state), do: {:stop, :normal, state}

    @impl true
    def handle_info({:answer, from}, boid, state) do
      :gen_boid.reply(from, {:later, boid.group})
      {:noreply, state}
    end

    def handle_info({:speed, speed}, _boid, state), do: {:noreply, %{max_speed: speed}, state}
    def handle_info(:stop, _boid, state), do: {:stop, :normal, state}
    def handle_info(_info, _boid, state), do: {:noreply, state}

    @impl true
    def terminate(reason, boid, state) do
      if state.owner, do: send(state.owner, {:terminated, reason, boid.id, state.steps})
    end
  end

  defmodule Mouse do
    @moduledoc "A boid with only the necessary callback."
    @behaviour :gen_boid

    @impl true
    def init(options), do: {:ok, options, nil}
  end
end
