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

  defmodule Traveler do
    @moduledoc """
    A boid for the tests of a world on several nodes. It counts its
    steps in its state. With `stop_at` in its state, it stops its
    movement when its x is that number or more. At its end, it keeps the
    reason and its state where a test of another node can read them.
    """
    @behaviour :gen_boid

    @impl true
    def init(options), do: {:ok, options}

    @impl true
    def handle_decide(_seen, %{pos: pos, state: %{stop_at: stop}} = boid) when elem(pos, 0) >= stop do
      {:ok, :boids_boid.update(boid, %{min_speed: 0, max_speed: 0, vel: {0, 0}})}
    end

    def handle_decide(_seen, boid), do: {:ok, boid}

    @impl true
    def handle_act(%{state: state} = boid), do: {:ok, %{boid | state: %{state | steps: state.steps + 1}}}

    @impl true
    def terminate(reason, boid), do: :persistent_term.put({__MODULE__, boid.id}, {reason, boid.state})
  end

  defmodule Person do
    @moduledoc "A process with another behavior that is a boid (boids:join/2)."
    use GenServer

    @impl true
    def init({world, options}) do
      {:ok, space, boid} = :boids.join(world, options)
      {:ok, {space, boid}}
    end

    # Put the boid at a position, and write it to the world.
    @impl true
    def handle_call({:go, pos}, _from, {space, boid}) do
      boid = :boids_boid.update(boid, %{pos: pos})
      {:reply, :boids.commit(space, boid), {space, boid}}
    end
  end

  defmodule Mouse do
    @moduledoc "A boid with only the necessary callback."
    @behaviour :gen_boid

    @impl true
    def init(options), do: {:ok, options}
  end

  defmodule Keeper do
    @moduledoc """
    A boid with a table of ETS in its state: the table has the number of
    its steps. `handle_load/2` makes the table again after a load. It
    also changes the state of a save of the version 1, which had no key
    `loads`. With the key `answer` in the state, it gives that answer.
    """
    @behaviour :gen_boid
    @vsn 2

    @impl true
    def init(options) do
      state = %{table: table(0), steps: 0, loads: 0}
      {:ok, Map.merge(%{pos: {0, 0}, rules: [], tick: :manual, state: state}, Map.new(options))}
    end

    @impl true
    def handle_act(%{state: state} = boid),
      do: {:ok, %{boid | state: %{state | steps: :ets.update_counter(state.table, :steps, 1)}}}

    @impl true
    def handle_call(:state, _from, boid), do: {:reply, boid.state, boid}
    def handle_call(:steps, _from, boid), do: {:reply, :ets.lookup_element(boid.state.table, :steps, 2), boid}

    @impl true
    def handle_load(1, %{state: state} = boid), do: handle_load(2, %{boid | state: Map.put(state, :loads, 0)})
    def handle_load(2, %{state: %{answer: answer}}), do: answer

    def handle_load(2, %{state: state} = boid),
      do: {:ok, %{boid | state: %{state | table: table(state.steps), loads: state.loads + 1}}}

    @doc "A table with a number of steps."
    def table(steps) do
      table = :ets.new(:keeper, [])
      :ets.insert(table, {:steps, steps})
      table
    end
  end

  defmodule Loose do
    @moduledoc "A boid as `Keeper`, with no `handle_load/2`: after a load, it does not have its table."
    @behaviour :gen_boid

    @impl true
    def init(options) do
      state = %{table: Keeper.table(0), steps: 0}
      {:ok, Map.merge(%{pos: {0, 0}, rules: [], tick: :manual, state: state}, Map.new(options))}
    end

    @impl true
    def handle_act(%{state: state} = boid),
      do: {:ok, %{boid | state: %{state | steps: :ets.update_counter(state.table, :steps, 1)}}}
  end
end
