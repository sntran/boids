defmodule BoidsReadmeTest do
  # The examples of README.md.
  use ExUnit.Case, async: true
  import Boids.Helpers

  defmodule Hawk do
    @behaviour :gen_boid

    @impl true
    def init(pos) do
      {:ok,
       %{pos: pos, group: :hawks, perception: 25, rules: [wander: 1.0], state: %{energy: 10.0}, tick: :manual}}
    end

    @impl true
    def handle_sense(%{neighbors: neighbors} = seen, boid) do
      {:ok, Map.put(seen, :prey, Enum.filter(neighbors, &(&1.group == :birds))), boid}
    end

    @impl true
    def handle_decide(%{prey: [_ | _]}, %{state: %{energy: energy}} = boid) when energy > 2 do
      {:ok, :boids_boid.update(boid, %{rules: [{:pursue, 1.0, %{target: {:group, :birds}}}]})}
    end

    def handle_decide(_seen, boid), do: {:ok, :boids_boid.update(boid, %{rules: [wander: 1.0]})}

    @impl true
    def handle_act(%{vel: vel, state: %{energy: energy} = state} = boid) do
      {:ok, %{boid | state: %{state | energy: energy - 0.01 * :boids_vec.norm(vel)}}}
    end

    @impl true
    def handle_call(:energy, _from, %{state: %{energy: energy}} = boid), do: {:reply, energy, boid}
  end

  defmodule Person do
    use GenServer

    def init(world) do
      {:ok, space, boid} = :boids.join(world, pos: {0, 0}, vel: {1, 0})
      Process.send_after(self(), :tick, 5)
      {:ok, %{space: space, boid: boid}}
    end

    def handle_info(:tick, %{space: space, boid: boid} = state) do
      Process.send_after(self(), :tick, 5)
      {:noreply, %{state | boid: :boids.advance(space, boid, 0.05)}}
    end
  end

  setup do
    {:ok, world} = :boids.start_world(bounds: {{0, 0}, {100, 100}}, wrap: true)
    on_exit(fn -> :boids.stop_world(world) end)
    %{world: world}
  end

  test "a first flock", %{world: world} do
    {:ok, ids} = :boids.populate(world, 200, max_speed: 12.0)
    assert length(ids) == 200

    assert [%{id: id, pos: {_, _}, vel: {_, _}, group: :default, data: :undefined, pid: pid} | _] =
             :boids.snapshot(world)

    assert is_reference(id) and :boids.whereis(world, id) == pid

    before = Map.new(:boids.snapshot(world), &{&1.id, &1.pos})
    assert eventually(fn -> Enum.all?(:boids.snapshot(world), &(&1.pos != before[&1.id])) end)
  end

  test "a boid with a behavior", %{world: world} do
    {:ok, hawk} = :gen_boid.start(world, Hawk, {50, 50})
    assert :gen_boid.call(hawk, :energy) == 10.0
    assert :gen_boid.which_rules(hawk) == [:wander]

    # The hawk sees a bird: it pursues the bird, and it uses energy.
    {:ok, _bird} = :boids.add(world, pos: {55, 50}, group: :birds, rules: [], tick: :manual)
    for _ <- 1..10, do: :boids.step(world, 0.05)
    assert :gen_boid.which_rules(hawk) == [:pursue]
    assert :gen_boid.call(hawk, :energy) < 10.0
  end

  test "the rules of a boid", %{world: world} do
    birds = [
      {:avoid, 4.0},
      {:evade, 3.0, %{target: {:group, :hawks}, radius: 12}},
      {:separation, 1.5, %{radius: 3}},
      {:alignment, 1.0},
      {:cohesion, 1.0}
    ]

    assert {:ok, _} =
             :boids.populate(world, 70, %{
               group: :birds,
               rules: birds,
               combine: :priority,
               tick: :manual
             })

    hawk = [{:avoid, 4.0}, {:pursue, 1.0, %{target: {:group, :birds}}}, {:wander, 0.5}]

    assert {:ok, id} =
             :boids.add(world, %{
               pos: {50, 50},
               group: :hawks,
               rules: hawk,
               perception: 25,
               tick: :manual
             })

    assert :boids.set_obstacle(world, :rock, {30, 30}, 5) == :ok
    for _ <- 1..20, do: :boids.step(world, 0.05)
    assert :boids.update(world, id, %{rules: [{:arrive, 1.0, %{target: {10, 10}}}]}) == :ok
    for _ <- 1..400, do: :boids.step(world, 0.05)
    {:ok, %{pos: pos}} = :boids.lookup(world, id)
    assert_vec(pos, {10.0, 10.0}, 0.1)

    # One rule at a time, with a name for each of two rules of seek.
    assert :boids.add_rule(world, id, {{:seek, :home}, 1.0, %{target: {0, 0}}}) == :ok
    assert :boids.add_rule(world, id, {{:seek, :food}, 2.0, %{target: {40, 10}}}) == :ok
    assert :boids.which_rules(world, id) == {:ok, [:arrive, {:seek, :home}, {:seek, :food}]}
    assert :boids.delete_rule(world, id, {:seek, :food}) == :ok
    assert :boids.which_rules(world, id) == {:ok, [:arrive, {:seek, :home}]}
  end

  test "a rule of your own", %{world: world} do
    gravity = fn _boid, _neighbors, _seen -> {0, -9.81} end

    fear = fn boid, neighbors, _seen ->
      case Enum.filter(neighbors, &(&1.group == :cats)) do
        [%{pos: pos} | _] -> :boids_steer.flee(boid, pos)
        [] -> {0, 0}
      end
    end

    {:ok, id} =
      :boids.add(world,
        pos: {50, 50},
        rules: [{gravity, 1.0}, {fear, 3.0}],
        max_speed: 5,
        tick: :manual
      )

    {:ok, _cat} = :boids.add(world, pos: {53, 50}, group: :cats, rules: [], max_speed: 0, tick: :manual)
    for _ <- 1..10, do: :boids.step(world, 0.05)
    {:ok, %{vel: {vx, vy}}} = :boids.lookup(world, id)
    # The boid moves down, and away from the cat.
    assert vx < 0 and vy < 0
  end

  test "the relations between the boids", %{world: world} do
    {:ok, leader} =
      :boids.add(world, pos: {50, 50}, vel: {2, 0}, rules: [cruise: 1.0], max_speed: 2, tick: :manual)

    {:ok, bird} = :boids.add(world, pos: {20, 80}, rules: [], tick: :manual)

    assert :boids.relate(world, bird, :follows, leader) == :ok

    assert :boids.update(world, bird, %{rules: [{:leader, 1.0, %{target: {:related, :follows}}}]}) ==
             :ok

    assert :boids.related(world, bird, :follows) == [leader]
    assert :boids.related_to(world, leader, :follows) == [bird]

    relations = :boids.relations(world)
    assert :graph.in_neighbours(relations, leader) == [bird]
    assert :graph.get_path(relations, bird, leader) == [bird, leader]

    # The bird comes behind its leader.
    for _ <- 1..400, do: :boids.step(world, 0.05)
    {:ok, %{pos: at}} = :boids.lookup(world, bird)
    {:ok, %{pos: to}} = :boids.lookup(world, leader)
    assert :boids_vec.norm(:boids_space.offset(:boids.space(world), at, to)) < 10

    # The relations of a boid go with the boid.
    assert :boids.remove(world, leader) == :ok
    assert :boids.related(world, bird, :follows) == []
  end

  test "a hierarchy has no cycle" do
    {:ok, world} = :boids.start_world(relations: :acyclic)
    {:ok, a} = :boids.add(world, pos: {0, 0}, tick: :manual)
    {:ok, b} = :boids.add(world, pos: {1, 0}, tick: :manual)
    assert :boids.relate(world, a, :follows, b) == :ok
    assert :boids.relate(world, b, :follows, a) == {:error, :cycle}
    assert :graph.topsort(:boids.relations(world)) == [a, b]
    :boids.stop_world(world)
  end

  test "the flocks of a world", %{world: world} do
    still = [rules: [], tick: :manual]
    {:ok, a} = :boids.add(world, [pos: {10, 10}] ++ still)
    {:ok, b} = :boids.add(world, [pos: {15, 10}] ++ still)
    {:ok, c} = :boids.add(world, [pos: {60, 60}] ++ still)

    flocks = :boids.flocks(world, 10)
    assert Enum.sort(Enum.map(flocks, &Enum.sort/1)) == Enum.sort([Enum.sort([a, b]), [c]])
    assert Enum.max(Enum.map(flocks, &length/1)) == 2

    graph = :boids.graph(world, 10)
    assert for(id <- :graph.vertices(graph), :graph.out_degree(graph, id) == 0, do: id) == [c]
    assert :graph.has_path(graph, a, b)
    refute :graph.has_path(graph, a, c)
  end

  test "a process of yours as a boid", %{world: world} do
    {:ok, pid} = GenServer.start_link(Person, world)
    assert {:ok, %{pos: {0, 0}}} = :boids.lookup(world, pid)
    assert eventually(fn -> elem(:boids.lookup(world, pid), 1).pos != {0, 0} end)
    GenServer.stop(pid)
    assert eventually(fn -> :boids.count(world) == 0 end)
  end

  test "the walls of a world" do
    land = :boids_grid.from_rows([~c"..........", ~c"....##....", ~c".........."], %{cell_size: 10.0})
    {:ok, world} = :boids.start_world(%{bounds: {{0, 0}, {100, 30}}, defaults: %{walkable: {:named, :land}}})
    on_exit(fn -> :boids.stop_world(world) end)
    :ok = :boids.set_grid(world, :land, land)
    {:ok, people} = :boids.populate(world, 20, %{rules: [{:wander, 1.0}, {:walls, 2.0}]})
    {:ok, bird} = :boids.add(world, %{pos: {50, 15}, walkable: :all})
    assert {:ok, %{pos: {50, 15}}} = :boids.lookup(world, bird)

    in_open_cells = fn grid ->
      for id <- people do
        {:ok, %{pos: pos}} = :boids.lookup(world, id)
        assert :boids_grid.walkable(grid, pos), "#{inspect(pos)} is in the wall"
      end
    end

    for _ <- 1..10 do
      Process.sleep(20)
      in_open_cells.(land)
    end

    # A door opens in the wall.
    door = :boids_grid.set_cost(land, [{4, 1}], 1)
    :ok = :boids.set_grid(world, :land, door)
    assert :boids_grid.walkable(door, {45.0, 15.0})
    refute :boids_grid.walkable(door, {55.0, 15.0})

    for _ <- 1..10 do
      Process.sleep(20)
      in_open_cells.(door)
    end
  end

  test "the ways of a world" do
    land = :boids_grid.new(%{size: {40, 30}, blocked: for(j <- 0..29, j != 14, j != 15, do: {20, j})})
    {:ok, world} = :boids.start_world(%{bounds: {{0, 0}, {40, 30}}, defaults: %{walkable: {:named, :land}}})
    on_exit(fn -> :boids.stop_world(world) end)
    :ok = :boids.set_grid(world, :land, land)
    :ok = :boids.set_field(world, :exit, :boids_field.new(land, [{35, 5}], %{margin: [3, 2]}))
    rules = [{:flow, 1.0, %{field: {:named, :exit}}}, {:separation, 1.5, %{radius: 0.7}}]
    {:ok, people} = :boids.populate(world, 30, %{area: {{2, 2}, {15, 28}}, rules: rules})
    place = fn id -> elem(:boids.lookup(world, id), 1).pos end
    assert Enum.all?(people, fn id -> elem(place.(id), 0) < 15 end)
    # The people go around the wall, through the door.
    assert eventually(fn -> Enum.any?(people, fn id -> elem(place.(id), 0) > 21 end) end, 500)
    assert Enum.all?(people, fn id -> :boids_grid.walkable(land, place.(id)) end)

    # The door closes, and another door opens: new walls, and new ways.
    closed = :boids_grid.set_cost(land, [{20, 14}, {20, 15}], :blocked)
    land2 = :boids_grid.set_cost(closed, [{20, 3}, {20, 4}], 1)
    :ok = :boids.set_grid(world, :land, land2)
    :ok = :boids.set_field(world, :exit, :boids_field.new(land2, [{35, 5}], %{margin: [3, 2]}))
    assert {:ok, field} = :boids.field(world, :exit)
    # At the left of the old door, the way now goes up, to the new door.
    assert {_dx, dy} = :boids_field.direction(field, {16.5, 14.5})
    assert dy < -0.9
    # A person in the door that closed goes out of it at its next step.
    # Then the people stay in the open cells of the new walls.
    in_open_cells = fn -> Enum.all?(people, fn id -> :boids_grid.walkable(land2, place.(id)) end) end
    assert eventually(in_open_cells)

    for _ <- 1..10 do
      Process.sleep(20)
      assert in_open_cells.()
    end
  end

  test "two streams in a narrow way" do
    way =
      :boids_grid.from_rows(
        [~c"####################", ~c"....................", ~c"####################"],
        %{cell_size: 2.0}
      )

    # 40 seconds in steps of 0.1 second. The result is for the last 20
    # seconds: the mean speed of the boids in their direction as a part
    # of the maximum speed, the distance between the two streams across
    # the way, and the number of times that a boid is nearer than 0.35
    # to a boid of the other stream.
    run = fn streams ->
      {:ok, world} =
        :boids.start_world(%{bounds: {{0, 0}, {40, 6}}, wrap: true, defaults: %{walkable: {:named, :way}}})

      :ok = :boids.set_grid(world, :way, way)
      :rand.seed(:exsss, {1, 2, 3})
      people = %{max_speed: 4, max_force: 24, perception: 2, tick: :manual}
      east = %{group: :east, seed: 100, rules: [{:flow, 1.0, %{field: {1, 0}}} | streams]}
      west = %{group: :west, seed: 200, rules: [{:flow, 1.0, %{field: {-1, 0}}} | streams]}
      {:ok, _} = :boids.populate(world, 15, Map.merge(people, east))
      {:ok, _} = :boids.populate(world, 15, Map.merge(people, west))

      sums =
        Enum.reduce(1..400, %{speed: 0.0, apart: 0.0, near: 0}, fn step, sums ->
          :ok = :boids.step(world, 0.1)
          rows = :boids.snapshot(world)
          for %{pos: pos} <- rows, do: assert(:boids_grid.walkable(way, pos))
          east = for %{group: :east, pos: pos, vel: {speed, _}} <- rows, do: {pos, speed}
          west = for %{group: :west, pos: pos, vel: {speed, _}} <- rows, do: {pos, -speed}
          side = fn stream -> Enum.sum(for {{_, y}, _} <- stream, do: y) / 15 end

          near =
            for {here, _} <- east, {there, _} <- west, reduce: 0 do
              near ->
                between = :boids_vec.shortest(:boids_vec.sub(there, here), {0.0, 0.0}, {40.0, 6.0})
                if :boids_vec.norm(between) < 0.35, do: near + 1, else: near
            end

          if step > 200 do
            %{
              speed: sums.speed + Enum.sum(for {_, speed} <- east ++ west, do: speed) / (30 * 4),
              # A boid that goes east has its right at -y.
              apart: sums.apart + side.(west) - side.(east),
              near: sums.near + near
            }
          else
            sums
          end
        end)

      :ok = :boids.stop_world(world)
      %{speed: sums.speed / 200, apart: sums.apart / 200, near: sums.near}
    end

    # The two rules: the two streams go at their full speed, each along
    # the wall at its right, and no boid touches a boid of the other
    # stream.
    streams = [{:separation, 1.5, %{radius: 0.7, oncoming: false}}, {:dodge, 4.0}]
    together = run.(streams)
    assert together.speed > 0.95
    assert together.apart > 1.5
    assert together.near == 0

    # With oncoming => false and no dodge, the two streams go through
    # each other.
    through = run.([hd(streams)])
    assert through.speed > 0.95
    assert abs(through.apart) < 0.5
    assert through.near > 100
  end

  test "a world below a supervisor of yours" do
    children = [{:boids, name: :boids_readme_space, bounds: {{0, 0}, {100, 100}}}]
    {:ok, sup} = Supervisor.start_link(children, strategy: :one_for_one)
    assert :boids.count(:boids_readme_space) == 0
    Supervisor.stop(sup)
  end

  defmodule Saver do
    # The boid of "A module that changes, and a state that a save cannot keep".
    @behaviour :gen_boid
    @vsn 2

    @impl true
    def init(pos) do
      state = %{energy: 10.0, seen: :ets.new(:seen, [])}
      {:ok, %{pos: pos, rules: [], tick: :manual, state: state}}
    end

    @impl true
    def handle_call(:state, _from, boid), do: {:reply, boid.state, boid}

    # A save of the version 1 had no energy.
    @impl true
    def handle_load(1, %{state: state} = boid),
      do: handle_load(2, %{boid | state: Map.put(state, :energy, 10.0)})

    # The table of the boid stopped with its first process.
    def handle_load(2, %{state: state} = boid),
      do: {:ok, %{boid | state: %{state | seen: :ets.new(:seen, [])}}}
  end

  @doc "A rule that is a function with a name."
  def east(_boid, _neighbors, _seen), do: {1.0, 0.0}

  test "save a world, and load it", %{world: world} do
    rules = [separation: 1.5, alignment: 1.0, cohesion: 1.0, wander: 0.5]
    {:ok, ids} = :boids.populate(world, 30, rules: rules, tick: :manual, seed: 1)
    for _ <- 1..100, do: :boids.step(world, 0.05)

    # Save.
    file = Path.join(System.tmp_dir!(), "boids-readme-#{System.unique_integer([:positive])}.save")
    on_exit(fn -> File.rm(file) end)
    File.write!(file, :erlang.term_to_binary(:boids.export(world)))
    # The first world makes 100 steps more: 200 steps with no load.
    for _ <- 1..100, do: :boids.step(world, 0.05)
    straight = for %{id: id, pos: pos, vel: vel} <- :boids.snapshot(world), do: {id, pos, vel}
    :ok = :boids.stop_world(world)

    # Load, in a new world with the same options.
    {:ok, new} = :boids.start_world(bounds: {{0, 0}, {100, 100}}, wrap: true)
    on_exit(fn -> :boids.stop_world(new) end)
    save = :erlang.binary_to_term(File.read!(file))
    assert {:ok, %{started: ^ids, not_started: []}} = :boids.import(new, save)
    assert Enum.map(:boids.snapshot(new), & &1.id) == ids
    for _ <- 1..100, do: :boids.step(new, 0.05)
    assert for(%{id: id, pos: pos, vel: vel} <- :boids.snapshot(new), do: {id, pos, vel}) == straight
  end

  test "what a save cannot keep", %{world: world} do
    still = [pos: {0, 0}, tick: :manual]
    {:ok, a} = :boids.add(world, still ++ [rules: [{fn _, _, _ -> {1.0, 0.0} end, 1.0}]])
    {:ok, b} = :boids.add(world, still ++ [rules: [{&__MODULE__.east/3, 1.0}]])
    {:ok, person} = GenServer.start_link(Person, world)
    {:ok, child} = :gen_boid.start_link(world, Hawk, {5, 5})
    {:ok, timer} = :boids.add(world, still ++ [data: make_ref()])

    %{not_saved: not_saved, can_fail: can_fail} = save = :boids.export(world)
    assert [{^person, :process}, {_id, :supervised}] = not_saved
    assert [{^a, {:function, rule}}, {^timer, {:live, _ref}}] = can_fail
    assert is_function(rule, 3)
    assert Enum.map(save.boids, & &1.boid.id) == [a, b, timer]
    GenServer.stop(person)
    :gen_boid.stop(child)

    # This node has the code that made the function: the two boids start.
    {:ok, new} = :boids.start_world()
    on_exit(fn -> :boids.stop_world(new) end)
    assert {:ok, %{started: [^a, ^b, ^timer], not_started: []}} = :boids.import(new, save)
  end

  test "a module that changes, and a state that a save cannot keep", %{world: world} do
    {:ok, saver} = :gen_boid.start(world, Saver, {5, 5})
    %{seen: table} = :gen_boid.call(saver, :state)
    %{boids: [%{vsn: 2, boid: %{id: id}} = saved], can_fail: []} = save = :boids.export(world)
    :ok = :boids.stop_world(world)
    # The table stopped with its process.
    assert :ets.info(table) == :undefined

    # A save of the version 1 of the module had no energy.
    older = %{saved | vsn: 1, boid: %{saved.boid | state: Map.delete(saved.boid.state, :energy)}}
    {:ok, new} = :boids.start_world()
    on_exit(fn -> :boids.stop_world(new) end)
    assert {:ok, %{started: [^id]}} = :boids.import(new, %{save | boids: [older]})
    assert %{energy: 10.0, seen: seen} = :gen_boid.call(:boids.whereis(new, id), :state)
    assert seen != table and :ets.info(seen, :size) == 0
  end
end
