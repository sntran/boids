defmodule BoidsExamples.ExitPlanTest do
  # The game Exit Plan: the rules that are functions, the people, the
  # director of a level, and the effect of a plan on the crowd.
  use ExUnit.Case, async: false
  alias BoidsExamples.Games.ExitPlan
  alias BoidsExamples.Games.ExitPlan.{Director, Person}

  @hall {110, 66}

  # A level with the manual clock: the boids move only with
  # Director.advance/2.
  defp level(options) do
    {:ok, scene} = ExitPlan.start(Map.merge(%{manual: true}, options))
    on_exit(fn -> :boids.stop_world(scene.space) end)
    scene
  end

  # A world with the manual clock, for people of the test.
  defp world do
    {:ok, world} = :boids.start_world(bounds: {{0, 0}, @hall}, wrap: false, defaults: %{tick: :manual})
    on_exit(fn -> :boids.stop_world(world) end)
    :boids.space(world)
  end

  # A person of the test. The test process is its director.
  defp person(space, pos, doors) do
    id = make_ref()
    {:ok, pid} = :gen_boid.start(space, Person, %{id: id, pos: pos, director: self(), hall: @hall, doors: doors})
    {id, pid}
  end

  defp steps(space, count), do: for(_ <- 1..count, do: :ok = :boids.step(space, 0.05))

  defp body(pos, vel, more \\ %{}) do
    Map.merge(
      %{pos: pos, vel: vel, max_speed: 6.0, state: %{hall: @hall, doors: [{:right, 31, 35}], signs: [], hint: nil}},
      more
    )
  end

  describe "the levels" do
    test "each level has doors in its walls, people in its hall, and a plan to make" do
      assert length(ExitPlan.levels()) == 5

      for level <- ExitPlan.levels() do
        assert level.hall == @hall
        assert level.people <= 60
        assert level.pillars >= 1 or level.signs >= 1
        assert level.good < level.limit
        {x0, y0, x1, y1} = level.area
        assert x0 >= 0 and y0 >= 0 and x1 <= 110 and y1 <= 66

        for {wall, a, b} <- level.doors do
          assert wall in [:left, :right, :top, :bottom]
          assert a < b and a >= 0 and b <= if(wall in [:left, :right], do: 66, else: 110)
        end
      end
    end

    test "the description of the game" do
      info = ExitPlan.info()
      assert info.slug == "exit-plan" and info.title == "Exit Plan" and info.tag == "Puzzle"
    end
  end

  describe "the rules that are functions" do
    test "the walls push a person to the inside, but not in front of a door" do
      {fx, _} = ExitPlan.walls(body({0.5, 10.0}, {0.0, 0.0}), [], %{})
      assert fx > 0
      {fx, _} = ExitPlan.walls(body({109.5, 10.0}, {0.0, 0.0}), [], %{})
      assert fx < 0
      {_, fy} = ExitPlan.walls(body({50.0, 65.5}, {0.0, 0.0}), [], %{})
      assert fy < 0
      # In front of the door of the right wall, the wall does not push.
      assert ExitPlan.walls(body({109.5, 33.0}, {0.0, 0.0}), [], %{}) == {0.0, 0.0}
      # In the middle of the hall, no wall pushes.
      assert ExitPlan.walls(body({50.0, 30.0}, {1.0, 0.0}), [], %{}) == {0.0, 0.0}
    end

    test "a sign pushes a person in its zone in the direction of its arrow" do
      signs = [%{x: 50.0, y: 30.0, dir: "left"}, %{x: 80.0, y: 30.0, dir: "up"}]
      state = %{hall: @hall, doors: [], signs: signs, hint: nil}
      {fx, fy} = ExitPlan.sign(body({52.0, 31.0}, {0.0, 0.0}, %{state: state}), [], %{})
      assert fx < 0 and abs(fy) < 1.0e-9
      {fx, fy} = ExitPlan.sign(body({80.0, 30.0}, {0.0, 0.0}, %{state: state}), [], %{})
      assert fy > 0 and abs(fx) < 1.0e-9
      assert ExitPlan.sign(body({20.0, 20.0}, {0.0, 0.0}, %{state: state}), [], %{}) == {0.0, 0.0}
    end

    test "a person goes to the nearest door, or to the nearest door in the direction of a sign" do
      doors = [{:right, 31, 35}, {:left, 31, 35}]
      assert ExitPlan.door_of({80.0, 33.0}, doors, @hall, nil) == {:right, 31, 35}
      assert ExitPlan.door_of({80.0, 33.0}, doors, @hall, "left") == {:left, 31, 35}
      # No door in the direction of the arrow: the nearest door.
      assert ExitPlan.door_of({80.0, 33.0}, doors, @hall, "up") == {:right, 31, 35}

      state = %{hall: @hall, doors: doors, signs: [], hint: "left"}
      {fx, _} = ExitPlan.to_door(body({80.0, 33.0}, {0.0, 0.0}, %{state: state}), [], %{})
      assert fx < 0
    end

    test "a position out of the hall in a door is at the door" do
      doors = [{:right, 31, 35}, {:left, 10, 18}, {:top, 54, 58}, {:bottom, 85, 88}]
      assert ExitPlan.at_door?({109.9, 33.0}, doors, @hall)
      assert ExitPlan.at_door?({0.1, 12.0}, doors, @hall)
      assert ExitPlan.at_door?({56.0, 65.9}, doors, @hall)
      assert ExitPlan.at_door?({86.0, 0.0}, doors, @hall)
      refute ExitPlan.at_door?({109.9, 20.0}, doors, @hall)
      refute ExitPlan.at_door?({50.0, 30.0}, doors, @hall)
    end
  end

  describe "a person" do
    test "walks slowly before the alarm, and goes out by a door after it" do
      space = world()
      {id, pid} = person(space, {100.0, 33.0}, [{:right, 31, 35}])
      steps(space, 20)
      {:ok, before} = :boids.boid(space, id)
      assert before.data == :waiting and before.max_speed <= 1.2

      :gen_boid.cast(pid, {:alarm, []})
      steps(space, 80)
      assert_received {:"$gen_cast", {:safe, ^id}}
      assert :boids.lookup(space, id) == :error
    end

    test "a person that passes a sign goes to the door in the direction of its arrow" do
      space = world()
      doors = [{:right, 31, 35}, {:left, 31, 35}]
      {id, pid} = person(space, {80.0, 33.0}, doors)
      :gen_boid.cast(pid, {:alarm, [%{x: 80.0, y: 33.0, dir: "left"}]})
      steps(space, 10)
      {:ok, boid} = :boids.boid(space, id)
      assert boid.state.hint == "left"
      steps(space, 20)
      {:ok, later} = :boids.boid(space, id)
      assert elem(later.pos, 0) < elem(boid.pos, 0)
    end

    test "a person in a crush for some time is hurt, stops, and stays on the floor" do
      space = world()
      # Ten people on one small place, and a door that is far.
      people = for n <- 1..10, do: person(space, {50.0 + rem(n, 3) * 0.3, 30.0 + div(n, 3) * 0.3}, [{:left, 31, 35}])
      for {_id, pid} <- people, do: :gen_boid.cast(pid, {:alarm, []})
      steps(space, 30)
      assert_received {:"$gen_cast", {:hurt, hurt}}
      {:ok, row} = :boids.lookup(space, hurt)
      assert row.group == :hurt and row.data == :hurt
      steps(space, 10)
      {:ok, still} = :boids.lookup(space, hurt)
      assert still.pos == row.pos
    end

    test "a person in a crowd walks slower" do
      space = world()
      people = for n <- 1..6, do: person(space, {50.0 + n * 0.6, 30.0}, [{:right, 31, 35}])
      {alone, pid} = person(space, {20.0, 50.0}, [{:right, 31, 35}])
      for {_id, p} <- [{alone, pid} | people], do: :gen_boid.cast(p, {:alarm, []})
      steps(space, 2)
      {:ok, free} = :boids.boid(space, alone)
      slow = for {id, _pid} <- people, {:ok, b} <- [:boids.boid(space, id)], do: b.max_speed
      assert free.max_speed == 6.0
      assert Enum.min(slow) < 6.0
    end
  end

  describe "the director" do
    test "the plan: pillars and signs to the limits of the level, remove, and clear" do
      %{space: space, director: d} = level(%{level: 2, people: 4})
      Director.input(d, %{"pillar" => [90, 33]})
      Director.input(d, %{"pillar" => [80, 20]})
      Director.input(d, %{"sign" => [70, 33, "left"]})
      Director.input(d, %{"sign" => [70, 20, "up"]})
      Director.input(d, %{"sign" => [60, 20, "up"]})
      Director.input(d, %{"sign" => [60, 50, "around"]})
      Director.input(d, %{"pillar" => [200, 33]})
      status = Director.status(d)
      # Level 2 has one pillar and two signs.
      assert status.x.pillars == 1 and status.h.rocks == [[90.0, 33.0, 2.5]]
      assert [%{pos: {90.0, 33.0}, radius: 2.5}] = :boids.obstacles(space)
      assert status.x.signs == [[70.0, 33.0, "left"], [70.0, 20.0, "up"]]
      assert Enum.count(status.h.zones, &(List.last(&1) == "warm")) == 2

      Director.input(d, %{"remove" => [90.5, 33.0]})
      assert Director.status(d).x.pillars == 0
      assert :boids.obstacles(space) == []
      Director.input(d, %{"remove" => [71, 34]})
      assert Director.status(d).x.signs == [[70.0, 20.0, "up"]]
      Director.input(d, %{"pillar" => [90, 33]})
      Director.input(d, %{"clear" => true})
      status = Director.status(d)
      assert status.x.pillars == 0 and status.x.signs == []
    end

    test "after the alarm, the plan does not change, and the level ends when the hall is empty" do
      %{director: d} = level(%{level: 1, people: 6})
      status = Director.status(d)
      assert status.x.phase == :planning
      assert ["In the hall", 6] in status.r

      Director.input(d, %{"alarm" => true})
      Director.input(d, %{"pillar" => [90, 33]})
      assert Director.status(d).x.phase == :leaving
      assert Director.status(d).x.pillars == 0

      status = Director.advance(d, 40.0)
      assert status.x.phase == :done
      assert status.x.safe + status.x.hurt == 6
      assert status.x.result.stars >= 1
      assert status.x.time > 0
      assert ["In the hall", 0] in status.r
    end

    test "a level that is not empty at the time limit gives no star" do
      %{director: d} = level(%{level: 1, people: 6, limit: 1.0})
      Director.input(d, %{"alarm" => true})
      status = Director.advance(d, 5.0)
      assert status.x.phase == :done
      assert status.x.result.stars == 0
      assert status.x.result.text =~ "The time is over"
    end

    test "again keeps the plan, next goes to the next level, and a level of the list" do
      %{director: d} = level(%{level: 2, people: 4})
      Director.input(d, %{"sign" => [70, 33, "left"]})
      Director.input(d, %{"alarm" => true})
      Director.advance(d, 40.0)
      Director.input(d, %{"again" => true})
      status = Director.status(d)
      assert status.x.phase == :planning and status.x.level == 2
      assert status.x.signs == [[70.0, 33.0, "left"]]

      Director.input(d, %{"next" => true})
      assert Director.status(d).x.level == 2
      Director.input(d, %{"alarm" => true})
      Director.advance(d, 40.0)
      Director.input(d, %{"next" => true})
      status = Director.status(d)
      assert status.x.level == 3 and status.x.signs == [] and status.x.phase == :planning

      Director.input(d, %{"level" => 5})
      assert Director.status(d).x.level == 5
      Director.input(d, %{"level" => 9})
      Director.input(d, %{"level" => "1"})
      Director.input(d, %{"other" => true})
      assert Director.status(d).x.level == 5
    end

    test "stars: one for all out, one for the time, one for no person hurt" do
      %{director: d} = level(%{level: 1, people: 3})
      Director.input(d, %{"alarm" => true})
      status = Director.advance(d, 40.0)
      %{stars: stars, text: text} = status.x.result

      cond do
        status.x.hurt == 0 and status.x.time <= 18.0 -> assert stars == 3 and text =~ "3 of 3"
        status.x.hurt == 0 -> assert stars == 2 and text =~ "All are safe"
        true -> assert stars < 3 and text =~ "hurt"
      end
    end
  end

  describe "the plan of the person" do
    # The hurt people of some runs of a level with a plan.
    defp hurt(level, plan, runs) do
      for _ <- 1..runs do
        %{space: space, director: d} = level(%{level: level})
        for message <- plan, do: Director.input(d, message)
        Director.input(d, %{"alarm" => true})
        status = Director.advance(d, 70.0)
        :boids.stop_world(space)
        assert status.x.phase == :done
        status.x.hurt
      end
    end

    @tag timeout: 300_000
    test "signs to the far door make the crush at the near door smaller" do
      none = hurt(2, [], 3)
      plan = hurt(2, [%{"sign" => [80, 20, "left"]}, %{"sign" => [80, 46, "left"]}], 3)
      assert Enum.sum(plan) < Enum.sum(none)
    end
  end

  describe "the scene" do
    test "the page gets the doors as zones, the people, and the readings" do
      scene = level(%{level: 3, people: 5})
      %{zones: zones} = ExitPlan.header(scene)
      assert length(zones) == 3 and Enum.all?(zones, &(List.last(&1) == "cool"))
      assert [%{name: "people"}, %{name: "hurt"}] = ExitPlan.kinds(scene)
      assert {0, _, 0} = ExitPlan.look(scene, %{group: :people, vel: {1.0, 0.0}})
      assert {1, 0, 0} = ExitPlan.look(scene, %{group: :hurt, vel: {0.0, 0.0}})
      assert %{r: [["Level", 3] | _], x: %{name: "Three doors"}} = ExitPlan.more(scene, 1)
      assert ExitPlan.input(scene, %{"sign" => [60, 30, "up"]}) == :ok
      assert ExitPlan.more(scene, 2).x.signs == [[60.0, 30.0, "up"]]
    end

    test "a scene for a visitor moves with the clock" do
      {:ok, scene} = ExitPlan.start(nil)
      on_exit(fn -> :boids.stop_world(scene.space) end)
      ExitPlan.input(scene, %{"alarm" => true})
      Process.sleep(600)
      status = ExitPlan.more(scene, 1)
      assert status.x.phase in [:leaving, :done]
      assert status.x.time > 0
    end
  end
end
