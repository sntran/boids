defmodule BoidsExamples.NightFoldTest do
  # The game Night Fold: the sheep flee from the dog, the fold keeps them,
  # the wolves come at night, and the fields.
  use ExUnit.Case, async: false
  alias BoidsExamples.Scene
  alias BoidsExamples.Games.NightFold, as: Fold
  alias BoidsExamples.Games.NightFold.Director

  # Start a field in a process of its own, as a visitor. The field stops
  # with that process.
  defp run(options) do
    test = self()

    pid =
      spawn(fn ->
        send(test, {:scene, Scene.start(Fold, options)})
        Process.sleep(:infinity)
      end)

    assert_receive {:scene, {:ok, scene}}, 5000

    # The field stops before the next test, so the count of the scenes is
    # right for it.
    on_exit(fn ->
      Scene.stop(scene)
      Process.exit(pid, :kill)
    end)

    scene
  end

  # Wait until the function gives a true value, for 15 seconds at most.
  defp wait(fun, what, tries \\ 300) do
    case fun.() do
      value when value in [false, nil] ->
        if tries == 0, do: flunk("No #{what} in 15 seconds.")
        Process.sleep(50)
        wait(fun, what, tries - 1)

      value ->
        value
    end
  end

  defp status(scene), do: Director.status(scene.director)
  defp rows(scene), do: :boids.snapshot(scene.space, :local)
  defp group(scene, group), do: for(%{group: ^group} = row <- rows(scene), do: row)

  test "a field has the sheep, the dog, the fence of the fold with its opening, and the readings" do
    scene = run(%{})
    header = Scene.header(scene)
    assert header.box == [160, 90]
    assert Enum.map(header.kinds, & &1.name) == ["sheep", "sheep in the fold", "dog", "wolves"]
    assert header.zones == [[128, 30, 152, 60, "cool"]]
    assert length(header.rocks) == length(Fold.posts(20))

    assert Enum.frequencies_by(rows(scene), & &1.group) == %{sheep: 14, dog: 1}

    status = status(scene)

    assert [["Field", 1], ["In the fold", "0 of 14"], ["Lost", 0], ["Clock", clock], ["Flocks", _]] = status.r
    assert clock =~ ~r/^\d+ s to night$/

    assert status.x.phase == :day and status.x.fields == 3 and status.x.total == 14

    # A moment of the scene is JSON for the page.
    moment = Scene.frame(scene, 1)
    assert length(moment.b) == 15 * 6
    assert is_binary(IO.iodata_to_binary(:json.encode(moment)))
  end

  test "the fields have more sheep, a smaller opening, a shorter day and more wolves" do
    [one, two, three] = Director.fields()
    assert one.sheep < two.sheep and two.sheep < three.sheep
    assert one.opening > two.opening and two.opening > three.opening
    assert one.day > two.day and two.day > three.day
    assert one.wolves < two.wolves and two.wolves < three.wolves
    # A field has 60 boids at most.
    assert three.sheep + three.wolves + 1 <= 60
  end

  test "the fold has its opening in the wall at the left" do
    wide = Fold.posts(20)
    narrow = Fold.posts(10)
    assert length(narrow) > length(wide)
    front = fn posts -> for {128.0, y} <- posts, do: y end
    refute Enum.any?(front.(wide), &(abs(&1 - 45) < 10))
    assert Enum.any?(front.(wide), &(&1 < 35)) and Enum.any?(front.(wide), &(&1 > 55))
    assert Fold.in_fold?({140, 45})
    refute Fold.in_fold?({120, 45})
    refute Fold.in_fold?({140, 70})
  end

  test "a sheep goes into the fold only through the opening" do
    # Through the opening of 20, at the middle of the wall at the left.
    assert Fold.through_opening?({128.0, 45.0}, {131.0, 46.0}, 20)
    assert Fold.through_opening?({129.0, 37.0}, {130.0, 37.0}, 20)
    # Next to the opening, through the posts of the wall.
    refute Fold.through_opening?({129.0, 33.0}, {130.0, 33.0}, 20)
    refute Fold.through_opening?({129.0, 37.0}, {130.0, 37.0}, 10)
    # Through the wall at the top, or from inside to inside.
    refute Fold.through_opening?({140.0, 60.0}, {140.0, 57.0}, 20)
    refute Fold.through_opening?({135.0, 45.0}, {136.0, 45.0}, 20)
  end

  test "the fence stops a sheep that the dog pushes against the wall" do
    # A sheep above the fold, and the dog above it: the sheep flees down,
    # to the wall at the top of the fold.
    scene = run(%{sheep: [{140.0, 63.0}], dog: {140.0, 72.0}})
    Process.sleep(2500)
    assert [%{pos: {_, y}}] = group(scene, :sheep)
    assert y > 58.5
    assert status(scene).x.penned == 0
  end

  test "a sheep flees from the dog that is near it, and grazes slowly when the dog is far" do
    scene = run(%{sheep: [{60.0, 45.0}, {60.0, 80.0}], dog: {54.0, 45.0}})
    [near_id, far_id] = Enum.sort_by(group(scene, :sheep), &elem(&1.pos, 1)) |> Enum.map(& &1.id)

    wait(
      fn ->
        {:ok, near} = :boids.boid(scene.space, near_id)
        near.max_speed == 8.0 and elem(near.pos, 0) > 63
      end,
      "sheep that flees from the dog"
    )

    {:ok, far} = :boids.boid(scene.space, far_id)
    assert far.max_speed == 2.2
  end

  test "the keys move the dog, and other keys change nothing" do
    scene = run(%{sheep: [{100.0, 80.0}], dog: {20.0, 45.0}})
    Scene.input(scene, %{"keys" => ["right", "run", "fly"]})
    Scene.input(scene, %{"keys" => "not a list"})
    Scene.input(scene, %{"other" => 1})

    wait(fn -> match?([%{pos: {x, _}}] when x > 30, group(scene, :dog)) end, "dog that moves")
    assert status(scene).x.thrust or elem(hd(group(scene, :dog)).pos, 0) > 30

    # With no key, the dog stops.
    Scene.input(scene, %{"keys" => []})
    wait(fn -> :boids_vec.norm(hd(group(scene, :dog)).vel) < 0.5 end, "dog that stops")
  end

  test "a sheep inside the walls stays in the fold, and the fold counts it" do
    scene = run(%{sheep: [{140.0, 45.0}, {40.0, 20.0}], dog: {10.0, 80.0}})
    wait(fn -> status(scene).x.penned == 1 end, "sheep in the fold")
    [penned] = group(scene, :penned)
    assert Fold.in_fold?(penned.pos)
    assert ["In the fold", "1 of 2"] in status(scene).r

    Process.sleep(1500)
    assert [%{pos: pos}] = group(scene, :penned)
    assert Fold.in_fold?(pos)
  end

  test "the flocks count the groups of sheep outside the fold" do
    scene = run(%{sheep: [{30.0, 20.0}, {32.0, 20.0}, {30.0, 70.0}, {32.0, 70.0}, {140.0, 45.0}], dog: {10.0, 85.0}})
    wait(fn -> status(scene).x.flocks == 2 end, "two flocks")
  end

  test "at night the wolves come, and a wolf takes a sheep outside the fold but not a sheep in it" do
    scene =
      run(%{
        sheep: [{60.0, 45.0}, {140.0, 45.0}],
        dog: {10.0, 85.0},
        day: 0,
        night: 20,
        wolves: [{60.0, 46.0}, {140.0, 47.0}]
      })

    wait(fn -> status(scene).x.phase == :night end, "night")
    assert length(group(scene, :wolves)) == 2
    assert ["Clock", clock] = Enum.at(status(scene).r, 3)
    assert clock =~ ~r/^\d+ s to dawn$/
    assert [[0, 0, 160, 90, "rock"], _] = status(scene).h.zones

    wait(fn -> status(scene).x.lost == 1 end, "sheep that a wolf takes")
    assert group(scene, :sheep) == []
    assert [_] = group(scene, :penned)

    # No sheep is outside the fold: the field is done, and the wolves go.
    wait(fn -> status(scene).x.phase == :done end, "end of the field")
    assert group(scene, :wolves) == []
    assert status(scene).x.pass
  end

  test "the dawn ends the field: with less than half of the sheep in the fold, go starts it again" do
    scene = run(%{sheep: [{40.0, 20.0}, {40.0, 70.0}], dog: {10.0, 85.0}, day: 0, night: 1, wolves: []})
    wait(fn -> status(scene).x.phase == :done end, "dawn")
    refute status(scene).x.pass
    assert [["Field", 1] | _] = status(scene).r
    assert ["Clock", "Done"] in status(scene).r

    Scene.input(scene, %{"go" => true})
    wait(fn -> status(scene).x.phase == :day end, "same field again")
    assert status(scene).x.field == 1
  end

  test "all the sheep in the fold end the field, and go starts the next field" do
    scene = run(%{sheep: [{140.0, 40.0}, {140.0, 50.0}], dog: {10.0, 85.0}})
    wait(fn -> status(scene).x.phase == :done end, "end of the field")
    assert status(scene).x.pass and status(scene).x.penned == 2
    # The keys change nothing after the end.
    Scene.input(scene, %{"keys" => ["right"]})

    Scene.input(scene, %{"go" => true})
    wait(fn -> status(scene).x.field == 2 end, "next field")
    assert status(scene).x.phase == :day
    assert length(Scene.header(scene).rocks) == length(Fold.posts(14))
    # Field 2 has its own sheep: the sheep of the test are only in field 1.
    assert status(scene).x.total == 2
  end

  test "after the last field, go starts the first field" do
    scene = run(%{field: 3, sheep: [{140.0, 45.0}], dog: {10.0, 85.0}})
    wait(fn -> status(scene).x.phase == :done end, "end of the field")
    Scene.input(scene, %{"go" => true})
    wait(fn -> status(scene).x.field == 1 end, "first field")
  end
end
