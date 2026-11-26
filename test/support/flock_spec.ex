defmodule Boids.FlockSpec do
  @moduledoc """
  The replay of a real flock process (`boids_flock`) as a behavior of
  `specs/Flock.tla`.

  `trace/1` records each message that the process of a flock handles: a
  join with its answer, a leave, and a `'DOWN'`. `replay/4` takes these
  events in their order. Each event is one action of the flock in the
  specification (`Join`, `Leave`, `Down`), and the answer of a join must
  be the answer of the specification. At the end, the rows of the real
  table must be the rows of the specification.

  The flock does not see the acts of the other processes: the start of a
  process, its end, and the call of `boids:remove/2` or `boids:leave/2`.
  The replay puts them where the events need them. When two orders are
  possible (for a join: the process of the row stopped, or not), it
  follows each one. The replay diverges when no order explains the
  events.

  Each join is one process of the specification, so a process of the
  code with two boids is two processes there.
  """
  alias Accord.TLA.Checker.Machine

  @specs Path.expand("../../specs", __DIR__)

  # --- The trace --------------------------------------------------------

  @doc """
  Start to record the messages that the process of `flock` handles. The
  record has its own trace session, so other tracers of the node and
  other records do not change it.
  """
  def trace(flock) do
    recorder = spawn_link(fn -> record([]) end)
    session = :trace.session_create(:boids_flock_spec, recorder, [])
    :trace.function(session, {:boids_flock, :handle_call, 3}, [{:_, [], [{:return_trace}]}], [:local])
    :trace.function(session, {:boids_flock, :handle_info, 2}, true, [:local])
    :trace.process(session, flock, true, [:call])
    {session, recorder}
  end

  @doc """
  Stop the record, and give the events in their order: `{:join, pid, id,
  answer}`, `{:leave, pid, id}` and `{:down, pid, id}`.
  """
  def events(flock, {session, recorder}) do
    :trace.process(session, flock, false, [:call])
    ref = :trace.delivered(session, flock)

    receive do
      {:trace_delivered, ^flock, ^ref} -> :ok
    end

    :trace.session_destroy(session)

    send(recorder, {:give, self()})

    receive do
      {:recorded, messages} -> parse(messages)
    end
  end

  defp record(messages) do
    receive do
      {:give, to} -> send(to, {:recorded, Enum.reverse(messages)})
      message -> record([message | messages])
    end
  end

  defp parse([
         {:trace, _, :call, {_, :handle_call, [{:join, pid, %{id: id}}, _, _]}},
         {:trace, _, :return_from, _, reply} | rest
       ]) do
    [{:join, pid, id, elem(reply, 1)} | parse(rest)]
  end

  defp parse([{:trace, _, :call, {_, :handle_call, [{:leave, id, pid}, _, _]}} | rest]) do
    [{:leave, pid, id} | parse(rest)]
  end

  defp parse([{:trace, _, :call, {_, :handle_info, [{:DOWN, ref, :process, pid, _}, %{refs: refs}]}} | rest]) do
    [{:down, pid, Map.get(refs, ref, :unknown)} | parse(rest)]
  end

  defp parse([_ | rest]), do: parse(rest)
  defp parse([]), do: []

  # --- The replay -------------------------------------------------------

  @doc """
  Replay the events of a flock in `dir`. `table` has the rows of the real
  flock after the events: a list of `{id, pid}`. The result is `:ok`,
  `{:error, {:diverged, event}}` when the specification has no step for
  an event, or `{:error, {:violated, invariant, event}}`.
  """
  def replay(events, table, dir) do
    {steps, procs, ids} = name(events, table)
    File.mkdir_p!(dir)
    File.write!(Path.join(dir, "Run.tla"), module(procs, ids))
    File.write!(Path.join(dir, "Run.cfg"), config())
    {:ok, m} = Machine.load(Path.join(dir, "Run.tla"), paths: [@specs])
    {:ok, init} = Machine.init_states(m)

    steps
    |> Enum.reduce_while({:ok, init}, fn {step, event}, {:ok, states} ->
      next = Enum.uniq(Enum.flat_map(states, &apply_step(m, &1, step, procs)))

      violated = fn s ->
        case Machine.check_invariants(m, s) do
          {:violated, invariant} -> invariant
          :ok -> nil
        end
      end

      case Enum.find_value(next, violated) do
        _ when next == [] -> {:halt, {:error, {:diverged, event}}}
        nil -> {:cont, {:ok, next}}
        invariant -> {:halt, {:error, {:violated, invariant, event}}}
      end
    end)
    |> case do
      {:ok, _} -> :ok
      error -> error
    end
  end

  # Give a name of the specification to each join and to each id, and
  # make the steps of the replay. The rows of the table are the last steps.
  defp name(events, table) do
    start = %{steps: [], procs: %{}, ids: %{}, count: 0}

    named =
      Enum.reduce(events, start, fn
        {:join, _pid, _id, {:error, {:bad_option, _}}}, acc ->
          # The flock refused the position: it did not read its table.
          acc

        {:join, pid, id, answer} = event, acc ->
          proc = "p#{acc.count + 1}"
          acc = id(%{acc | procs: Map.put(acc.procs, {pid, id}, proc), count: acc.count + 1}, id)
          step(acc, {:join, proc, acc.ids[id], answer == :ok}, event)

        {kind, pid, id} = event, acc ->
          case acc.procs do
            %{{^pid, ^id} => proc} -> step(acc, {kind, proc}, event)
            # A leave for a process that has no boid changes nothing.
            _ when kind == :leave -> acc
            _ -> step(acc, :none, event)
          end
      end)

    rows =
      for {id, pid} <- table do
        case named.procs do
          %{{^pid, ^id} => proc} -> {{:has, named.ids[id], proc}, {:row, id, pid}}
          # A row that no join made.
          _ -> {:none, {:row, id, pid}}
        end
      end

    free = for {id, name} <- named.ids, not List.keymember?(table, id, 0), do: {{:free, name}, {:no_row, id}}
    {Enum.reverse(named.steps) ++ rows ++ free, Map.values(named.procs), Map.values(named.ids)}
  end

  defp id(acc, id), do: %{acc | ids: Map.put_new(acc.ids, id, "i#{map_size(acc.ids) + 1}")}
  defp step(acc, step, event), do: %{acc | steps: [{step, event} | acc.steps]}

  # The states of the specification after one event, from one state.
  defp apply_step(m, s, {:join, p, i, ok?}, procs) do
    for s1 <- run(m, s, "Start", [p, i]),
        # The process that has the row stopped before the join, or not.
        s2 <- [
          s1 | for(o <- procs, o != p, run(m, s1, "Has", [i, o]) != [], s <- run(m, s1, "Stop", [o]), do: s)
        ],
        s3 <- run(m, s2, "Join", [p]),
        s4 <- run(m, s3, if(ok?, do: "Got", else: "NotGot"), [p]),
        # A caller of boids:remove/2 can find the process from now.
        s5 <- if(ok?, do: run(m, s4, "Find", [p]), else: [s4]),
        do: s5
  end

  defp apply_step(m, s, {:down, p}, _procs) do
    # The process stopped before now, if the specification does not know it.
    for s1 <- [s | run(m, s, "Stop", [p])], s2 <- run(m, s1, "Down", [p]), do: s2
  end

  defp apply_step(m, s, {:leave, p}, _procs) do
    # The process itself left, or boids:remove/2 stopped it.
    case for(cause <- ["Quit", "Remove"], s1 <- run(m, s, cause, [p]), s2 <- run(m, s1, "Leave", [p]), do: s2) do
      # A second leave, or a leave for a process that the flock refused, changes nothing.
      [] -> [s]
      next -> next
    end
  end

  defp apply_step(m, s, {:has, i, p}, _procs), do: run(m, s, "Has", [i, p])
  defp apply_step(m, s, {:free, i}, _procs), do: run(m, s, "Free", [i])
  defp apply_step(_m, _s, :none, _procs), do: []

  defp run(m, s, action, args) do
    {:ok, steps} = Machine.step(m, s, action, args)
    for {next, _} <- steps, do: next
  end

  defp module(procs, ids) do
    """
    ---- MODULE Run ----
    EXTENDS Flock, TLC
    RunProcs == #{set(procs)}
    RunIds == #{set(ids)}
    \\* What the replay sees of the flock: the answer to a join, and a row of the table.
    Got(p) == row[idOf[p]] = p /\\ UNCHANGED vars
    NotGot(p) == row[idOf[p]] /= p /\\ UNCHANGED vars
    Has(i, p) == row[i] = p /\\ UNCHANGED vars
    Free(i) == row[i] = None /\\ UNCHANGED vars
    ====
    """
  end

  defp config do
    """
    SPECIFICATION Spec
    CONSTANTS
        Procs <- RunProcs
        Ids <- RunIds
        None = "none"
        TakeOver = TRUE
        CheckOwner = TRUE
    INVARIANT LiveHasRow Watched NoLostRow Fair
    """
  end

  defp set(names), do: "{" <> Enum.map_join(Enum.sort(names), ", ", &~s("#{&1}")) <> "}"
end
