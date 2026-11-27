defmodule Boids.TestBoids do
  @moduledoc false

  defmodule Hawk do
    @moduledoc """
    A boid with each callback of gen_boid. It hunts the mice that it sees,
    and counts its steps. Its state tells where it stops, and where it
    gives a boid with another id.
    """
    @behaviour :gen_boid

    @impl true
    def init(:ignore), do: :ignore
    def init({:stop, reason}), do: {:stop, reason}

    def init(args) do
      if args[:trap], do: Process.flag(:trap_exit, true)

      state = %{
        owner: args[:owner],
        steps: 0,
        acts: 0,
        seen: [],
        stop_at: args[:stop_at],
        stop_in: Map.get(args, :stop_in, :decide),
        other_id_in: args[:other_id_in]
      }

      options = %{pos: {0, 0}, group: :hawks, rules: [], tick: :manual, state: state}
      {:ok, Map.merge(options, Map.get(args, :boid, %{}))}
    end

    @impl true
    def handle_sense(_seen, %{state: %{stop_in: :sense, steps: steps, stop_at: steps}} = boid),
      do: {:stop, :normal, boid}

    def handle_sense(seen, %{state: %{other_id_in: :sense}} = boid),
      do: {:ok, seen, %{boid | id: :other}}

    def handle_sense(%{neighbors: neighbors} = seen, %{state: state} = boid) do
      mice = Enum.filter(neighbors, &(&1.group == :mice))
      # The state has what the boid saw: the tests ask for it.
      {:ok, Map.put(seen, :mice, mice),
       %{boid | state: %{state | seen: for(n <- neighbors, do: {n.id, n.pos})}}}
    end

    @impl true
    def handle_decide(_seen, %{state: %{stop_in: :decide, steps: steps, stop_at: steps}} = boid),
      do: {:stop, :normal, boid}

    def handle_decide(_seen, %{state: %{other_id_in: :decide}} = boid), do: {:ok, %{boid | id: :other}}

    def handle_decide(%{mice: mice}, %{state: state} = boid) do
      boid = %{boid | state: %{state | steps: state.steps + 1}}

      case mice do
        [] ->
          {:ok, boid}

        [mouse | _] ->
          {:ok,
           :boids_boid.update(boid, %{rules: [{:seek, 1, %{target: mouse.pos}}], data: {:hunts, mouse.id}})}
      end
    end

    @impl true
    def handle_act(%{state: %{stop_in: :act, steps: steps, stop_at: steps}} = boid),
      do: {:stop, :normal, boid}

    def handle_act(%{state: %{other_id_in: :act}} = boid), do: {:ok, %{boid | id: :other}}

    def handle_act(%{state: state} = boid) do
      # The boid is where it moved to.
      {:ok, %{boid | state: Map.merge(state, %{acts: state.acts + 1, at: boid.pos})}}
    end

    @impl true
    def handle_call(:steps, _from, boid), do: {:reply, boid.state.steps, boid}
    def handle_call(:state, _from, boid), do: {:reply, boid.state, boid}
    def handle_call(:where, _from, boid), do: {:reply, boid.pos, boid}
    def handle_call({:go, pos}, _from, boid), do: {:reply, :ok, :boids_boid.update(boid, %{pos: pos})}

    def handle_call(:later, from, boid) do
      send(self(), {:answer, from})
      {:noreply, boid}
    end

    def handle_call({:later, group}, from, boid) do
      send(self(), {:answer, from})
      {:noreply, %{boid | group: group}}
    end

    def handle_call(:stop, _from, boid), do: {:stop, :normal, :bye, boid}
    def handle_call(:fail, _from, boid), do: {:stop, :normal, boid}
    def handle_call(:other_id, _from, boid), do: {:reply, :ok, %{boid | id: :other}}

    @impl true
    def handle_cast({:data, data}, boid), do: {:noreply, %{boid | data: data}}

    def handle_cast(:count, %{state: state} = boid),
      do: {:noreply, %{boid | state: %{state | steps: state.steps + 100}}}

    def handle_cast(:stop, boid), do: {:stop, :normal, boid}

    @impl true
    def handle_info({:answer, from}, boid) do
      :gen_boid.reply(from, {:later, boid.group})
      {:noreply, boid}
    end

    def handle_info({:speed, speed}, boid), do: {:noreply, :boids_boid.update(boid, %{max_speed: speed})}
    def handle_info(:stop, boid), do: {:stop, :normal, boid}
    def handle_info(_info, boid), do: {:noreply, boid}

    @impl true
    def terminate(reason, %{state: state} = boid) do
      if state.owner, do: send(state.owner, {:terminated, reason, boid.id, state.steps})
    end
  end

  defmodule Mouse do
    @moduledoc "A boid with only the necessary callback."
    @behaviour :gen_boid

    @impl true
    def init(options), do: {:ok, options}
  end
end
