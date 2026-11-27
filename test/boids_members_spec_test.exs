defmodule BoidsMembersSpecTest do
  # The replay of a real environment as a behavior of specs/Members.tla.
  use ExUnit.Case, async: true
  use ExUnitProperties
  import Boids.Helpers

  alias Boids.MembersSpec

  @moduletag :tmp_dir
  @moduletag :capture_log

  # A process of the test that is a boid: it joins, and leaves on request.
  defp member(environment, id) do
    spawn(fn ->
      case :boids.join(environment, id: id, pos: {0, 0}) do
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

  # Do the acts on a real environment, and give its events and its last table.
  # With `wait`, each act is done before the next act starts. Without it,
  # the processes of the test and of the environment run at the same time.
  defp run(acts, wait \\ false) do
    {:ok, environment} = :boids.start_environment()
    recorder = MembersSpec.trace(environment)

    members =
      Enum.reduce(acts, [], fn act, members ->
        members = act(environment, act, members)
        if wait, do: settle(environment, members)
        members
      end)

    table = settle(environment, members)
    events = MembersSpec.events(environment, recorder)
    check_relations(environment, table)
    :boids.stop_environment(environment)
    {events, table}
  end

  # The relations are not in the specification. After the acts, only the
  # boids of the table have relations, and the table of the relations
  # has the edges of the graph, in the two directions.
  defp check_relations(environment, table) do
    links = :boids.relations(environment)
    edges = :graph.edges(links)
    ids = for {id, _pid} <- table, do: id
    assert :graph.vertices(links) -- ids == []

    rows =
      for {from, to, label} <- edges,
          row <- [{{:out, from, label}, [to]}, {{:in, to, label}, [from]}],
          do: row

    assert Enum.sort(:ets.tab2list(:boids.space(environment).links)) == Enum.sort(rows)
  end

  defp act(environment, {:add, id}, members) do
    # After many kills in one second, the supervisor of the boids stops,
    # and its supervisor starts it again. A call to it exits then.
    try do
      :boids.add(environment, id: id, pos: {0, 0}, tick: :manual)
    catch
      :exit, _ -> :ok
    end

    members
  end

  defp act(environment, {:remove, id}, members) do
    :boids.remove(environment, id)
    members
  end

  defp act(environment, {:kill, id}, members) do
    with pid when is_pid(pid) <- :boids.whereis(environment, id), do: Process.exit(pid, :kill)
    members
  end

  defp act(environment, {:join, id}, members), do: [{id, member(environment, id)} | members]

  # A relation from a boid to the other boid of the test, or to itself.
  defp act(environment, {:relate, id}, members) do
    :boids.relate(environment, id, :follows, other(id))
    members
  end

  defp act(environment, {:unrelate, id}, members) do
    :boids.unrelate(environment, id, :follows, other(id))
    members
  end

  defp act(_space, {:leave, id}, members) do
    for {^id, pid} <- members, do: send(pid, :leave)
    members
  end

  defp other(:a), do: :b
  defp other(:b), do: :a
  defp other(id), do: id

  # Wait until each process of the test did its calls, and the table
  # does not change. The result is the table.
  defp settle(environment, members, last \\ nil, same \\ 0) do
    for {_id, pid} <- members, Process.alive?(pid) do
      ref = Process.monitor(pid)
      send(pid, {:ready?, self()})

      receive do
        {:ready, ^pid} -> Process.demonitor(ref, [:flush])
        {:DOWN, ^ref, _, _, _} -> :ok
      end
    end

    :sys.get_state(environment)
    table = Enum.sort(for %{id: id, pid: pid} <- :boids.snapshot(environment), do: {id, pid})

    cond do
      table == last and same >= 3 ->
        table

      table == last ->
        Process.sleep(5)
        settle(environment, members, table, same + 1)

      true ->
        Process.sleep(5)
        settle(environment, members, table, 0)
    end
  end

  test "an environment with boids that start, stop, start again, leave and go", %{tmp_dir: dir} do
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
    assert MembersSpec.replay(events, table, dir) == :ok
  end

  test "a new boid with the id of a boid that stopped takes its row before or after its 'DOWN'", %{
    tmp_dir: dir
  } do
    # Each add comes at once after a kill: its join and the 'DOWN' come in the two orders.
    acts = Enum.flat_map(1..20, fn _ -> [add: :a, kill: :a, join: :b, kill: :b, add: :a, kill: :a] end)
    {events, table} = run(acts)
    assert Enum.count(events, &match?({:join, _, _, :ok}, &1)) >= 20
    assert MembersSpec.replay(events, table, dir) == :ok
  end

  property "each real environment is a behavior of the specification", %{tmp_dir: dir} do
    kinds = [:add, :add, :remove, :kill, :join, :leave, :relate, :relate, :unrelate]
    act = tuple({member_of(kinds), member_of([:a, :b])})

    check all(acts <- list_of(act, max_length: 25), max_runs: 40) do
      {events, table} = run(acts)
      assert MembersSpec.replay(events, table, dir) == :ok
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
    assert MembersSpec.replay(events, table, dir) == :ok
  end

  describe "an environment that is not a behavior of the specification" do
    setup do
      first = spawn(fn -> :ok end)
      second = spawn(fn -> Process.sleep(:infinity) end)
      %{first: first, second: second}
    end

    test "a leave that takes the row of a new process diverges", %{tmp_dir: dir, first: first, second: second} do
      # The environment before the check of the process of a leave: specs/MCMembersLeave.cfg.
      events = [{:join, first, :a, :ok}, {:down, first, :a}, {:join, second, :a, :ok}, {:leave, first, :a}]
      assert MembersSpec.replay(events, [{:a, second}], dir) == :ok
      assert MembersSpec.replay(events, [], dir) == {:error, {:diverged, {:no_row, :a}}}
    end

    test "an environment that refuses an id whose process stopped diverges", %{
      tmp_dir: dir,
      first: first,
      second: second
    } do
      # The environment with no check of the process of a row: specs/MCMembersKeep.cfg.
      taken = [{:join, first, :a, :ok}, {:join, second, :a, :ok}]
      assert MembersSpec.replay(taken, [{:a, second}], dir) == :ok
      # After that, the environment does not watch the first process.
      watched = taken ++ [{:down, first, :a}]
      assert MembersSpec.replay(watched, [{:a, second}], dir) == {:error, {:diverged, {:down, first, :a}}}
      refused = [{:join, first, :a, :ok}, {:join, second, :a, {:error, {:exists, :a}}}, {:down, first, :a}]
      assert MembersSpec.replay(refused, [], dir) == :ok
      late = [{:join, first, :a, :ok}, {:down, first, :a}, {:join, second, :a, {:error, {:exists, :a}}}]
      assert MembersSpec.replay(late, [], dir) == {:error, {:diverged, List.last(late)}}
    end

    test "a wrong answer, a lost row and a row from nothing diverge", %{
      tmp_dir: dir,
      first: first,
      second: second
    } do
      two = [{:join, first, :a, :ok}, {:join, second, :a, :ok}]
      assert MembersSpec.replay(two, [{:a, second}], dir) == :ok
      assert MembersSpec.replay(two, [{:a, first}], dir) == {:error, {:diverged, {:row, :a, first}}}
      assert MembersSpec.replay([{:join, first, :a, :ok}], [], dir) == {:error, {:diverged, {:no_row, :a}}}
      assert MembersSpec.replay([], [{:a, first}], dir) == {:error, {:diverged, {:row, :a, first}}}
      assert MembersSpec.replay([{:down, first, :a}], [], dir) == {:error, {:diverged, {:down, first, :a}}}
      first_refused = [{:join, first, :a, {:error, {:exists, :a}}}]
      assert MembersSpec.replay(first_refused, [], dir) == {:error, {:diverged, hd(first_refused)}}
    end

    test "events that change nothing are permitted", %{tmp_dir: dir, first: first} do
      events = [
        {:join, first, :a, {:error, {:bad_option, {:pos, {0, 0, 0}}}}},
        {:leave, first, :a},
        {:join, first, :a, :ok},
        {:leave, first, :a},
        {:leave, first, :a}
      ]

      assert MembersSpec.replay(events, [], dir) == :ok
      assert MembersSpec.replay([], [], dir) == :ok
    end
  end

  test "the record has each message of the environment, with the answers", %{tmp_dir: dir} do
    {:ok, environment} = :boids.start_environment()
    recorder = MembersSpec.trace(environment)
    {:ok, :a} = :boids.add(environment, id: :a, pos: {0, 0}, tick: :manual)
    pid = :boids.whereis(environment, :a)
    {:error, _} = :boids.add(environment, id: :a, pos: {1, 1}, tick: :manual)
    {:error, _} = :boids.add(environment, id: :b, pos: {1, 1, 1}, tick: :manual)
    # The record does not have the messages of the relations.
    :ok = :boids.relate(environment, :a, :follows, :a)
    [{:a, :a, :follows}] = :graph.edges(:boids.relations(environment))
    :ok = :boids.unrelate(environment, :a, :follows, :a)
    :ok = :boids.remove(environment, :a)
    send(environment, {:DOWN, make_ref(), :process, self(), :normal})
    assert eventually(fn -> :boids.count(environment) == 0 end)
    events = MembersSpec.events(environment, recorder)
    :boids.stop_environment(environment)

    assert [
             {:join, ^pid, :a, :ok},
             {:join, _, :a, {:error, {:exists, :a}}},
             {:join, _, :b, {:error, {:bad_option, {:pos, {1, 1, 1}}}}}
             | rest
           ] = events

    assert {:leave, pid, :a} in rest
    assert {:down, self(), :unknown} in rest
    # A 'DOWN' that the environment does not know is not in the specification.
    assert MembersSpec.replay(events, [], dir) == {:error, {:diverged, {:down, self(), :unknown}}}
    assert MembersSpec.replay(events -- [{:down, self(), :unknown}], [], dir) == :ok
  end
end
