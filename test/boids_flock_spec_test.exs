defmodule BoidsFlockSpecTest do
  # The replay of a real flock as a behavior of specs/Flock.tla.
  use ExUnit.Case, async: true
  use ExUnitProperties
  import Boids.Helpers

  alias Boids.FlockSpec

  @moduletag :tmp_dir
  @moduletag :capture_log

  # A process of the test that is a boid: it joins, and leaves on request.
  defp member(flock, id) do
    spawn(fn ->
      case :boids.join(flock, id: id, pos: {0, 0}) do
        {:ok, space, boid} -> member_loop(space, boid)
        {:error, _} -> member_loop(nil, nil)
      end
    end)
  end

  defp member_loop(space, boid) do
    receive do
      :leave when space != nil -> :boids.leave(space, boid)
      {:ready?, from} -> send(from, {:ready, self()})
      _ -> :ok
    end

    member_loop(space, boid)
  end

  # Do the acts on a real flock, and give its events and its last table.
  # With `wait`, each act is done before the next act starts. Without it,
  # the processes of the test and of the flock run at the same time.
  defp run(acts, wait \\ false) do
    {:ok, flock} = :boids.start_flock()
    recorder = FlockSpec.trace(flock)

    members =
      Enum.reduce(acts, [], fn act, members ->
        members = act(flock, act, members)
        if wait, do: settle(flock, members)
        members
      end)

    table = settle(flock, members)
    events = FlockSpec.events(flock, recorder)
    check_relations(flock, table)
    :boids.stop_flock(flock)
    {events, table}
  end

  # The relations are not in the specification. After the acts, only the
  # boids of the table have relations, and the table of the relations
  # has the edges of the graph, in the two directions.
  defp check_relations(flock, table) do
    links = :boids.relations(flock)
    edges = :graph.edges(links)
    ids = for {id, _pid} <- table, do: id
    assert :graph.vertices(links) -- ids == []

    rows =
      for {from, to, label} <- edges,
          row <- [{{:out, from, label}, [to]}, {{:in, to, label}, [from]}],
          do: row

    assert Enum.sort(:ets.tab2list(:boids.space(flock).links)) == Enum.sort(rows)
  end

  defp act(flock, {:add, id}, members) do
    # After many kills in one second, the supervisor of the boids stops,
    # and its supervisor starts it again. A call to it exits then.
    try do
      :boids.add(flock, id: id, pos: {0, 0}, tick: :manual)
    catch
      :exit, _ -> :ok
    end

    members
  end

  defp act(flock, {:remove, id}, members) do
    :boids.remove(flock, id)
    members
  end

  defp act(flock, {:kill, id}, members) do
    with pid when is_pid(pid) <- :boids.whereis(flock, id), do: Process.exit(pid, :kill)
    members
  end

  defp act(flock, {:join, id}, members), do: [{id, member(flock, id)} | members]

  # A relation from a boid to the other boid of the test, or to itself.
  defp act(flock, {:relate, id}, members) do
    :boids.relate(flock, id, :follows, other(id))
    members
  end

  defp act(flock, {:unrelate, id}, members) do
    :boids.unrelate(flock, id, :follows, other(id))
    members
  end

  defp act(_flock, {:leave, id}, members) do
    for {^id, pid} <- members, do: send(pid, :leave)
    members
  end

  defp other(:a), do: :b
  defp other(:b), do: :a
  defp other(id), do: id

  # Wait until each process of the test did its calls, and the table
  # does not change. The result is the table.
  defp settle(flock, members, last \\ nil, same \\ 0) do
    for {_id, pid} <- members, Process.alive?(pid) do
      ref = Process.monitor(pid)
      send(pid, {:ready?, self()})

      receive do
        {:ready, ^pid} -> Process.demonitor(ref, [:flush])
        {:DOWN, ^ref, _, _, _} -> :ok
      end
    end

    :sys.get_state(flock)
    table = Enum.sort(for %{id: id, pid: pid} <- :boids.snapshot(flock), do: {id, pid})

    cond do
      table == last and same >= 3 ->
        table

      table == last ->
        Process.sleep(5)
        settle(flock, members, table, same + 1)

      true ->
        Process.sleep(5)
        settle(flock, members, table, 0)
    end
  end

  test "a flock with boids that start, stop, start again, leave and go", %{tmp_dir: dir} do
    acts = [
      add: :a,
      add: :a,
      add: :b,
      join: :c,
      join: :c,
      kill: :a,
      remove: :b,
      add: :b,
      leave: :c,
      join: :c,
      kill: :c,
      remove: :a,
      add: :a,
      remove: :nobody
    ]

    {events, table} = run(acts, true)
    assert Enum.count(events, &match?({:join, _, _, :ok}, &1)) >= 6
    assert Enum.any?(events, &match?({:join, _, :a, {:error, {:exists, :a}}}, &1))
    assert Enum.any?(events, &match?({:down, _, _}, &1))
    assert Enum.any?(events, &match?({:leave, _, _}, &1))
    assert [{:a, _}, {:b, _}] = table
    assert FlockSpec.replay(events, table, dir) == :ok
  end

  test "a new boid with the id of a boid that stopped takes its row before or after its 'DOWN'", %{
    tmp_dir: dir
  } do
    # Each add comes at once after a kill: its join and the 'DOWN' come in the two orders.
    acts = Enum.flat_map(1..20, fn _ -> [add: :a, kill: :a, join: :b, kill: :b, add: :a, kill: :a] end)
    {events, table} = run(acts)
    assert Enum.count(events, &match?({:join, _, _, :ok}, &1)) >= 20
    assert FlockSpec.replay(events, table, dir) == :ok
  end

  property "each real flock is a behavior of the specification", %{tmp_dir: dir} do
    kinds = [:add, :add, :remove, :kill, :join, :leave, :relate, :relate, :unrelate]
    act = tuple({member_of(kinds), member_of([:a, :b])})

    check all(acts <- list_of(act, max_length: 25), max_runs: 40) do
      {events, table} = run(acts)
      assert FlockSpec.replay(events, table, dir) == :ok
    end
  end

  test "the relations between the boids are not events of the specification", %{tmp_dir: dir} do
    acts = [
      add: :a,
      relate: :a,
      add: :b,
      relate: :a,
      relate: :b,
      join: :c,
      relate: :c,
      kill: :a,
      relate: :b,
      add: :a,
      relate: :a,
      unrelate: :a,
      relate: :b,
      remove: :b,
      leave: :c,
      add: :b,
      relate: :b
    ]

    {events, table} = run(acts, true)
    assert Enum.all?(events, &(elem(&1, 0) in [:join, :leave, :down]))
    assert [{:a, _}, {:b, _}] = table
    assert FlockSpec.replay(events, table, dir) == :ok
  end

  describe "a flock that is not a behavior of the specification" do
    setup do
      first = spawn(fn -> :ok end)
      second = spawn(fn -> Process.sleep(:infinity) end)
      %{first: first, second: second}
    end

    test "a leave that takes the row of a new process diverges", %{tmp_dir: dir, first: first, second: second} do
      # The flock before the check of the process of a leave: specs/MCFlockLeave.cfg.
      events = [{:join, first, :a, :ok}, {:down, first, :a}, {:join, second, :a, :ok}, {:leave, first, :a}]
      assert FlockSpec.replay(events, [{:a, second}], dir) == :ok
      assert FlockSpec.replay(events, [], dir) == {:error, {:diverged, {:no_row, :a}}}
    end

    test "a flock that refuses an id whose process stopped diverges", %{
      tmp_dir: dir,
      first: first,
      second: second
    } do
      # The flock with no check of the process of a row: specs/MCFlockKeep.cfg.
      taken = [{:join, first, :a, :ok}, {:join, second, :a, :ok}]
      assert FlockSpec.replay(taken, [{:a, second}], dir) == :ok
      # After that, the flock does not watch the first process.
      watched = taken ++ [{:down, first, :a}]
      assert FlockSpec.replay(watched, [{:a, second}], dir) == {:error, {:diverged, {:down, first, :a}}}
      refused = [{:join, first, :a, :ok}, {:join, second, :a, {:error, {:exists, :a}}}, {:down, first, :a}]
      assert FlockSpec.replay(refused, [], dir) == :ok
      late = [{:join, first, :a, :ok}, {:down, first, :a}, {:join, second, :a, {:error, {:exists, :a}}}]
      assert FlockSpec.replay(late, [], dir) == {:error, {:diverged, List.last(late)}}
    end

    test "a wrong answer, a lost row and a row from nothing diverge", %{
      tmp_dir: dir,
      first: first,
      second: second
    } do
      two = [{:join, first, :a, :ok}, {:join, second, :a, :ok}]
      assert FlockSpec.replay(two, [{:a, second}], dir) == :ok
      assert FlockSpec.replay(two, [{:a, first}], dir) == {:error, {:diverged, {:row, :a, first}}}
      assert FlockSpec.replay([{:join, first, :a, :ok}], [], dir) == {:error, {:diverged, {:no_row, :a}}}
      assert FlockSpec.replay([], [{:a, first}], dir) == {:error, {:diverged, {:row, :a, first}}}
      assert FlockSpec.replay([{:down, first, :a}], [], dir) == {:error, {:diverged, {:down, first, :a}}}
      first_refused = [{:join, first, :a, {:error, {:exists, :a}}}]
      assert FlockSpec.replay(first_refused, [], dir) == {:error, {:diverged, hd(first_refused)}}
    end

    test "events that change nothing are permitted", %{tmp_dir: dir, first: first} do
      events = [
        {:join, first, :a, {:error, {:bad_option, {:pos, {0, 0, 0}}}}},
        {:leave, first, :a},
        {:join, first, :a, :ok},
        {:leave, first, :a},
        {:leave, first, :a}
      ]

      assert FlockSpec.replay(events, [], dir) == :ok
      assert FlockSpec.replay([], [], dir) == :ok
    end
  end

  test "the record has each message of the flock, with the answers", %{tmp_dir: dir} do
    {:ok, flock} = :boids.start_flock()
    recorder = FlockSpec.trace(flock)
    {:ok, :a} = :boids.add(flock, id: :a, pos: {0, 0}, tick: :manual)
    pid = :boids.whereis(flock, :a)
    {:error, _} = :boids.add(flock, id: :a, pos: {1, 1}, tick: :manual)
    {:error, _} = :boids.add(flock, id: :b, pos: {1, 1, 1}, tick: :manual)
    # The record does not have the messages of the relations.
    :ok = :boids.relate(flock, :a, :follows, :a)
    [{:a, :a, :follows}] = :graph.edges(:boids.relations(flock))
    :ok = :boids.unrelate(flock, :a, :follows, :a)
    :ok = :boids.remove(flock, :a)
    send(flock, {:DOWN, make_ref(), :process, self(), :normal})
    assert eventually(fn -> :boids.count(flock) == 0 end)
    events = FlockSpec.events(flock, recorder)
    :boids.stop_flock(flock)

    assert [
             {:join, ^pid, :a, :ok},
             {:join, _, :a, {:error, {:exists, :a}}},
             {:join, _, :b, {:error, {:bad_option, {:pos, {1, 1, 1}}}}}
             | rest
           ] = events

    assert {:leave, pid, :a} in rest
    assert {:down, self(), :unknown} in rest
    # A 'DOWN' that the flock does not know is not in the specification.
    assert FlockSpec.replay(events, [], dir) == {:error, {:diverged, {:down, self(), :unknown}}}
    assert FlockSpec.replay(events -- [{:down, self(), :unknown}], [], dir) == :ok
  end
end
