defmodule BoidsExamples.ScenesTest do
  # The scenes of the site: each one starts, gives moments, and stops.
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

  test "the flock of the home page has birds and a hawk" do
    {_pid, {:ok, scene}} = scene(BoidsExamples.Scenes.Flock)
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
      {_pid, {:ok, %{space: space} = scene}} = scene(BoidsExamples.Scenes.Playground, definition)
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

      {_pid, {:ok, %{space: space}}} = scene(BoidsExamples.Scenes.Playground, %{"kinds" => [chain]})
      relations = :boids.relations(space)
      assert :graph.no_edges(relations) == 4

      assert :graph.is_arborescence(:graph.subgraph(relations, :graph.vertices(relations))) or
               :graph.is_acyclic(relations)
    end

    test "refuses a bad definition with a text for the visitor" do
      bad = fn definition ->
        {_pid, {:error, text}} = scene(BoidsExamples.Scenes.Playground, definition)
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
      assert :counters.get(:persistent_term.get(BoidsExamples.Scene), 1) == 0
    end
  end

  test "the site has a limit of the scenes at one time, and a scene stops with its visitor" do
    count = :persistent_term.get(BoidsExamples.Scene)
    limit = String.to_integer(System.get_env("BOIDS_SCENES", "8"))
    started = for _ <- 1..limit, do: scene(BoidsExamples.Scenes.Playground, %{"kinds" => [@hawks]})
    assert Enum.all?(started, &match?({_pid, {:ok, _}}, &1))
    assert {_pid, {:error, text}} = scene(BoidsExamples.Scenes.Playground, %{"kinds" => [@hawks]})
    assert text =~ "scenes at one time"

    for {pid, _} <- started, do: Process.exit(pid, :kill)
    Process.sleep(300)
    assert :counters.get(count, 1) == 0
    assert {_pid, {:ok, scene}} = scene(BoidsExamples.Scenes.Playground, %{"kinds" => [@hawks]})
    # A visitor can stop a scene, for a new one.
    # The stop waits for the end of the world, so the count is right at once.
    assert Scene.stop(scene) == :ok
    assert :counters.get(count, 1) == 0
  end
end
