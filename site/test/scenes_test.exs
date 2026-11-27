defmodule BoidsSite.ScenesTest do
  # The scenes of the site: each one starts, gives moments, and stops.
  use ExUnit.Case, async: false
  alias BoidsSite.Scene

  # Start a scene in a process of its own. The scene stops with that process.
  defp scene(module, definition \\ nil) do
    test = self()

    pid =
      spawn(fn ->
        send(test, {:scene, Scene.start(module, definition)})
        Process.sleep(:infinity)
      end)

    on_exit(fn -> Process.exit(pid, :kill) end)
    assert_receive {:scene, result}, 5000
    {pid, result}
  end

  defp moments(scene, count) do
    for number <- 1..count do
      Process.sleep(Scene.tick())
      moment = Scene.frame(scene, number)
      assert rem(length(moment.b), 6) == 0
      assert Enum.all?(moment.b, &is_number/1)
      # The page gets JSON.
      assert is_binary(IO.iodata_to_binary(:json.encode(moment)))
      moment
    end
  end

  test "the flock of the home page has birds and a hawk" do
    {_pid, {:ok, scene}} = scene(BoidsSite.Scenes.Flock)
    header = Scene.header(scene)
    assert header.box == [160, 60]
    assert length(header.rocks) == 2
    assert [%{name: "birds"}, %{name: "hawk"}] = header.kinds
    assert is_binary(IO.iodata_to_binary(:json.encode(header)))

    moments = moments(scene, 25)
    assert length(hd(moments).b) == 61 * 6
    assert [["The hawk", mode], ["Its energy", energy]] = List.last(moments).r
    assert mode in ["hunts", "rests"] and is_float(energy)
    # The boids move.
    assert hd(moments).b != List.last(moments).b
  end

  test "the game has a ship that takes the keys of a person" do
    {_pid, {:ok, scene}} = scene(BoidsSite.Scenes.Game)
    assert Enum.map(Scene.header(scene).kinds, & &1.name) == ["ship", "rocks", "drones", "queen", "shots", "bolts"]

    [moment | _] = moments(scene, 3)
    assert [["Score", 0], ["Shield", 3], ["Wrecks", 0], ["Pilot", "autopilot"] | _] = moment.r
    kinds = moment.b |> Enum.chunk_every(6) |> Enum.frequencies_by(&Enum.at(&1, 4))
    assert %{0 => 1, 2 => 5, 3 => 1} = kinds

    # The keys make the person the pilot, and the ship shoots.
    assert Scene.input(scene, %{"keys" => ["thrust", "fire", "other"]}) == :ok
    after_keys = moments(scene, 8)
    assert Enum.any?(after_keys, fn moment -> ["Pilot", "you"] in moment.r end)
    assert Enum.any?(after_keys, fn moment -> moment.b |> Enum.chunk_every(6) |> Enum.any?(&(Enum.at(&1, 4) == 4)) end)
    assert Enum.any?(after_keys, &(&1.x.thrust == true))

    # Other messages change nothing.
    assert Scene.input(scene, %{"ping" => 1}) == :ok
    # Each drone has the relation guards to the queen.
    assert length(:boids.related_to(scene.space, :queen, :guards)) >= 5
    # The relations of the drones come with a moment of each second.
    assert Enum.any?(moments(scene, div(1000, Scene.tick()) + 1), &is_list(&1[:l]))
  end

  test "a hit makes two smaller rocks of a rock, and removes a drone" do
    {_pid, {:ok, %{space: space} = scene}} = scene(BoidsSite.Scenes.Game)
    rows = :boids.snapshot(space)
    [rock | _] = for %{group: :rocks, pid: pid} <- rows, do: pid
    [drone | _] = for %{group: :drones, pid: pid} <- rows, do: pid
    count = fn group -> Enum.count(:boids.snapshot(space), &(&1.group == group)) end
    {rocks, drones} = {count.(:rocks), count.(:drones)}

    :gen_boid.cast(rock, :hit)
    :gen_boid.cast(drone, :hit)
    Process.sleep(300)
    assert count.(:rocks) == rocks + 1
    assert count.(:drones) == drones - 1
    assert Enum.sort(for %{group: :rocks, data: size} <- :boids.snapshot(space), do: size) |> Enum.take(2) == [2, 2]
    assert [_ | _] = moments(scene, 2)
  end

  # Wait until `fun` gives a true value, for `tries` times 50 ms at most.
  defp eventually(fun, tries) do
    case fun.() do
      value when value in [false, nil] and tries > 0 ->
        Process.sleep(50)
        eventually(fun, tries - 1)

      value ->
        value
    end
  end

  test "a drone that hunts the ship shoots a bolt at it" do
    {_pid, {:ok, %{space: space} = scene}} = scene(BoidsSite.Scenes.Game)
    {:ok, %{pos: {x, y}}} = :boids.lookup(space, :ship)
    args = %{id: :hunter, pos: {x - 12, y}, space: space}
    {:ok, drone} = :gen_boid.start(space, BoidsSite.Scenes.Game.Drone, args)
    # The drone does not move, so its bolt has a distance to go, and the test sees it.
    :ok = :boids.update(space, :hunter, %{min_speed: 0, max_speed: 0})

    bolt =
      eventually(
        fn ->
          # The keys of a person: the ship does not shoot at the drone.
          :ok = Scene.input(scene, %{"keys" => []})
          Enum.find(:boids.snapshot(space), &(&1.group == :bolts))
        end,
        160
      )

    assert %{group: :bolts} = bolt
    # The drone hunts: it has the rule of a hunt.
    assert Process.alive?(drone)
    assert :pursue in :gen_boid.which_rules(drone)
    # The page gets the bolt as a kind of its own.
    kinds = Scene.frame(scene, 1).b |> Enum.chunk_every(6) |> Enum.map(&Enum.at(&1, 4))
    assert 5 in kinds or :boids.lookup(space, bolt.id) == :error
  end

  test "a hit takes one part of the shield of a ship that is not safe" do
    {_pid, {:ok, %{space: space, ship: ship}}} = scene(BoidsSite.Scenes.Game)
    status = fn -> elem(:boids.lookup(space, :ship), 1).data end

    # At the start, the ship is safe: a hit does nothing.
    assert %{safe: true, shield: 3} = status.()
    :gen_boid.cast(ship, :hit)
    Process.sleep(150)
    assert %{shield: 3, wrecks: 0} = status.()

    # After the safe time, a hit takes one part. A drone of the game can
    # also hit the ship: the ship is then safe, and the result is the same.
    before = eventually(fn -> if(status.().safe, do: nil, else: status.()) end, 120)
    assert %{safe: false, shield: shield, wrecks: wrecks} = before
    :gen_boid.cast(ship, :hit)

    after_hit =
      eventually(fn -> if(status.().safe, do: status.(), else: nil) end, 40)

    case shield do
      1 -> assert %{shield: 3, wrecks: ^wrecks} = Map.update!(after_hit, :wrecks, &(&1 - 1))
      _ -> assert after_hit.shield == shield - 1
    end
  end

  describe "the playground" do
    @birds %{
      "name" => "birds",
      "count" => 12,
      "speed" => [6, 12],
      "search" => 2,
      "rules" => [["separation", 1.5, %{"radius" => 3}], ["alignment", 1], ["cohesion", 1]],
      "when" => [%{"sees" => "hawks", "rules" => [["evade", 3, %{"target" => "hawks"}]]}]
    }
    @hawks %{
      "name" => "hawks",
      "count" => 1,
      "speed" => 14,
      "perception" => 30,
      "color" => "warm",
      "rules" => [["pursue", 1, %{"target" => "birds"}]]
    }

    test "starts the kinds of a definition" do
      definition = %{"box" => [100, 60], "rocks" => [[50, 30, 5]], "kinds" => [@birds, @hawks]}
      {_pid, {:ok, %{space: space} = scene}} = scene(BoidsSite.Scenes.Playground, definition)
      header = Scene.header(scene)
      assert header.box == [100, 60] and header.rocks == [[50, 30, 5]]
      assert [%{name: "birds", shape: "dart"}, %{name: "hawks", color: "warm"}] = header.kinds
      assert Enum.frequencies_by(:boids.snapshot(space), & &1.group) == %{"birds" => 12, "hawks" => 1}

      # A bird that sees the hawk has the other rules.
      for _ <- 1..40, do: Process.sleep(Scene.tick())
      rules = for %{group: "birds", pid: pid} <- :boids.snapshot(space), do: :gen_boid.which_rules(pid)
      assert Enum.all?(rules, &(&1 in [[:separation, :alignment, :cohesion], [:evade]]))
      assert [_ | _] = moments(scene, div(1000, Scene.tick()) + 1) |> Enum.filter(&(&1[:r] != nil))
    end

    test "a chain gives each boid the relation follows to the boid before it" do
      chain = %{
        "name" => "convoy",
        "count" => 5,
        "follows" => "chain",
        "rules" => [["leader", 2, %{"target" => "leader"}]]
      }

      {_pid, {:ok, %{space: space}}} = scene(BoidsSite.Scenes.Playground, %{"kinds" => [chain]})
      relations = :boids.relations(space)
      assert :graph.no_edges(relations) == 4

      assert :graph.is_arborescence(:graph.subgraph(relations, :graph.vertices(relations))) or
               :graph.is_acyclic(relations)
    end

    test "refuses a bad definition with a text for the visitor" do
      bad = fn definition ->
        {_pid, {:error, text}} = scene(BoidsSite.Scenes.Playground, definition)
        text
      end

      assert bad.(%{}) =~ "list of kinds"
      assert bad.(%{"kinds" => [%{"count" => 3}]}) =~ "needs a name"
      assert bad.(%{"kinds" => [Map.put(@birds, "count", 5000)]}) =~ "boids at most"
      assert bad.(%{"kinds" => List.duplicate(@hawks, 7)}) =~ "6 kinds"
      assert bad.(%{"kinds" => [Map.put(@hawks, "rules", [["fly", 1]])]}) =~ "not a rule"
      assert bad.(%{"kinds" => [Map.put(@hawks, "rules", [["seek", 1, %{"speed" => 2}]])]}) =~ "bad rules"
      assert bad.(%{"kinds" => [Map.put(@hawks, "rules", [["seek", 1, %{"atom" => 2}]])]}) =~ "not an option"
      assert bad.(%{"kinds" => [Map.put(@hawks, "perception", -1)]}) =~ "bad perception"
      assert bad.(%{"kinds" => [Map.put(@hawks, "shape", "star")]}) =~ "shape"
      assert bad.(%{"box" => [10, 10], "kinds" => [@hawks]}) =~ "sides of the box"
      assert bad.(%{"rocks" => [[1, 2]], "kinds" => [@hawks]}) =~ "rock is"
      # A scene that the site refuses starts no world.
      assert :counters.get(:persistent_term.get(BoidsSite.Scene), 1) == 0
    end
  end

  test "the site has a limit of the scenes at one time, and a scene stops with its visitor" do
    count = :persistent_term.get(BoidsSite.Scene)
    limit = String.to_integer(System.get_env("BOIDS_SCENES", "8"))
    started = for _ <- 1..limit, do: scene(BoidsSite.Scenes.Playground, %{"kinds" => [@hawks]})
    assert Enum.all?(started, &match?({_pid, {:ok, _}}, &1))
    assert {_pid, {:error, text}} = scene(BoidsSite.Scenes.Playground, %{"kinds" => [@hawks]})
    assert text =~ "scenes at one time"

    for {pid, _} <- started, do: Process.exit(pid, :kill)
    Process.sleep(300)
    assert :counters.get(count, 1) == 0
    assert {_pid, {:ok, scene}} = scene(BoidsSite.Scenes.Playground, %{"kinds" => [@hawks]})
    # A visitor can stop a scene, for a new one.
    Scene.stop(scene)
    Process.sleep(200)
    assert :counters.get(count, 1) == 0
  end
end
