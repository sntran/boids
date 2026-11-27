defmodule BoidsExamples.FireflyFieldTest do
  # The game Firefly Field: the clock of a firefly, the sync of a group,
  # the lantern, the homes, the wind, the dawn and the levels.
  use ExUnit.Case, async: false
  alias BoidsExamples.Scene
  alias BoidsExamples.Games.FireflyField, as: Field
  alias BoidsExamples.Games.FireflyField.Director

  # Start a night in a process of its own, as a visitor. The night stops
  # with that process.
  defp run(options) do
    test = self()

    pid =
      spawn(fn ->
        send(test, {:scene, Scene.start(Field, options)})
        Process.sleep(:infinity)
      end)

    on_exit(fn -> Process.exit(pid, :kill) end)
    assert_receive {:scene, {:ok, scene}}, 5000
    scene
  end

  # Wait until the function gives a true value, for `seconds` at most.
  defp wait(fun, what, seconds \\ 10), do: wait(fun, what, seconds, seconds * 20)

  defp wait(fun, what, seconds, tries) do
    case fun.() do
      value when value in [false, nil] ->
        if tries == 0, do: flunk("No #{what} in #{seconds} seconds.")
        Process.sleep(50)
        wait(fun, what, seconds, tries - 1)

      value ->
        value
    end
  end

  defp status(scene), do: Director.status(scene.director).x
  defp fireflies(scene), do: :boids.snapshot(scene.space, :local)

  defp center(rows) do
    :boids_vec.scale(Enum.reduce(rows, {0.0, 0.0}, &:boids_vec.add(&1.pos, &2)), 1 / length(rows))
  end

  describe "the clock of a firefly" do
    test "grows with the time, and flashes at its end" do
      assert {0.25, false} = Field.next_clock(0.0, 0.5, 2.0, 0)
      assert {+0.0, true} = Field.next_clock(0.9, 0.5, 2.0, 0)
    end

    test "goes forward when the neighbors flash, but not just after a flash" do
      # Each flash multiplies the clock by 1.1.
      {clock, false} = Field.next_clock(0.5, 0.0, 2.0, 2)
      assert_in_delta clock, 0.6, 1.0e-9
      # Just after its flash, a firefly does not see the flashes.
      assert {0.1, false} = Field.next_clock(0.1, 0.0, 2.0, 3)
      # Many flashes count as five.
      {many, false} = Field.next_clock(0.3, 0.0, 2.0, 40)
      assert_in_delta many, 0.45, 1.0e-9
      # A firefly near its flash flashes with its neighbors.
      assert {+0.0, true} = Field.next_clock(0.9, 0.0, 2.0, 2)
    end

    test "moves a clock near its flash more than a clock far from its flash" do
      # So two parts of a group that flash at different times come together.
      {early, false} = Field.next_clock(0.4, 0.0, 2.0, 1)
      {late, false} = Field.next_clock(0.8, 0.0, 2.0, 1)
      assert late - 0.8 > 1.5 * (early - 0.4)
    end

    test "a wave of flashes from neighbor to neighbor is one flash of the field, but a long chain is not" do
      w = Field.window()
      assert Field.same_flash?(0, 0, w)
      refute Field.same_flash?(0, 0, w + 1)
      # A wave: each flash comes soon after the last flash.
      assert Field.same_flash?(0, 3 * w, 4 * w)
      # One flash of the field is at most four windows long.
      refute Field.same_flash?(0, 4 * w, 4 * w + 1)
    end

    test "gives the light of a firefly: bright at its flash, and dark after 0.7 second" do
      assert Field.light(%{flash: 1000}, 1000) == 10
      assert Field.light(%{flash: 1000}, 1350) == 5
      assert Field.light(%{flash: 1000}, 1800) == 0
      assert Field.light(%{flash: nil}, 1000) == 0
    end
  end

  test "the levels have their groups, a dawn, and at most 60 fireflies" do
    levels = Field.levels()
    assert length(levels) == 5

    for level <- levels do
      assert level.title != "" and level.dawn >= 60
      total = Enum.sum(for {_point, count, _factor} <- level.groups, do: count)
      assert total >= 6 and total <= 60
      assert length(level.groups) >= 2
    end

    assert Enum.any?(levels, & &1.wind)
    assert Enum.any?(levels, fn level -> Enum.any?(level.groups, fn {_point, _count, factor} -> factor >= 1.25 end) end)
  end

  test "the lantern starts far from the groups" do
    points = [{42.0, 46.0}, {118.0, 44.0}]
    spot = Field.away(points)
    assert Enum.all?(points, &(:boids_vec.dist(spot, &1) > Field.radius()))
  end

  test "a group of fireflies that see each other comes to flash together, and the level is done" do
    scene = run(%{groups: [{{80, 45}, 6, 1.0}], dawn: 90})
    assert status(scene).total == 6
    assert status(scene).state == :night
    # One group: all the fireflies flash together, three times in a row.
    assert wait(fn -> status(scene).state == :done end, "three flashes of all the fireflies", 40)
    done = status(scene)
    assert done.streak >= 3 and done.last == 6 and done.best == 6
  end

  test "two groups far apart do not flash together three times in a row before the dawn" do
    scene = run(%{groups: [{{20, 20}, 5, 1.0}, {{140, 70}, 5, 1.2}], dawn: 12})
    assert wait(fn -> status(scene).state == :dawn end, "dawn", 20)
    at_dawn = status(scene)
    assert at_dawn.streak < 3
    assert at_dawn.groups == 2
    assert at_dawn.dawn == 0
  end

  test "the fireflies in the light of the lantern follow it, and stay where it leaves them" do
    scene = run(%{groups: [{{40, 45}, 6, 1.0}], lantern: {58.0, 45.0}, dawn: 90})
    {x0, _} = center(fireflies(scene))
    # The fireflies fly to the lantern.
    assert wait(fn -> elem(center(fireflies(scene)), 0) > x0 + 10 end, "fireflies at the lantern")
    # The lantern takes them farther, to the right.
    Director.input(scene.director, %{"lantern" => [90, 45]})
    assert wait(fn -> elem(center(fireflies(scene)), 0) > 80 end, "fireflies that follow the lantern", 20)
    # A fast move far away: the lantern leaves them, and they stay near
    # the place where it left them.
    left = center(fireflies(scene))
    Director.input(scene.director, %{"keys" => ["fast"]})
    Director.input(scene.director, %{"lantern" => [20, 85]})
    assert wait(fn -> status(scene).lantern == [20.0, 85.0] end, "the lantern far away", 20)
    Process.sleep(4000)
    {x, _} = now = center(fireflies(scene))
    assert x > 60
    assert :boids_vec.dist(now, left) < 14
  end

  test "the keys and a point of the field move the lantern; other input changes nothing" do
    # Two groups far apart: the level is not done during the test.
    scene = run(%{groups: [{{20, 20}, 2, 1.0}, {{140, 80}, 2, 1.3}], lantern: {80.0, 45.0}, dawn: 90})
    Director.input(scene.director, %{"keys" => ["right", "up", "jump"]})
    assert wait(fn -> match?([x, y] when x > 81 and y > 46, status(scene).lantern) end, "the lantern that moves")
    Director.input(scene.director, %{"keys" => []})
    Process.sleep(200)
    stopped = status(scene).lantern
    Process.sleep(300)
    assert status(scene).lantern == stopped

    # The key fast makes the lantern faster.
    [x0, _] = status(scene).lantern
    Director.input(scene.director, %{"keys" => ["left"]})
    Process.sleep(1000)
    [x1, _] = status(scene).lantern
    Director.input(scene.director, %{"keys" => ["left", "fast"]})
    Process.sleep(1000)
    [x2, _] = status(scene).lantern
    Director.input(scene.director, %{"keys" => []})
    assert x1 - x2 > 1.8 * (x0 - x1)

    # A point of the field: the lantern goes there, and stays in the field.
    Director.input(scene.director, %{"lantern" => [300, -40]})
    assert wait(fn -> status(scene).lantern == [158.0, 2.0] end, "the lantern at the edge", 30)

    for bad <- [%{"lantern" => ["a", 1]}, %{"lantern" => [1]}, %{"keys" => "left"}, %{"go" => true}, %{"other" => 1}] do
      Director.input(scene.director, bad)
    end

    Process.sleep(200)
    assert status(scene).lantern == [158.0, 2.0]
    assert status(scene).state == :night
  end

  test "at the dawn the night ends, and the person tries the same level again" do
    scene = run(%{level: 2, groups: [{{20, 20}, 3, 1.0}, {{140, 70}, 3, 1.2}], dawn: 1})
    assert wait(fn -> status(scene).state == :dawn end, "dawn")
    Director.input(scene.director, %{"go" => true})
    assert wait(fn -> status(scene).state == :night end, "a new night")
    assert status(scene).level == 2
  end

  test "after a level that is done, the next level starts; after the last level, the first" do
    # The lantern is on the group, so the wind of level 5 does not move
    # the fireflies apart.
    scene = run(%{level: 4, groups: [{{80, 45}, 6, 1.0}], lantern: {80.0, 45.0}, dawn: 90})
    assert wait(fn -> status(scene).state == :done end, "level 4 done", 40)
    Director.input(scene.director, %{"go" => true})
    assert wait(fn -> status(scene).level == 5 end, "level 5")
    assert status(scene).title == "Far apart"
    assert wait(fn -> status(scene).state == :done end, "level 5 done", 40)
    Director.input(scene.director, %{"go" => true})
    assert wait(fn -> status(scene).level == 1 end, "level 1")
  end

  test "the wind turns, and the fireflies of a windy level have the rule flow" do
    scene = run(%{level: 3, groups: [{{80, 45}, 4, 1.0}], dawn: 90})
    assert status(scene).wind == true
    id = hd(fireflies(scene)).id
    {:ok, boid} = :boids.boid(scene.space, id)
    assert :flow in :gen_boid.which_rules(:boids.whereis(scene.space, id))
    assert boid.group == :fireflies
    assert wait(fn -> :ets.lookup_element(boid.state.table, :wind, 2) != {0.0, 0.0} end, "wind")
  end

  test "the page draws each firefly with its light, and the slow clocks in their own color" do
    scene = run(%{groups: [{{40, 45}, 3, 1.0}, {{120, 45}, 3, 1.3}], dawn: 90})
    looks = for row <- fireflies(scene), do: Field.look(scene, row)
    assert Enum.sort(Enum.uniq(for {kind, _angle, _light} <- looks, do: kind)) == [0, 1]
    assert Enum.all?(looks, fn {_kind, _angle, light} -> light in 0..10 end)
    # A firefly that flashed now is bright.
    now = System.monotonic_time(:millisecond)
    assert {0, _, 10} = Field.look(scene, %{data: %{slow: false, flash: now}, vel: {1.0, 0.0}})
    assert Field.header(scene) == %{ground: "night"}
    assert [%{shape: "firefly"}, %{shape: "firefly", color: "plum"}] = Field.kinds(scene)

    readings = Director.status(scene.director).r
    assert Enum.map(readings, &hd/1) == ["Level", "Groups", "Last flash", "Best", "Dawn in"]
  end
end
