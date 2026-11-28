defmodule BoidsSaveTest do
  # The save of a world, and the load of a save: export/1 and import/2.
  use ExUnit.Case, async: true
  import Boids.Helpers

  alias Boids.TestBoids.{Hawk, Keeper, Loose, Mouse, Person}

  @moduletag :capture_log
  @box {{0, 0}, {60, 60}}

  # A world that stops at the end of the test.
  defp world(opts \\ %{}) do
    {:ok, world} = :boids.start_world(opts)
    on_exit(fn -> :boids.stop_world(world) end)
    world
  end

  # A boid with no rule and no clock: it moves only with step/2.
  defp still(more), do: Map.merge(%{pos: {0, 0}, rules: [], tick: :manual}, Map.new(more))

  defp ids(world), do: Enum.map(:boids.snapshot(world), & &1.id)

  # The rows of a world with no process: two worlds have other processes.
  defp rows(world), do: Enum.map(:boids.snapshot(world), &Map.delete(&1, :pid))

  defp steps(world, count, dt \\ 0.05), do: for(_ <- 1..count, do: :ok = :boids.step(world, dt))

  # The state of a hawk, with the positions of the boids that it saw:
  # their ids are references, which are not the same in two runs.
  defp hawk(world) do
    state = :gen_boid.call(:boids.whereis(world, :hawk), :state)
    %{state | seen: Enum.map(state.seen, &elem(&1, 1))}
  end

  # A save as a program keeps it: through a binary.
  defp through_binary(save), do: :erlang.binary_to_term(:erlang.term_to_binary(save))

  # Stop a world, start a world with the same options, and load the save.
  defp load_again(world, options, save) do
    :ok = :boids.stop_world(world)
    new = world(options)
    {new, :boids.import(new, through_binary(save))}
  end

  # The saved boid of an id.
  defp saved(save, id), do: Enum.find(save.boids, &(&1.boid.id == id))

  # Change the saved boid of an id.
  defp change(save, id, fun) do
    %{save | boids: Enum.map(save.boids, &if(&1.boid.id == id, do: fun.(&1), else: &1))}
  end

  @doc "A rule that is a function with a name."
  def push(_boid, _neighbors, _seen), do: {1.0, 0.0}

  describe "export/1" do
    test "gives the boids with all their state, the facts and the number of the format" do
      world = world(bounds: @box)
      {:ok, :a} = :boids.add(world, still(id: :a, pos: {1, 2}, vel: {3, 4}, group: :birds, data: :x, seed: 5))
      {:ok, hawk} = :gen_boid.start(world, Hawk, %{boid: %{id: :hawk, pos: {5, 5}}})
      :ok = :boids.relate(world, :hawk, :hunts, :a)
      :ok = :boids.set_obstacle(world, :rock, {30, 30}, 2)
      steps(world, 3)

      save = :boids.export(world)
      assert Map.keys(save) |> Enum.sort() == [:boids, :can_fail, :facts, :format, :not_saved]
      assert save.format == 1
      assert save.not_saved == []
      assert save.can_fail == []
      assert save.facts == :boids_world.facts(world)
      assert [{{:obstacle, :rock}, {{30, 30}, 2}, {_counter, _node}}] = save.facts

      assert [a, h] = save.boids
      {:ok, boid} = :boids.boid(world, :a)
      assert a.boid == boid
      assert a.mod == :undefined
      assert a.vsn == :undefined
      assert a.relations == []
      # The options of the process, with no seed: the save has the state of the random numbers.
      assert a.server == %{tick: :manual, max_dt: 0.25, search: 1, priority: :low, hibernate: true}
      assert a.rand != :undefined
      assert {a.known, a.steps} == {[], 0}

      assert h.mod == Hawk
      assert h.vsn == hd(Hawk.module_info(:attributes)[:vsn])
      assert h.relations == [hunts: [:a]]
      assert h.boid.state == :gen_boid.call(hawk, :state)
      assert h.boid.state.steps == 3
    end

    test "has the boids in the order of snapshot/1" do
      world = world(bounds: @box)
      {:ok, refs} = :boids.populate(world, 30, still(%{}))
      {:ok, :last} = :boids.add(world, still(id: :last))
      :ok = :boids.remove(world, Enum.at(refs, 4))
      save = :boids.export(world)
      assert Enum.map(save.boids, & &1.boid.id) == ids(world)
      assert ids(world) == List.delete_at(refs, 4) ++ [:last]
    end

    test "is a term that goes through a binary and back" do
      world = world(bounds: @box)
      grid = :boids_grid.new(size: {6, 6}, cell_size: 10, blocked: [{2, 2}])
      :ok = :boids.set_grid(world, :land, grid)
      :ok = :boids.set_field(world, :exit, :boids_field.new(grid, [{5, 5}]))
      :ok = :boids.set_obstacle(world, :rock, {30, 30}, 2)
      :ok = :boids.set_time_scale(world, 0.5)
      rules = [{:wander, 0.5}, {&__MODULE__.push/3, 1.0}, {:flow, 1.0, field: {:named, :exit}}]
      {:ok, _} = :boids.populate(world, 10, still(rules: rules, seed: 3))
      {:ok, _} = :gen_boid.start(world, Hawk, %{owner: self(), boid: %{id: :hawk, pos: {5, 5}}})
      steps(world, 5)
      save = :boids.export(world)
      binary = :erlang.term_to_binary(save)
      assert :erlang.binary_to_term(binary) == save
      assert :erlang.binary_to_term(binary, [:safe]) == save
    end

    test "does not have a process of yours, and a boid below a supervisor of yours" do
      world = world()
      {:ok, :mine} = :boids.add(world, still(id: :mine))
      {:ok, person} = GenServer.start_link(Person, {world, %{id: :person, pos: {1, 1}}})
      {:ok, child} = :gen_boid.start_link(world, Mouse, still(id: :child))
      # A boid of the world with a relation to each of them.
      :ok = :boids.relate(world, :mine, :knows, :person)
      :ok = :boids.relate(world, :mine, :knows, :child)
      :ok = :boids.relate(world, :child, :knows, :mine)

      save = :boids.export(world)
      assert Enum.map(save.boids, & &1.boid.id) == [:mine]
      assert save.not_saved == [person: :process, child: :supervised]
      assert saved(save, :mine).relations == [knows: [:child, :person]]
      # The boids continue.
      assert Process.alive?(person) and Process.alive?(child)
      assert ids(world) == [:mine, :person, :child]
      GenServer.stop(person)
      :gen_boid.stop(child)
    end

    test "does not have a boid that stops before its answer: the reason is that of its end" do
      world = world()
      {:ok, :a} = :boids.add(world, still(id: :a))
      {:ok, :b} = :boids.add(world, still(id: :b))
      pid = :boids.whereis(world, :b)
      # The boid :b does not read its messages.
      :ok = :sys.suspend(pid)
      task = Task.async(fn -> :boids.export(world) end)
      # The request of the export is in its messages: now it stops.
      assert eventually(fn -> Process.info(pid, :message_queue_len) == {:message_queue_len, 1} end)
      Process.exit(pid, :kill)
      save = Task.await(task)
      assert Enum.map(save.boids, & &1.boid.id) == [:a]
      assert save.not_saved == [b: :killed]
    end

    test "tells that a boid with an anonymous function can fail after a load" do
      world = world()
      here = self()
      rule = fn _boid, _neighbors, _seen -> {1.0, 0.0} end
      field = fn _pos -> {0.0, 1.0} end
      # A function that keeps a pid from the code that made it.
      keeps = fn -> here end
      {:ok, :rule} = :boids.add(world, still(id: :rule, rules: [{rule, 1.0}]))
      {:ok, :field} = :boids.add(world, still(id: :field, rules: [{:flow, 1.0, field: field}]))
      {:ok, :data} = :boids.add(world, still(id: :data, data: %{[1 | keeps] => 2}))
      # A function with a name is not an anonymous function.
      {:ok, :named} = :boids.add(world, still(id: :named, rules: [{&__MODULE__.push/3, 1.0}]))
      save = :boids.export(world)

      assert save.can_fail == [
               rule: {:function, rule},
               field: {:function, field},
               data: {:function, keeps},
               data: {:live, here}
             ]

      assert Enum.map(save.boids, & &1.boid.id) == [:rule, :field, :data, :named]
    end

    test "tells that a boid with a pid, a port or a reference can fail after a load" do
      world = world()
      port = hd(:erlang.ports())
      ref = make_ref()
      {:ok, id} = :boids.add(world, still(%{}))
      assert is_reference(id)
      # The id of a boid of the world is not a thing that stops: a reference, or a pid.
      {:ok, person} = GenServer.start_link(Person, {world, %{pos: {1, 1}}})
      target = [{:seek, 1.0, target: {:boid, id}}]
      {:ok, :ids} = :boids.add(world, still(id: :ids, rules: target, data: {id, person}))
      {:ok, :live} = :boids.add(world, still(id: :live, data: {port, [ref, %{pid: self()}, ref]}))
      {:ok, _} = :gen_boid.start(world, Hawk, %{owner: self(), boid: %{id: :hawk}})
      {:ok, _} = :gen_boid.start(world, Loose, id: :loose)
      # The module of this boid has handle_load/2: it makes its table again.
      {:ok, _} = :gen_boid.start(world, Keeper, id: :keeper)

      save = :boids.export(world)
      %{table: table} = saved(save, :loose).boid.state
      assert is_reference(table)

      assert Enum.sort(save.can_fail) ==
               Enum.sort(
                 live: {:live, port},
                 live: {:live, ref},
                 live: {:live, self()},
                 hawk: {:live, self()},
                 loose: {:live, table}
               )

      assert save.not_saved == [{person, :process}]
      assert length(save.boids) == 6
      GenServer.stop(person)
    end

    test "export(World, local) of a world on one node is export/1" do
      world = world()
      {:ok, :a} = :boids.add(world, still(id: :a, data: make_ref()))
      assert %{can_fail: [a: {:live, _}]} = save = :boids.export(world, :local)
      assert save == :boids.export(world)
    end

    test "has the version of the module of each boid, as code_change/3 gets it" do
      world = world()
      # A module with two attributes vsn has a list of versions.
      forms = [
        {:attribute, 1, :module, :boids_save_two_versions},
        {:attribute, 2, :vsn, :first},
        {:attribute, 3, :vsn, :second},
        {:attribute, 4, :export, [init: 1]},
        {:function, 5, :init, 1,
         [{:clause, 5, [{:var, 5, :Options}], [], [{:tuple, 5, [{:atom, 5, :ok}, {:var, 5, :Options}]}]}]}
      ]

      {:ok, module, binary} = :compile.forms(forms)
      {:module, ^module} = :code.load_binary(module, ~c"nofile", binary)
      {:ok, _} = :gen_boid.start(world, module, still(id: :two))
      {:ok, _} = :gen_boid.start(world, Keeper, id: :keeper)
      {:ok, _} = :gen_boid.start(world, Mouse, still(id: :mouse))
      save = :boids.export(world)
      assert saved(save, :two).vsn == [:first, :second]
      assert saved(save, :keeper).vsn == 2
      # With no attribute, the compiler gives a number.
      assert is_integer(saved(save, :mouse).vsn)
    end
  end

  describe "import/2" do
    # A world with boids of each kind, for a run with the same result each time.
    defp flock(search) do
      :rand.seed(:exsss, 7)
      world = world(bounds: @box, wrap: true)

      rules = [
        {:separation, 1.5, oncoming: false},
        {:alignment, 1.0},
        {:cohesion, 1.0},
        {:wander, 0.5},
        {:dodge, 1.0}
      ]

      {:ok, refs} = :boids.populate(world, 40, rules: rules, tick: :manual, seed: 1, search: search)
      [first, second | _] = refs
      # A boid that follows another boid, and a boid with callbacks that hunts.
      follower = still(id: :follower, pos: {30, 30}, rules: [{:leader, 1.0, target: {:related, :follows}}])
      {:ok, :follower} = :boids.add(world, Map.merge(follower, %{seed: 77, search: search}))
      :ok = :boids.relate(world, :follower, :follows, first)
      :ok = :boids.relate(world, :follower, :likes, second)
      :ok = :boids.relate(world, second, :likes, :follower)

      {:ok, _} =
        :gen_boid.start(world, Hawk, %{boid: %{id: :hawk, pos: {20, 20}, search: search, max_speed: 6}})

      {:ok, _} = :boids.add(world, still(id: :mouse, group: :mice, pos: {24, 24}))
      {world, refs}
    end

    for search <- [1, 3] do
      test "100 steps, a save, a new world, a load and 100 steps give the same as 200 steps (search #{search})" do
        search = unquote(search)
        {world, _} = flock(search)
        steps(world, 200)
        straight = Enum.map(rows(world), &Map.delete(&1, :id))
        hawk = hawk(world)
        :ok = :boids.stop_world(world)

        {world, refs} = flock(search)
        steps(world, 100)
        save = :boids.export(world)
        assert save.can_fail == [] and save.not_saved == []
        {new, {:ok, result}} = load_again(world, [bounds: @box, wrap: true], save)
        expected = refs ++ [:follower, :hawk, :mouse]
        assert result == %{started: expected, not_started: [], not_related: [], facts: :ok}
        assert ids(new) == expected
        assert :boids.related(new, :follower, :follows) == [hd(refs)]
        assert :boids.related_to(new, :follower, :likes) == [Enum.at(refs, 1)]
        # The rules are data: each rule has its options after the load, with no code.
        {:ok, boid} = :boids.boid(new, hd(refs))
        assert boid == saved(save, hd(refs)).boid
        assert {:separation, 1.5, %{oncoming: false}} = List.keyfind(boid.rules, :separation, 0)
        steps(new, 100)
        # The references of the first run are other references: the order is the same.
        assert Enum.map(rows(new), &Map.delete(&1, :id)) == straight
        assert hawk(new) == hawk
        assert hawk.steps == 200
      end
    end

    test "a boid starts with its module, its id and all its state, and init/1 does not run" do
      world = world()
      {:ok, hawk} = :gen_boid.start(world, Hawk, %{boid: %{id: :hawk, pos: {5, 5}, vel: {1, 0}, tick: 20}})
      {:ok, :a} = :boids.add(world, still(id: :a, tick: 10, max_dt: 0.5, priority: :normal, hibernate: false))
      :ok = :boids.set_time_scale(world, 0)
      assert eventually(fn -> :gen_boid.call(hawk, :steps) > 2 end)
      save = :boids.export(world)
      state = saved(save, :hawk).boid.state

      {new, {:ok, %{started: [:hawk, :a]}}} = load_again(world, %{}, save)
      loaded = :boids.whereis(new, :hawk)
      assert loaded != hawk
      # init/1 of the module makes a state with no step: the boid has the state of the save.
      assert :gen_boid.call(loaded, :state).steps >= state.steps
      assert state.steps > 2
      assert %{mod: Hawk, tick: 20, roams: true, moves: 0} = :sys.get_state(loaded)
      # Its clock runs: the boid makes steps.
      assert eventually(fn -> :gen_boid.call(loaded, :steps) > state.steps + 2 end)
      # The options of the process of the other boid.
      assert %{mod: :undefined, tick: 10, max_dt: 0.5, priority: :normal, hibernate: false} =
               :sys.get_state(:boids.whereis(new, :a))

      # The supervisor of the world has the boids: remove/2 stops one.
      assert :boids.remove(new, :hawk) == :ok
      assert ids(new) == [:a]
    end

    test "a world with a grid, a field, obstacles and a scale of the time comes back with them" do
      # A wall with a door of two cells. The boids start at its left, and the goal is at its right.
      grid = :boids_grid.new(size: {40, 30}, blocked: for(j <- 0..29, j not in [14, 15], do: {20, j}))
      field = :boids_field.new(grid, [{35, 5}])
      options = [bounds: {{0, 0}, {40, 30}}, defaults: %{walkable: {:named, :land}}]

      start = fn ->
        :rand.seed(:exsss, 11)
        world = world(options)
        :ok = :boids.set_grid(world, :land, grid)
        :ok = :boids.set_field(world, :exit, field)
        :ok = :boids.set_obstacle(world, :rock, {30, 12}, 1.5)
        :ok = :boids.set_obstacle(world, :gone, {5, 5}, 1)
        :ok = :boids.remove_obstacle(world, :gone)
        :ok = :boids.set_time_scale(world, 0.5)
        rules = [{:flow, 1.0, field: {:named, :exit}}, {:separation, 1.5, radius: 0.7}, {:avoid, 2.0}]
        more = %{area: {{2, 2}, {15, 28}}, rules: rules, perception: 2.0, max_speed: 4.0, max_force: 40.0}
        {:ok, ids} = :boids.populate(world, 20, still(Map.merge(more, %{seed: 1})))
        {world, ids}
      end

      {world, _} = start.()
      steps(world, 600, 0.1)
      straight = Enum.map(rows(world), &Map.delete(&1, :id))
      :ok = :boids.stop_world(world)

      {world, ids} = start.()
      steps(world, 20, 0.1)
      # The boids are on their way: not one is through the door.
      assert Enum.all?(rows(world), fn %{pos: {x, _}} -> x < 20 end)
      save = :boids.export(world)
      facts = :boids_world.facts(world)
      {new, {:ok, %{started: ^ids, facts: :ok}}} = load_again(world, options, save)

      # The facts are the facts of the first world, with their versions.
      assert :boids_world.facts(new) == facts
      assert :boids.grid(new, :land) == {:ok, grid}
      assert :boids.field(new, :exit) == {:ok, field}
      assert [%{id: :rock, pos: {30, 12}, radius: 1.5}] = :boids.obstacles(new)
      assert %{time_scale: 0.5} = :boids_space.env(:boids.space(new))

      # Each boid goes on its way, in the places where it can walk, to the goal.
      for _ <- 1..580 do
        :ok = :boids.step(new, 0.1)
        assert Enum.all?(:boids.snapshot(new), fn %{pos: pos} -> :boids_grid.walkable(grid, pos) end)
      end

      assert Enum.map(rows(new), &Map.delete(&1, :id)) == straight
      for %{pos: pos} <- rows(new), do: assert(:boids_vec.dist(pos, {35.5, 5.5}) < 6.0)
    end

    test "a boid with a table of ETS in its state works after the load with handle_load/2" do
      world = world()
      {:ok, keeper} = :gen_boid.start(world, Keeper, id: :keeper)
      steps(world, 3)
      %{table: table} = :gen_boid.call(keeper, :state)
      save = :boids.export(world)
      assert save.can_fail == []

      {new, {:ok, %{started: [:keeper], not_started: []}}} = load_again(world, %{}, save)
      # The table of the first process stopped with it.
      assert :ets.info(table) == :undefined
      loaded = :boids.whereis(new, :keeper)
      assert %{table: other, steps: 3, loads: 1} = :gen_boid.call(loaded, :state)
      assert other != table
      steps(new, 2)
      assert :gen_boid.call(loaded, :steps) == 5
      assert %{steps: 5} = :gen_boid.call(loaded, :state)
    end

    test "a boid with a table of ETS and no handle_load/2 is in the list, and stops at its first step" do
      world = world()
      {:ok, _} = :gen_boid.start(world, Loose, id: :loose)
      {:ok, :a} = :boids.add(world, still(id: :a))
      steps(world, 3)
      save = :boids.export(world)
      table = saved(save, :loose).boid.state.table
      assert save.can_fail == [loose: {:live, table}]

      {new, {:ok, %{started: [:loose, :a]}}} = load_again(world, %{}, save)
      loaded = :boids.whereis(new, :loose)
      ref = Process.monitor(loaded)
      :ok = :boids.step(new, 0.05)
      # The table is not there: the boid stops with an error, and the other boid continues.
      assert_receive {:DOWN, ^ref, :process, ^loaded, {:badarg, _}}
      assert eventually(fn -> ids(new) == [:a] end)
    end

    test "handle_load/2 gets the version of the module that made the save, and changes an older state" do
      world = world()
      {:ok, _} = :gen_boid.start(world, Keeper, id: :keeper)
      steps(world, 2)
      save = :boids.export(world)
      assert saved(save, :keeper).vsn == 2

      # A save of the version 1 of the module: its state had no key loads.
      older =
        change(save, :keeper, fn saved ->
          %{saved | vsn: 1, boid: %{saved.boid | state: Map.delete(saved.boid.state, :loads)}}
        end)

      {new, {:ok, %{started: [:keeper]}}} = load_again(world, %{}, older)
      assert %{steps: 2, loads: 1} = :gen_boid.call(:boids.whereis(new, :keeper), :state)
    end

    test "handle_load/2 can stop the load of its boid, and a bad answer stops it too" do
      world = world()
      for id <- [:stops, :bad, :other, :good], do: {:ok, _} = :gen_boid.start(world, Keeper, id: id)
      save = :boids.export(world)

      answer = fn save, id, answer ->
        change(save, id, fn saved -> put_in(saved.boid.state[:answer], answer) end)
      end

      other = %{saved(save, :other).boid | id: :another}

      save =
        save
        |> answer.(:stops, {:stop, :no_fuel})
        |> answer.(:bad, :nonsense)
        |> answer.(:other, {:ok, other})

      {new, {:ok, result}} = load_again(world, %{}, save)
      assert result.started == [:good]

      assert result.not_started == [
               stops: :no_fuel,
               bad: {:bad_return_value, :nonsense},
               other: {:bad_return_value, {:ok, other}}
             ]

      assert ids(new) == [:good]
    end

    test "a boid of a module that the node does not have does not start" do
      world = world()
      {:ok, _} = :gen_boid.start(world, Mouse, still(id: :mouse))
      {:ok, :a} = :boids.add(world, still(id: :a))
      save = change(:boids.export(world), :mouse, &%{&1 | mod: :boids_no_such_module})
      {new, {:ok, result}} = load_again(world, %{}, save)
      assert %{started: [:a], not_started: [mouse: {:no_module, :boids_no_such_module}]} = result
      assert ids(new) == [:a]
    end

    test "a world that is not empty keeps its boids, and a boid of the save with the same id does not start" do
      world = world()
      for id <- [:a, :b, :c], do: {:ok, ^id} = :boids.add(world, still(id: id, pos: {1, 1}, data: :saved))
      :ok = :boids.relate(world, :a, :follows, :b)
      :ok = :boids.relate(world, :c, :follows, :b)
      :ok = :boids.relate(world, :c, :follows, :a)
      save = :boids.export(world)

      other = world()
      {:ok, :x} = :boids.add(other, still(id: :x))
      {:ok, :b} = :boids.add(other, still(id: :b, pos: {9, 9}, data: :here))
      {:ok, result} = :boids.import(other, save)
      assert result.started == [:a, :c]
      assert result.not_started == [b: {:exists, :b}]
      assert result.not_related == []
      # The boids of the save are after the boids of the world, in the order of the save.
      assert ids(other) == [:x, :b, :a, :c]
      assert {:ok, %{data: :here, pos: {9, 9}}} = :boids.lookup(other, :b)
      # A relation to the boid of the world with that id.
      assert :boids.related(other, :a, :follows) == [:b]
      assert :boids.related(other, :c, :follows) == [:a, :b]

      # The same save again: all the boids are there.
      {:ok, again} = :boids.import(other, save)
      assert again.started == []
      assert again.not_started == [a: {:exists, :a}, b: {:exists, :b}, c: {:exists, :c}]
      assert :boids.count(other) == 4
    end

    test "tells each relation that the world refuses" do
      world = world()
      for id <- [:a, :b, :c], do: {:ok, ^id} = :boids.add(world, still(id: id))
      :ok = :boids.relate(world, :a, :follows, :b)
      :ok = :boids.relate(world, :b, :follows, :a)
      :ok = :boids.relate(world, :c, :follows, :a)
      {:ok, person} = GenServer.start_link(Person, {world, %{id: :person, pos: {1, 1}}})
      :ok = :boids.relate(world, :c, :knows, :person)
      save = :boids.export(world)
      GenServer.stop(person)

      # A world where the relations cannot make a cycle, and where the process of the user is not.
      {new, {:ok, result}} = load_again(world, [relations: :acyclic], save)
      assert result.started == [:a, :b, :c]

      assert result.not_related == [
               {{:b, :follows, :a}, :cycle},
               {{:c, :knows, :person}, {:not_found, :person}}
             ]

      assert :boids.related(new, :a, :follows) == [:b]
      assert :boids.related(new, :c, :follows) == [:a]
    end

    test "a boid with positions of another size does not start" do
      world = world()
      {:ok, :flat} = :boids.add(world, still(id: :flat, pos: {1, 2}))
      save = :boids.export(world)
      deep = world()
      {:ok, :deep} = :boids.add(deep, still(id: :deep, pos: {1, 2, 3}))

      assert {:ok, %{started: [], not_started: [flat: {:bad_option, {:pos, {1, 2}}}]}} =
               :boids.import(deep, save)
    end

    test "a fact that is newer in the world stays, and the other facts of the save come" do
      world = world(name: :"save_facts#{System.unique_integer([:positive])}")
      :ok = :boids.set_obstacle(world, :rock, {1, 1}, 1)
      :ok = :boids.set_obstacle(world, :tree, {2, 2}, 1)
      :ok = :boids.set_obstacle(world, :gone, {3, 3}, 1)
      :ok = :boids.set_time_scale(world, 0.25)
      save = :boids.export(world)
      # After the save: the world moves the rock, removes the tree, and puts a new obstacle.
      :ok = :boids.set_obstacle(world, :rock, {9, 9}, 1)
      :ok = :boids.remove_obstacle(world, :tree)
      :ok = :boids.set_obstacle(world, :new, {4, 4}, 1)
      facts = :boids_world.facts(world)

      assert {:ok, %{facts: :ok}} = :boids.import(world, save)
      # Each fact of the world is newer than the save, or the same: nothing changes.
      assert :boids_world.facts(world) == facts
      obstacles = fn world -> for %{id: id, pos: pos} <- :boids.obstacles(world), do: {id, pos} end
      assert obstacles.(world) == [gone: {3, 3}, new: {4, 4}, rock: {9, 9}]

      # A new world gets all the facts of the save, with their versions.
      new = world()
      :ok = :boids.set_obstacle(new, :mine, {5, 5}, 1)
      assert {:ok, %{facts: :ok}} = :boids.import(new, save)
      assert obstacles.(new) == [gone: {3, 3}, mine: {5, 5}, rock: {1, 1}, tree: {2, 2}]
      assert %{time_scale: 0.25} = :boids_space.env(:boids.space(new))
      assert save.facts -- :boids_world.facts(new) == []
      # The next change of the new world is after the facts of the save.
      :ok = :boids.set_obstacle(new, :rock, {7, 7}, 1)
      assert obstacles.(new)[:rock] == {7, 7}
    end

    test "an export of another format gives a clear error, and the world does not change" do
      world = world()
      {:ok, :a} = :boids.add(world, still(id: :a))
      :ok = :boids.set_obstacle(world, :rock, {1, 1}, 1)
      save = :boids.export(world)
      new = world()
      assert :boids.import(new, %{save | format: 0}) == {:error, {:format, 0}}
      assert :boids.import(new, %{save | format: 2}) == {:error, {:format, 2}}
      assert :boids.import(new, %{format: :other}) == {:error, {:format, :other}}
      assert :boids.count(new) == 0
      assert :boids.obstacles(new) == []
      # A term that is not an export is an error of the caller.
      assert_raise FunctionClauseError, fn -> :boids.import(new, :save) end
    end

    test "facts that are not facts give the error badarg in the result, and the boids start" do
      world = world()
      {:ok, :a} = :boids.add(world, still(id: :a))
      :ok = :boids.set_obstacle(world, :rock, {1, 1}, 1)
      save = :boids.export(world)
      new = world()
      assert {:ok, %{started: [:a], facts: {:error, :badarg}}} = :boids.import(new, %{save | facts: [:rock]})
      assert Process.alive?(new)
      assert :boids.obstacles(new) == []
    end
  end

  describe "a function in a save" do
    # Load the code of a module with a rule that is an anonymous
    # function, and the same rule as a function with a name. The force is
    # the factor. The code that the node had for the module is its old
    # code then.
    defp reload(module, factor) do
      source = [
        "-module('#{module}').",
        "-export([rule/1, named/3]).",
        "rule(K) -> fun(_Boid, _Neighbors, _Seen) -> {K * #{factor}, 0.0} end.",
        "named(_Boid, _Neighbors, _Seen) -> {#{factor}, 0.0}."
      ]

      forms =
        for line <- source do
          {:ok, tokens, _} = :erl_scan.string(String.to_charlist(line))
          {:ok, form} = :erl_parse.parse_form(tokens)
          form
        end

      {:ok, ^module, binary} = :compile.forms(forms)
      {:module, ^module} = :code.load_binary(module, ~c"nofile", binary)
      :ok
    end

    # The same, on a node that has no other code of the module.
    defp compile(module, factor) do
      delete(module)
      reload(module, factor)
    end

    defp delete(module) do
      :code.purge(module)
      :code.delete(module)
      :code.purge(module)
    end

    # A world with one boid that has one rule, in another process: this
    # process must have no function of the module when its code goes. The
    # result is the save after one step, as a binary, and the position
    # after a second step.
    defp first_run(rule) do
      run = fn ->
        {:ok, world} = :boids.start_world()
        options = still(id: :a, vel: {0, 0}, rules: [{rule.(), 1.0}], max_force: 100, min_speed: 0)
        {:ok, :a} = :boids.add(world, options)
        :ok = :boids.step(world, 0.5)
        save = :boids.export(world)
        :ok = :boids.step(world, 0.5)
        {:ok, %{pos: pos}} = :boids.lookup(world, :a)
        :ok = :boids.stop_world(world)
        {:erlang.term_to_binary(save), length(save.can_fail), pos}
      end

      Task.await(Task.async(run))
    end

    # Load a save from a binary into a new world, and make one step, in
    # another process. The result has no function.
    defp second_run(binary) do
      run = fn ->
        {:ok, world} = :boids.start_world()
        {:ok, result} = :boids.import(world, :erlang.binary_to_term(binary))

        # What Erlang does with a call of a function that import/2 did not take.
        calls =
          for {id, {:function, fun}} <- result.not_started do
            try do
              {_x, _y} = fun.(nil, nil, nil)
              {id, :called}
            catch
              :error, {:badfun, ^fun} -> {id, :badfun}
              :error, :undef -> {id, :undef}
            end
          end

        :ok = :boids.step(world, 0.5)
        pos = for %{pos: pos} <- :boids.snapshot(world), do: pos
        :ok = :boids.stop_world(world)
        {result.started, calls, pos}
      end

      Task.await(Task.async(run))
    end

    test "an anonymous function as a rule loads only on a node with the same code of its module" do
      module = Module.concat(__MODULE__, "Rules#{System.unique_integer([:positive])}")
      on_exit(fn -> delete(module) end)
      compile(module, 1.0)
      {binary, 1, expected} = first_run(fn -> module.rule(2.0) end)

      # The same code: the boid starts, and it continues as in the first world.
      assert second_run(binary) == {[:a], [], [expected]}

      # The module changes, and the node keeps the first code as the old
      # code of the module: Erlang can call the function. That code goes
      # at the next change of the module, so the boid does not start.
      reload(module, 3.0)
      assert :erlang.check_old_code(module)
      assert second_run(binary) == {[], [a: :called], []}

      # Only another code of the module: the term is a function, but Erlang cannot call it.
      compile(module, 3.0)
      refute :erlang.check_old_code(module)
      assert second_run(binary) == {[], [a: :badfun], []}

      # No code of the module.
      delete(module)
      assert second_run(binary) == {[], [a: :undef], []}

      # The first code again: the boid starts.
      compile(module, 1.0)
      assert second_run(binary) == {[:a], [], [expected]}
    end

    test "a function with a name as a rule loads with each code of its module that has the function" do
      module = Module.concat(__MODULE__, "Rules#{System.unique_integer([:positive])}")
      on_exit(fn -> delete(module) end)
      compile(module, 1.0)
      {binary, 0, expected} = first_run(fn -> Function.capture(module, :named, 3) end)
      assert second_run(binary) == {[:a], [], [expected]}

      # Another code of the module: the boid starts, and the rule is the new function.
      compile(module, 3.0)
      assert {[:a], [], [{x, _}]} = second_run(binary)
      assert x > elem(expected, 0)

      # No code of the module: the node cannot call the function.
      delete(module)
      assert second_run(binary) == {[], [a: :undef], []}
    end
  end
end
