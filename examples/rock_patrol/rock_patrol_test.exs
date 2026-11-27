defmodule BoidsExamples.Games.RockPatrolTest do
  # Rock Patrol: the ship, the rocks, the drones and their bolts.
  use ExUnit.Case, async: false
  alias BoidsExamples.Scene

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

  test "the game has a ship that takes the keys of a person" do
    {_pid, {:ok, scene}} = scene(BoidsExamples.Games.RockPatrol)
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
    {_pid, {:ok, %{space: space} = scene}} = scene(BoidsExamples.Games.RockPatrol)
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
    {_pid, {:ok, %{space: space} = scene}} = scene(BoidsExamples.Games.RockPatrol)
    {:ok, %{pos: {x, y}}} = :boids.lookup(space, :ship)
    args = %{id: :hunter, pos: {x - 12, y}, space: space}
    {:ok, drone} = :gen_boid.start(space, BoidsExamples.Games.RockPatrol.Drone, args)
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
    {_pid, {:ok, %{space: space, ship: ship}}} = scene(BoidsExamples.Games.RockPatrol)
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
end
