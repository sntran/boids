defmodule BoidsExamples.Games.AntTrailTest do
  # The rules of Ant Trail: the scent and its field, the food, the ants
  # that carry food home and leave scent, the trail to the near food, and
  # the inputs of the person.
  use ExUnit.Case, async: false
  alias BoidsExamples.Games.AntTrail
  alias BoidsExamples.Games.AntTrail.Director
  alias BoidsExamples.Scene

  # Start a game in a process of its own: the game stops with that
  # process. The options go to the director.
  defp game(options) do
    test = self()

    visitor =
      spawn(fn ->
        send(test, {:started, Scene.start(AntTrail, options)})
        Process.sleep(:infinity)
      end)

    assert_receive {:started, {:ok, scene}}, 10_000

    # At the end of the test, the scene stops with its visitor. The test
    # waits for the end of its world, so that the next test counts no
    # scene of this test.
    on_exit(fn ->
      ref = Process.monitor(scene.guard)
      Process.exit(visitor, :kill)

      receive do
        {:DOWN, ^ref, :process, _pid, _reason} -> :ok
      after
        5000 -> :ok
      end
    end)

    scene
  end

  # Wait until the state of the director agrees with a function, for 60
  # seconds at most. The result is that state.
  defp until(scene, check, tries \\ 600) do
    state = Director.state(scene.director)

    cond do
      check.(state) -> state
      tries == 0 -> flunk("The game did not come to the state. Last state: #{inspect(Map.drop(state, [:land]))}")
      true -> Process.sleep(100) && until(scene, check, tries - 1)
    end
  end

  # A land with no world: only a table of scent, for the tests of the
  # scent. A land of an earlier time is the same land with an earlier t0.
  defp land(half_life) do
    %{
      scent: :ets.new(:test_scent, [:set, :public]),
      t0: System.monotonic_time(:millisecond),
      scale: 1.0,
      half_life: half_life
    }
  end

  defp later(land, ms), do: %{land | t0: land.t0 - ms}

  defp pieces(state), do: Map.new(AntTrail.piles(state.land), fn {id, _x, _y, n} -> {id, n} end)

  defp place(scene, item, {x, y}), do: AntTrail.input(scene, %{"place" => [x, y], "item" => item})

  # The most scent of the cells near a position.
  defp strongest(land, {x, y}, radius) do
    values =
      for {index, scent} <- AntTrail.cells(land), :boids_vec.dist(AntTrail.center(index), {x, y}) <= radius, do: scent

    Enum.max(values, fn -> 0.0 end)
  end

  test "a cell keeps the stronger scent, and the scent falls to half in each half life" do
    land = land(10_000)
    assert AntTrail.cell({0.0, 0.0}) == 0
    assert AntTrail.cell({3.0, 5.0}) == 1 + 2 * 80
    assert AntTrail.cell({-1.0, 5.0}) == nil and AntTrail.cell({160.0, 5.0}) == nil
    assert AntTrail.center(1 + 2 * 80) == {3.0, 5.0}

    assert AntTrail.mark(land, {11.0, 11.0}, 8.0) == :ok
    assert_in_delta AntTrail.scent(land, {11.0, 11.0}), 8.0, 0.2
    # The cells next to the mark get the half of the scent.
    assert_in_delta AntTrail.scent(land, {13.0, 11.0}), 4.0, 0.1
    assert_in_delta AntTrail.scent(land, {11.0, 9.0}), 4.0, 0.1
    assert AntTrail.scent(land, {15.0, 15.0}) == 0.0

    # A weaker mark does not change the cell. Many ants on the same way do
    # not add their scent.
    AntTrail.mark(land, {11.0, 11.0}, 2.0)
    assert_in_delta AntTrail.scent(land, {11.0, 11.0}), 8.0, 0.2

    # After one half life, the scent is the half. A new mark that is
    # stronger than the scent now takes its place.
    assert_in_delta AntTrail.scent(later(land, 10_000), {11.0, 11.0}), 4.0, 0.2
    assert_in_delta AntTrail.scent(later(land, 20_000), {11.0, 11.0}), 2.0, 0.1
    AntTrail.mark(later(land, 20_000), {11.0, 11.0}, 3.0)
    assert_in_delta AntTrail.scent(later(land, 20_000), {11.0, 11.0}), 3.0, 0.1

    # No cell has more than 10.
    AntTrail.mark(land, {51.0, 51.0}, 50.0)
    assert AntTrail.scent(land, {51.0, 51.0}) <= 10.0
    # A mark out of the land changes nothing.
    assert AntTrail.mark(land, {-5.0, 200.0}, 5.0) == :ok
  end

  test "the scent of an ant with food is stronger near the food" do
    assert AntTrail.strength(0.0) == 10.0
    strengths = for walked <- [0, 10, 40, 80, 160], do: AntTrail.strength(walked * 1.0)
    assert strengths == Enum.sort(strengths, :desc)
    assert_in_delta AntTrail.strength(40.0), 10.0 / :math.exp(1), 0.01
  end

  test "the field points to the stronger scent, and gives no force on no scent or on a flat scent" do
    land = land(60_000)
    field = AntTrail.field(land)

    # No scent: no force.
    assert field.({80.0, 45.0}) == {0.0, 0.0}

    # A trail along x, with more scent to the right.
    for x <- 20..60//2, do: AntTrail.mark(land, {x + 1.0, 21.0}, x / 8)
    {gx, _gy} = field.({41.0, 21.0})
    assert gx > 0

    # Under the trail, the field points up to the trail.
    {_gx, gy} = field.({41.0, 17.0})
    assert gy > 0

    # A flat scent: no force.
    for x <- 100..130//2, y <- 50..80//2, do: AntTrail.mark(land, {x + 1.0, y + 1.0}, 6.0)
    assert field.({115.0, 65.0}) == {0.0, 0.0}

    # An old trail that is too faint: no force.
    assert AntTrail.field(later(land, 600_000)).({41.0, 21.0}) == {0.0, 0.0}
  end

  test "a pile gives each piece once, and the last piece removes the pile" do
    food = :ets.new(:test_food, [:set, :public])
    land = %{food: food}
    :ets.insert(food, {0, 30.0, 30.0, 2})
    assert AntTrail.nearest_pile(land, {31.0, 30.0}, 8.0) == {0, {30.0, 30.0}, 1.0}
    assert AntTrail.nearest_pile(land, {50.0, 30.0}, 8.0) == nil
    assert AntTrail.take(land, 0)
    assert AntTrail.take(land, 0)
    assert AntTrail.piles(land) == []
    refute AntTrail.take(land, 0)
  end

  test "an ant takes a piece of food home, and leaves a scent that is stronger near the food" do
    scene = game(%{layout: "empty", scale: 3.0, ants: 20})
    place(scene, "food", {40, 45})
    state = until(scene, &(&1.home >= 3))

    # Each piece at the nest came from the pile.
    assert pieces(state)[0] <= 40 - 3
    [trip | _] = state.trips
    assert trip >= 10

    # The scent near the food is stronger than the scent near the nest.
    assert strongest(state.land, {40.0, 45.0}, 4.0) > strongest(state.land, {30.0, 45.0}, 3.0)

    # The readings show the food at the nest, and the length of the trips.
    %{r: readings} = AntTrail.more(scene, 1)
    assert ["Home", home] = Enum.find(readings, &(hd(&1) == "Home"))
    assert home >= 3
    assert ["Trip", "" <> trip] = Enum.find(readings, &(hd(&1) == "Trip"))
    assert trip =~ ~r/^\d+ units$/
  end

  test "the ants bring more food from the near pile than from the far pile" do
    scene = game(%{layout: "piles", scale: 3.0})
    state = until(scene, &(&1.home >= 20))
    left = pieces(state)
    assert Map.get(left, 0, 0) < Map.get(left, 1, 0)
  end

  test "the person places food and rocks in the land, with limits" do
    scene = game(%{layout: "empty", ants: 0})
    %{pieces: pieces, piles: most_piles, rocks: most_rocks, rock: radius} = AntTrail.limits()

    place(scene, "food", {60, 30})
    assert [{0, 60.0, 30.0, ^pieces}] = AntTrail.piles(until(scene, &(&1.piles == 1)).land)

    # No food at the nest, out of the land, or on other food.
    place(scene, "food", {22, 45})
    place(scene, "food", {200, 45})
    place(scene, "food", {61, 30})

    # At most some piles.
    for k <- 1..most_piles, do: place(scene, "food", {40 + 10 * k, 70})
    until(scene, &(length(AntTrail.piles(&1.land)) == most_piles))
    Process.sleep(200)
    state = Director.state(scene.director)
    assert length(AntTrail.piles(state.land)) == most_piles

    # A rock on a pile removes the pile. A rock is an obstacle of the world.
    place(scene, "rock", {60, 30})
    state = until(scene, &(length(&1.rocks) == 1))
    assert length(AntTrail.piles(state.land)) == most_piles - 1
    assert [%{pos: {60.0, 30.0}, radius: ^radius}] = :boids.obstacles(scene.space)

    # No rock on a rock, and at most some rocks.
    place(scene, "rock", {61, 31})
    for k <- 1..(most_rocks + 2), do: place(scene, "rock", {12 * k, 12})
    state = until(scene, &(length(&1.rocks) == most_rocks))
    Process.sleep(200)
    assert length(Director.state(scene.director).rocks) == most_rocks
    assert length(:boids.obstacles(scene.space)) == most_rocks
    refute Enum.any?(state.rocks, fn {x, y, _r} -> {x, y} == {61.0, 31.0} end)
  end

  test "the land ignores bad inputs" do
    scene = game(%{layout: "empty", ants: 0})

    for message <- [
          %{"place" => [50, 50], "item" => "tree"},
          %{"place" => ["50", 50], "item" => "food"},
          %{"place" => [50], "item" => "food"},
          %{"place" => %{"x" => 50}, "item" => "rock"},
          %{"place" => [50, 50]},
          %{"layout" => "sea"},
          %{"layout" => 3},
          %{"rain" => "yes"},
          %{"item" => "food"},
          "food",
          nil
        ] do
      assert AntTrail.input(scene, message) == :ok
    end

    # The director is alive, and nothing changed.
    state = Director.state(scene.director)
    assert AntTrail.piles(state.land) == [] and state.rocks == [] and state.layout == "empty"
  end

  test "rain washes the scent away" do
    scene = game(%{layout: "empty", ants: 0})
    land = Director.state(scene.director).land
    AntTrail.mark(land, {50.0, 50.0}, 5.0)
    assert length(AntTrail.cells(land)) == 5

    AntTrail.input(scene, %{"rain" => true})
    until(scene, &(AntTrail.cells(&1.land) == []))
  end

  test "a new land starts again, with its rocks, its food and its ants" do
    scene = game(%{layout: "piles", scale: 3.0, ants: 6})
    until(scene, &(length(:boids.snapshot(&1.land.space, :local)) == 6))

    AntTrail.input(scene, %{"layout" => "bridge"})
    state = until(scene, &(&1.layout == "bridge"))
    assert state.home == 0 and state.trips == []
    assert length(state.rocks) == 5
    assert [{_id, 130.0, 25.0, 80}] = AntTrail.piles(state.land)
    assert length(:boids.obstacles(scene.space)) == 5

    AntTrail.input(scene, %{"layout" => "empty"})
    state = until(scene, &(&1.layout == "empty"))
    assert AntTrail.piles(state.land) == [] and state.rocks == []
    assert :boids.obstacles(scene.space) == []
    # The ants come out of the nest again, up to the most ants.
    state = until(scene, &(length(:boids.snapshot(&1.land.space, :local)) == 6))
    assert state.started == 6
  end

  test "the readings, the scent for the page, and the header" do
    scene = game(%{layout: "piles", scale: 3.0, ants: 20})
    until(scene, &(AntTrail.cells(&1.land) != []))

    status = AntTrail.more(scene, 1)
    assert Enum.map(status.r, &hd/1) == ["Ants", "With food", "Home", "Food left", "Trip"]
    piles = Enum.chunk_every(status.x.piles, 3)
    assert Enum.any?(piles, &match?([55.0, 62.0, _], &1))
    assert status.x.layout == "piles"

    # The scent goes four times in a second: index and level, 1 to 9.
    number = max(div(250, Scene.tick()), 1)
    if number > 1, do: refute(Map.has_key?(status.x, :scent))
    %{x: %{scent: [_, _ | _] = scent}} = AntTrail.more(scene, number)
    assert rem(length(scent), 2) == 0
    {indexes, levels} = scent |> Enum.chunk_every(2) |> Enum.map(&List.to_tuple/1) |> Enum.unzip()
    assert Enum.all?(indexes, &(&1 in 0..(80 * 45 - 1)))
    assert Enum.all?(levels, &(&1 in 1..9))
    assert is_binary(IO.iodata_to_binary(:json.encode(Scene.frame(scene, number))))

    header = Scene.header(scene)
    assert header.ground == "sand"
    assert [[_, _, _, _, "fur", "Nest"]] = header.zones
    assert header.grid == %{cell: 2.0, columns: 80, rows: 45}
    assert [%{name: "ants"}, %{name: "ants with food"}] = header.kinds
    assert is_binary(IO.iodata_to_binary(:json.encode(header)))

    # An ant with food has its own look.
    assert {1, _, 0} = AntTrail.look(scene, %{data: :carry, vel: {1.0, 0.0}})
    assert {0, _, 0} = AntTrail.look(scene, %{data: :search, vel: {1.0, 0.0}})

    # The ids of the ants are not their processes.
    for %{id: id} <- :boids.snapshot(scene.space), do: refute(is_pid(id))
    assert length(:boids.snapshot(scene.space)) <= 60
  end

  test "the game tells what it is" do
    info = AntTrail.info()
    assert info.slug == "ant-trail" and info.title == "Ant Trail" and info.order == 110
    assert AntTrail.page() =~ ~s(name: "ant-trail")
    assert AntTrail.ants() <= 60
  end
end
