defmodule BoidsExamples.DeepReefTest do
  # The game Deep Reef: the schools, the predator, the confusion effect,
  # the stamina, the time, the small schools that join, and the new fish.
  use ExUnit.Case, async: false
  alias BoidsExamples.Scene
  alias BoidsExamples.Games.DeepReef, as: Reef
  alias BoidsExamples.Games.DeepReef.Director

  # Start a hunt in a process of its own, as a visitor. The hunt stops
  # with that process.
  defp run(options) do
    test = self()

    pid =
      spawn(fn ->
        send(test, {:scene, Scene.start(Reef, options)})
        Process.sleep(:infinity)
      end)

    assert_receive {:scene, {:ok, scene}}, 5000

    # The test ends when the scene stopped, so that the next test counts
    # no scene of this test.
    on_exit(fn ->
      ref = Process.monitor(scene.guard)
      Process.exit(pid, :kill)

      receive do
        {:DOWN, ^ref, :process, _pid, _reason} -> :ok
      after
        5000 -> :ok
      end
    end)

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
  defp fish(scene), do: for(%{group: :fish} = row <- :boids.snapshot(scene.space, :local), do: row)
  defp predator(scene), do: Enum.find(:boids.snapshot(scene.space, :local), &(&1.group == :predator))

  defp reading(scene, label),
    do:
      Enum.find_value(status(scene).r, fn
        [^label, value] -> value
        _ -> nil
      end)

  defp keys(scene, names), do: Scene.input(scene, %{"keys" => names})

  # A school that cannot reach the predator, far from it: the hunt has no
  # catch by chance.
  @far %{schools: [{{20, 15}, 6}], predator: {140.0, 80.0}, every: 0}

  test "a reef has rocks, four schools of fish and the predator" do
    scene = run(%{every: 0})
    header = Scene.header(scene)
    assert header.box == [160, 90]
    assert Enum.map(header.kinds, & &1.name) == ["fish", "predator"]
    assert length(header.rocks) == length(Reef.rocks())
    assert length(fish(scene)) == 40
    assert %{group: :predator, data: %{stamina: 100.0}} = predator(scene)

    wait(fn -> reading(scene, "Schools") >= 3 end, "schools")
    %{x: x} = status(scene)
    assert %{state: :hunting, caught: 0, misses: 0} = x
    assert x.time in 89..90
  end

  test "the chance of a catch falls with the fish near the target" do
    assert Reef.chance(0) == 1.0
    assert Reef.chance(1) == 1.0
    assert Reef.chance(8) == 0.1
    assert Reef.chance(20) == 0.1
    chances = Enum.map(1..8, &Reef.chance/1)
    assert chances == Enum.sort(chances, :desc)
    assert_in_delta Reef.chance(4), 0.614, 0.01
  end

  test "the target is the nearest fish that the predator touches, with the fish near it" do
    neighbor = fn id, offset, group ->
      %{id: id, group: group, offset: offset, dist: :boids_vec.norm(offset)}
    end

    assert Reef.target([]) == nil
    assert Reef.target([neighbor.(:far, {5.0, 0.0}, :fish)]) == nil
    # A rock or another kind of boid is not a fish.
    assert Reef.target([neighbor.(:other, {1.0, 0.0}, :predator)]) == nil

    school = [
      neighbor.(:a, {1.5, 0.0}, :fish),
      neighbor.(:b, {1.0, 0.0}, :fish),
      neighbor.(:c, {3.0, 2.0}, :fish),
      neighbor.(:d, {9.0, 0.0}, :fish)
    ]

    # The target is b; a and c are near b, and d is far from b.
    assert {%{id: :b}, 2} = Reef.target(school)
  end

  test "the predator catches a fish that is alone, and the fish stops" do
    scene = run(Map.merge(@far, %{schools: [{{80, 80}, 1}], predator: {78.6, 80.0}, roll: 0.99}))
    [%{id: id}] = fish(scene)
    pid = :boids.whereis(scene.space, id)
    ref = Process.monitor(pid)
    wait(fn -> status(scene).x.caught == 1 end, "catch")
    assert_receive {:DOWN, ^ref, :process, ^pid, :normal}, 2000
    assert fish(scene) == []
    assert status(scene).x.misses == 0
  end

  test "a fish in a tight school confuses the predator: a miss" do
    # The predator is in the middle of a school of 9 fish. With the roll
    # 0.5, a catch needs a chance of one half or more.
    scene = run(Map.merge(@far, %{schools: [{{80, 80}, 9}], predator: {80.0, 80.0}, roll: 0.5}))
    wait(fn -> status(scene).x.misses >= 1 end, "miss")
    assert status(scene).x.caught == 0
    # After a try, the predator waits before the next try.
    assert status(scene).x.misses <= 2
  end

  test "the keys move the predator, and a burst uses the stamina" do
    scene = run(@far)
    %{pos: {x0, _}} = predator(scene)
    keys(scene, ["left", "nothing", 7])
    wait(fn -> elem(predator(scene).pos, 0) < x0 - 3 end, "move to the left")

    keys(scene, ["left", "burst"])
    wait(fn -> predator(scene).data.burst end, "burst")
    wait(fn -> predator(scene).data.stamina < 80 end, "use of the stamina")
    wait(fn -> status(scene).x.thrust end, "flame of a burst")

    # With no key, the predator slows down and gets its stamina back.
    keys(scene, [])
    low = predator(scene).data.stamina
    wait(fn -> predator(scene).data.stamina > low + 5 and not predator(scene).data.burst end, "rest")
    wait(fn -> :boids_vec.norm(predator(scene).vel) < 1.0 end, "stop")
  end

  test "the predator stays out of the rocks and in the reef" do
    {_id, {cx, cy}, radius} = Enum.find(Reef.rocks(), &(elem(&1, 0) == :middle))
    scene = run(Map.merge(@far, %{predator: {cx - radius - 4.0, cy * 1.0}}))
    keys(scene, ["right"])
    Process.sleep(1500)
    %{pos: pos} = predator(scene)
    assert :boids_vec.dist(pos, {cx, cy}) >= radius + 0.9

    keys(scene, ["down", "burst"])
    wait(fn -> elem(predator(scene).pos, 1) <= 1.0 end, "the bottom of the reef")
    Process.sleep(500)
    assert elem(predator(scene).pos, 1) >= 1.0
  end

  test "the hunt ends after its time, and go starts a new hunt" do
    scene = run(Map.merge(@far, %{seconds: 1}))
    keys(scene, ["up"])
    wait(fn -> status(scene).x.state == :over end, "end of the hunt")
    %{x: x, r: r} = status(scene)
    assert x.time == 0 and ["Time", "0 s"] in r

    # The predator stops at the end, and the keys change nothing.
    keys(scene, ["left", "burst"])
    Process.sleep(600)
    assert :boids_vec.norm(predator(scene).vel) < 1.0

    # A go during a hunt changes nothing; after the end, a new hunt starts.
    old = predator(scene).id
    Scene.input(scene, %{"go" => true})
    wait(fn -> status(scene).x.state == :hunting end, "new hunt")
    assert predator(scene).id != old
    assert length(fish(scene)) == 6
  end

  test "the best score stays from hunt to hunt" do
    scene = run(Map.merge(@far, %{schools: [{{80, 80}, 1}], predator: {78.6, 80.0}, roll: 0.0, seconds: 1}))
    wait(fn -> status(scene).x.state == :over end, "end of the hunt")
    assert %{caught: 1, best: 1} = status(scene).x
    Scene.input(scene, %{"go" => true})
    wait(fn -> status(scene).x.state == :hunting end, "new hunt")
    assert %{caught: 0, best: 1} = status(scene).x
  end

  test "a small school goes to a larger school" do
    # Two fish far from a school of 10.
    scene = run(Map.merge(@far, %{schools: [{{30, 45}, 10}, {{130, 45}, 2}]}))
    [small | _] = Enum.filter(fish(scene), &(elem(&1.pos, 0) > 100))
    distance = fn -> :boids_vec.dist(:boids.lookup(scene.space, small.id) |> elem(1) |> Map.get(:pos), {30, 45}) end
    start = distance.()
    wait(fn -> distance.() < start - 30 end, "move to the larger school", 400)
  end

  test "the schools come from boids:flocks/2" do
    scene = run(Map.merge(@far, %{schools: [{{30, 20}, 5}, {{130, 70}, 5}]}))
    schools = Director.schools(scene.space)
    assert length(schools) == 2
    assert Enum.sort(Enum.map(schools, &length/1)) == [5, 5]
  end

  test "new schools come in at a side of the reef" do
    scene = run(Map.merge(@far, %{every: 1}))
    wait(fn -> length(fish(scene)) >= 11 end, "new school")
    assert length(fish(scene)) <= 16
  end
end
