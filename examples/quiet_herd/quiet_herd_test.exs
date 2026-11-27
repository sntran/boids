defmodule BoidsExamples.HerdTest do
  # The game Quiet Herd: the fear of the deer, the wave, the alarm, the
  # guards, the grass and the fields.
  use ExUnit.Case, async: false
  alias BoidsExamples.Scene
  alias BoidsExamples.Games.QuietHerd, as: Herd
  alias BoidsExamples.Games.QuietHerd.Director

  # Start a try in a process of its own, as a visitor. The try stops with
  # that process.
  defp run(options) do
    test = self()

    pid =
      spawn(fn ->
        send(test, {:scene, Scene.start(Herd, options)})
        Process.sleep(:infinity)
      end)

    on_exit(fn -> Process.exit(pid, :kill) end)
    assert_receive {:scene, {:ok, scene}}, 5000
    scene
  end

  # Wait until the function gives a true value, for 10 seconds at most.
  defp wait(fun, what, tries \\ 200) do
    case fun.() do
      value when value in [false, nil] ->
        if tries == 0, do: flunk("No #{what} in 10 seconds.")
        Process.sleep(50)
        wait(fun, what, tries - 1)

      value ->
        value
    end
  end

  defp status(scene), do: Director.status(scene.director)
  defp deer(scene), do: for(%{group: :deer} = row <- :boids.snapshot(scene.space, :local), do: row)
  defp afraid(scene), do: Enum.count(deer(scene), &(&1.data.fear == :afraid))

  defp scare(scene, row, from) do
    :gen_boid.cast(:boids.whereis(scene.space, row.id), {:scare, from})
  end

  # A tight group of 12 deer around a point.
  defp herd({x, y}), do: for(i <- 0..3, j <- 0..2, do: {x + i * 3.0, y + j * 3.0})

  @quiet %{guards: [], limit: 99}

  test "a field has the deer, the guards, the fox, the grass and the far side" do
    scene = run(%{})
    header = Scene.header(scene)
    assert header.box == [160, 90]
    assert Enum.map(header.kinds, & &1.name) == ["calm deer", "alert deer", "afraid deer", "fox", "guards"]
    [goal | grass] = header.zones
    assert goal == [152, 0, 160, 90, "warm", "Far side"]
    assert length(grass) == 4 and Enum.all?(grass, &(Enum.slice(&1, 4, 2) == ["leaf", "Tall grass"]))
    assert header.ground == "grass"

    rows = :boids.snapshot(scene.space, :local)
    assert Enum.frequencies_by(rows, & &1.group) == %{deer: 22, guards: 2, fox: 1}

    status = status(scene)
    assert [["Field", 1], ["Time", _], ["Afraid", 0], ["Most afraid", 0]] = status.r
    assert status.x.state == :sneaking and status.x.fields == 3 and status.x.limit == 6

    # A moment of the scene is JSON for the page.
    moment = Scene.frame(scene, 1)
    assert length(moment.b) == 25 * 6
    assert is_binary(IO.iodata_to_binary(:json.encode(moment)))
  end

  test "the fields have more deer, less grass and more guards" do
    [one, two, three] = Director.fields()
    assert one.deer < two.deer and two.deer < three.deer
    assert length(one.grass) > length(two.grass) and length(two.grass) > length(three.grass)
    assert length(one.guards) < length(two.guards) and length(two.guards) < length(three.guards)
    assert one.limit > two.limit and two.limit >= three.limit
    # A field has 60 boids at most.
    assert three.deer + length(three.guards) + 1 <= 60
  end

  test "the distance of alarm grows with the speed of the fox, and the grass makes it small" do
    assert Herd.alarm(%{speed: 0.0, hidden: false}) == 5.0
    assert Herd.alarm(%{speed: 5.0, hidden: false}) == 10.5
    assert Herd.alarm(%{speed: 14.0, hidden: false}) > 20
    assert Herd.alarm(%{speed: 14.0, hidden: true}) == 4.0
    assert Herd.in_grass?({10, 10}, [{0, 0, 20, 20}])
    refute Herd.in_grass?({30, 10}, [{0, 0, 20, 20}])
  end

  test "one afraid deer makes a wave: the fear goes from deer to deer" do
    scene = run(Map.merge(@quiet, %{deer: herd({60, 40})}))
    assert afraid(scene) == 0
    # The first deer of the group flees through the group.
    first = Enum.min_by(deer(scene), &elem(&1.pos, 0))
    scare(scene, first, {50.0, 43.0})

    wait(fn -> status(scene).x.most >= 4 end, "wave")
    # The fox is far: the fear of the other deer comes from their neighbors.
    fox = Enum.find(:boids.snapshot(scene.space, :local), &(&1.group == :fox))
    assert :boids_vec.dist(fox.pos, {60, 40}) > 40
    hops = for %{data: %{fear: :afraid, hop: hop}} <- deer(scene), do: hop
    assert Enum.any?(hops, &(&1 >= 1))
  end

  test "a fox that walks at a distance makes no fear, and a fox that runs near makes a wave" do
    scene = run(Map.merge(@quiet, %{deer: herd({60, 44}), fox: {36.0, 22.0}}))
    Director.input(scene.director, %{"keys" => ["right"]})
    Process.sleep(3000)
    assert status(scene).x.most == 0
    assert Enum.all?(deer(scene), &(&1.data.fear == :calm))

    # The same fox runs: the deer notice it from far away.
    Director.input(scene.director, %{"keys" => ["right", "run", "up", "nothing"]})
    wait(fn -> status(scene).x.most >= 3 end, "fear of a fox that runs")
  end

  test "an afraid deer calms down after some seconds" do
    scene = run(Map.merge(@quiet, %{deer: [{80.0, 45.0}]}))
    [one] = deer(scene)
    scare(scene, one, {70.0, 45.0})
    wait(fn -> afraid(scene) == 1 end, "afraid deer")
    assert [%{data: %{fear: :afraid, from: {70.0, 45.0}, hop: 0}}] = deer(scene)
    # The page draws it with the look of an afraid deer.
    assert {2, _angle, 0} = Herd.look(scene, hd(deer(scene)))
    wait(fn -> afraid(scene) == 0 end, "calm deer")
    assert [%{data: %{fear: :calm}}] = deer(scene)
  end

  test "the alarm calls the guards to the place of the fear, and a guard that touches the fox ends the try" do
    scene = run(%{deer: herd({60, 30}), guards: [{130.0, 60.0}], limit: 2, fox: {100.0, 60.0}})
    Process.sleep(1000)
    # The guard rests far from the fox, and does not see it.
    assert status(scene).x.state == :sneaking
    assert status(scene).x.alarms == 0

    first = Enum.min_by(deer(scene), &elem(&1.pos, 0))
    scare(scene, first, {100.0, 60.0})
    wait(fn -> status(scene).x.alarms >= 1 end, "alarm")
    status = wait(fn -> (status(scene).x.state == :caught && status(scene)) || nil end, "capture")
    assert status.x.time > 0

    # Keys do nothing after the end of the try.
    Director.input(scene.director, %{"keys" => ["left"]})
    assert status(scene).x.state == :caught
  end

  test "in the tall grass, a deer sees the fox only when it is very near" do
    # The fox walks up, 9 units from a deer.
    options = Map.merge(@quiet, %{deer: [{63.0, 45.0}], fox: {54.0, 38.0}})

    noticed = fn grass ->
      scene = run(Map.put(options, :grass, grass))
      Director.input(scene.director, %{"keys" => ["up"]})

      seen =
        Enum.reduce(1..40, false, fn _, seen ->
          Process.sleep(50)
          seen or Enum.any?(deer(scene), &(&1.data.fear != :calm))
        end)

      Scene.stop(scene)
      seen
    end

    refute noticed.([{48, 20, 58, 70}])
    assert noticed.([])
  end

  test "the far side ends the field, and go starts the next field or the same field again" do
    scene = run(%{guards: [], deer: [], fox: {148.0, 45.0}})
    Director.input(scene.director, %{"keys" => ["right"]})
    status = wait(fn -> (status(scene).x.state == :done && status(scene)) || nil end, "end of the field")
    assert status.x.field == 1 and status.x.time > 0
    # The fox stops at the far side.
    Director.input(scene.director, %{"keys" => ["left"]})
    Process.sleep(300)
    fox = Enum.find(:boids.snapshot(scene.space, :local), &(&1.group == :fox))
    assert elem(fox.pos, 0) >= Herd.goal()

    Director.input(scene.director, %{"go" => true})
    status = status(scene)
    assert status.x.field == 2 and status.x.state == :sneaking
    assert [["Field", 2] | _] = status.r

    # After the last field, go starts the first field.
    for field <- [3, 1] do
      Director.input(scene.director, %{"keys" => ["right"]})
      wait(fn -> status(scene).x.state == :done end, "end of the field")
      Director.input(scene.director, %{"go" => true})
      assert status(scene).x.field == field
    end
  end

  test "after a capture, go starts the same field again" do
    scene = run(%{deer: [], guards: [{102.0, 45.0}], fox: {100.0, 45.0}})
    # A guard that rests sees a fox near it.
    wait(fn -> status(scene).x.state == :caught end, "capture")
    Director.input(scene.director, %{"go" => true})
    status = status(scene)
    assert status.x.field == 1 and status.x.state == :sneaking and status.x.most == 0
  end
end
