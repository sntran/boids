defmodule BoidsExamples.DucklingLineTest do
  # The game Duckling Line: the joins, the chain of relations, the breaks,
  # the nest, the pikes, the keys and the ponds.
  use ExUnit.Case, async: false
  alias BoidsExamples.Scene
  alias BoidsExamples.Games.DucklingLine, as: Line
  alias BoidsExamples.Games.DucklingLine.Director

  # Start a try in a process of its own, as a visitor. The try stops with
  # that process.
  defp run(options) do
    test = self()

    pid =
      spawn(fn ->
        send(test, {:scene, Scene.start(Line, options)})
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
  defp reading(scene, name), do: status(scene).r |> Enum.find(&(hd(&1) == name)) |> List.last()
  defp leader(scene, id), do: List.first(:boids.related(scene.space, id, :follows))
  defp row(scene, id), do: elem(:boids.lookup(scene.space, id), 1)
  defp duck(n), do: {:duckling, n}

  # A pond with no pike, the mother at the left, and the nest far away.
  @calm %{pikes: [], mother: {20.0, 45.0}, nest: {138, 32, 156, 58}, rocks: [], reeds: []}

  test "a lost duckling that sees the mother joins the line behind her" do
    scene = run(Map.put(@calm, :ducklings, [{23.5, 45.0}, {100.0, 70.0}]))
    assert reading(scene, "Lost") == 2

    wait(fn -> leader(scene, duck(0)) == Line.mother() end, "join")
    wait(fn -> row(scene, duck(0)).data.line end, "duckling in the line")
    assert reading(scene, "In the line") == 1
    assert reading(scene, "Lost") == 1
    # The duckling far away is still lost.
    assert leader(scene, duck(1)) == nil
    refute row(scene, duck(1)).data.line
  end

  test "a second duckling joins at the end of the line: the line is a chain of relations" do
    scene = run(Map.put(@calm, :ducklings, [{23.5, 45.0}, {27.0, 45.0}]))
    wait(fn -> leader(scene, duck(0)) == Line.mother() end, "first join")
    wait(fn -> leader(scene, duck(1)) == duck(0) end, "second join behind the first")
    assert :boids.related_to(scene.space, Line.mother(), :follows) == [duck(0)]
    wait(fn -> reading(scene, "In the line") == 2 end, "two in the line")
    # The page gets the relations of the chain.
    graph = :boids.relations(scene.space)
    assert {duck(1), duck(0), :follows} in :graph.edges(graph)
  end

  test "a duckling far from its leader for 2 seconds leaves the line, and the ducklings behind it follow it" do
    scene = run(Map.put(@calm, :ducklings, [{23.5, 45.0}, {27.0, 45.0}]))
    wait(fn -> leader(scene, duck(1)) == duck(0) end, "a line of two")

    # The mother is far away at once: the first duckling cannot follow.
    :ok = :boids.update(scene.space, Line.mother(), %{pos: {140.0, 80.0}})
    wait(fn -> leader(scene, duck(0)) == nil end, "break")
    assert reading(scene, "Breaks") == 1
    # The second duckling still follows the first: a short line that waits.
    assert leader(scene, duck(1)) == duck(0)
    wait(fn -> reading(scene, "Lost") == 2 end, "two lost ducklings")
    refute row(scene, duck(1)).data.line

    # The mother comes back: the short line joins her again.
    {x, y} = row(scene, duck(0)).pos
    :ok = :boids.update(scene.space, Line.mother(), %{pos: {x - 3.0, y}})
    wait(fn -> leader(scene, duck(0)) == Line.mother() end, "join again")
    wait(fn -> reading(scene, "In the line") == 2 end, "the whole line back")
  end

  test "a duckling that comes into the nest in a line is safe, and all safe ends the pond with stars" do
    options = %{@calm | nest: {14, 38, 32, 52}} |> Map.put(:ducklings, [{24.0, 45.0}])
    scene = run(options)
    wait(fn -> status(scene).x.state == :done end, "the end of the pond")
    x = status(scene).x
    assert x.safe == 1 and x.total == 1
    assert x.breaks == 0 and x.stars == 3
    assert row(scene, duck(0)).data.safe
    # A safe duckling has no leader, and stays in the nest.
    assert leader(scene, duck(0)) == nil
    assert {:ok, %{rules: rules}} = :boids.boid(scene.space, duck(0))
    assert hd(rules) |> elem(0) == :contain
  end

  test "the ducklings behind a safe duckling follow it into the nest" do
    # A line of two forms outside the nest, then the mother swims into it.
    options = Map.merge(@calm, %{mother: {44.0, 45.0}, nest: {10, 36, 30, 54}, ducklings: [{47.5, 45.0}, {51.0, 45.0}]})
    scene = run(options)
    wait(fn -> leader(scene, duck(1)) == duck(0) end, "a line of two")
    Director.input(scene.director, %{"keys" => ["left"]})
    wait(fn -> status(scene).x.state == :done end, "all safe")
    assert status(scene).x.safe == 2
    assert status(scene).x.breaks == 0
  end

  test "a lost duckling in the nest is not safe: it must come in a line" do
    options = Map.merge(@calm, %{nest: {80, 30, 110, 60}, ducklings: [{95.0, 45.0}]})
    scene = run(options)
    Process.sleep(1000)
    assert status(scene).x.safe == 0
    refute row(scene, duck(0)).data.safe
  end

  test "a pike scares a duckling near it, and the duckling flees fast" do
    options = Map.merge(@calm, %{ducklings: [{84.0, 45.0}], pikes: [{80.0, 45.0}]})
    scene = run(options)

    wait(
      fn ->
        {:ok, boid} = :boids.boid(scene.space, duck(0))
        boid.state.scared > 0 and boid.max_speed == 9
      end,
      "scare"
    )
  end

  test "the keys move the mother, hurry is faster, and bad input changes nothing" do
    scene = run(Map.put(@calm, :ducklings, [{100.0, 80.0}]))
    Director.input(scene.director, %{"keys" => ["right", "nothing", 5]})
    wait(fn -> elem(row(scene, Line.mother()).vel, 0) > 4.0 end, "swim")
    Director.input(scene.director, %{"keys" => ["right", "hurry"]})
    wait(fn -> :boids_vec.norm(row(scene, Line.mother()).vel) > 9.0 end, "hurry")
    Director.input(scene.director, %{"keys" => []})
    wait(fn -> :boids_vec.norm(row(scene, Line.mother()).vel) < 1.0 end, "stop")

    # Bad messages, and the next pond while the pond is not done.
    Director.input(scene.director, %{"keys" => "right"})
    Director.input(scene.director, %{"go" => true})
    Director.input(scene.director, %{"other" => 1})
    assert status(scene).x.pond == 1
    assert status(scene).x.state == :swimming
  end

  test "go starts the next pond after the nest, and again starts the same pond" do
    # The rocks and the reeds of the ponds stay: the options hold for each pond.
    options = %{pikes: [], mother: {20.0, 45.0}, nest: {14, 38, 32, 52}, ducklings: [{24.0, 45.0}]}
    scene = run(options)
    wait(fn -> status(scene).x.state == :done end, "the end of the pond")

    Director.input(scene.director, %{"go" => true})
    wait(fn -> status(scene).x.pond == 2 end, "the next pond")
    assert status(scene).x.state == :swimming
    assert status(scene).x.name == "Reed maze"
    # The world of the new pond has its rocks and reeds.
    assert length(:boids.obstacles(scene.space)) == 7

    Director.input(scene.director, %{"again" => true})
    wait(fn -> status(scene).x.safe == 0 and status(scene).x.pond == 2 end, "the same pond again")
  end

  test "each pond has its ducklings and pikes on free water, not in a rock, the reeds or the nest" do
    for {pond, number} <- Enum.with_index(Director.ponds(), 1) do
      scene = run(%{pond: number})
      rows = :boids.snapshot(scene.space, :local)
      ducklings = for %{group: :ducklings} = row <- rows, do: row
      pikes = for %{group: :pikes} = row <- rows, do: row
      assert length(ducklings) == pond.ducklings
      assert length(pikes) == pond.pikes
      assert status(scene).x.total == pond.ducklings

      for %{pos: pos} <- ducklings ++ pikes do
        refute Line.inside?(pos, pond.nest)
        for {x, y, r} <- pond.rocks ++ pond.reeds, do: assert(:boids_vec.dist(pos, {x, y}) > r)
      end

      # The header has the ground, the nest, the rocks and the reeds.
      header = Scene.header(scene)
      assert header.ground == "water"
      assert [[_, _, _, _, "gold", "Nest"]] = header.zones
      assert length(header.rocks) == length(pond.rocks)
      assert length(header.reeds) == length(pond.reeds)
      assert length(Scene.header(scene).kinds) == 5
    end
  end

  test "a duckling is in the line when its chain of leaders comes to the mother or to a safe duckling" do
    rows = %{
      a: %{data: %{safe: false}},
      b: %{data: %{safe: false}},
      s: %{data: %{safe: true}},
      c: %{data: %{safe: false}}
    }

    leaders = %{a: :mother, b: :a, c: :x}
    lookup = fn id -> if Map.has_key?(rows, id), do: {:ok, rows[id]}, else: :error end
    related = fn id, :follows -> List.wrap(leaders[id]) end

    assert Line.in_line?(:mother, lookup, related)
    assert Line.in_line?(:b, lookup, related)
    assert Line.in_line?(:s, lookup, related)
    refute Line.in_line?(nil, lookup, related)
    refute Line.in_line?(:c, lookup, related)
    refute Line.in_line?(:gone, lookup, related)
  end

  test "the look of each boid for the page" do
    scene = run(Map.put(@calm, :ducklings, [{100.0, 80.0}]))
    assert {0, _, 0} = Line.look(scene, %{group: :mother, vel: {1.0, 0.0}})
    assert {4, _, 0} = Line.look(scene, %{group: :pikes, vel: {1.0, 0.0}})
    assert {3, _, 0} = Line.look(scene, %{group: :ducklings, data: %{line: false, safe: true}, vel: {1.0, 0.0}})
    assert {2, _, 0} = Line.look(scene, %{group: :ducklings, data: %{line: true, safe: false}, vel: {1.0, 0.0}})
    assert {1, _, 0} = Line.look(scene, %{group: :ducklings, data: %{line: false, safe: false}, vel: {1.0, 0.0}})
    assert %{r: [_ | _], x: %{state: :swimming, reeds: []}} = Line.more(scene, 1)
    assert Line.info().slug == "duckling-line"
  end
end
