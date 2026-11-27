defmodule BoidsSite.FlightTest do
  # The game Long Flight: the director of a run, the birds and the hawks.
  use ExUnit.Case, async: false
  alias BoidsSite.Scene
  alias BoidsSite.Scenes.Flight
  alias BoidsSite.Scenes.Flight.{Bird, Director, Hawk}

  # Start a run in a process of its own, as a visitor. The run stops with
  # that process.
  defp run(options) do
    test = self()

    pid =
      spawn(fn ->
        send(test, {:scene, Scene.start(Flight, options)})
        Process.sleep(:infinity)
      end)

    on_exit(fn -> Process.exit(pid, :kill) end)
    assert_receive {:scene, {:ok, scene}}, 5000
    scene
  end

  # Wait until the status of the run is as the function tells, for 8 seconds at most.
  defp wait(scene, fun, tries \\ 160) do
    status = Director.status(scene.director)

    cond do
      fun.(status) -> status
      tries == 0 -> flunk("The run did not come to the state: #{inspect(status.x)}")
      true -> Process.sleep(50) && wait(scene, fun, tries - 1)
    end
  end

  defp birds(scene), do: for(%{group: :birds} = row <- :boids.snapshot(scene.space, :local), do: row)
  defp names(status), do: Enum.map(status.x.deck, & &1.name)

  # A small land near the exit: the birds are safe in less than 2 seconds.
  @near %{birds: 4, rocks: 0, hawks: 0, start: {140, 145}}
  # A land where the birds are far from the exit.
  @far %{birds: 3, rocks: 0, hawks: 0, start: {10, 15}}

  test "the birds that reach the exit are safe, and the person gets an offer of 3 cards" do
    scene = run(@near)
    header = Scene.header(scene)
    assert header.box == [160, 90]
    assert header.zones == [[150, 0, 160, 90, "cool"]]
    assert Enum.map(header.kinds, & &1.name) == ["birds", "hawks", "elders"]

    status = Director.status(scene.director)
    assert status.x.phase == :flying and status.x.land == 1
    assert [["Land", 1], ["Birds", 4], ["Safe", 0], ["Lost", 0], ["Seconds", seconds]] = status.r
    assert seconds in 85..90
    assert names(status) == [:flow, :separation, :alignment, :cohesion]

    # A moment of the scene is JSON for the page, with the rocks of the land.
    moment = Scene.frame(scene, 1)
    assert length(moment.b) == 4 * 6
    assert moment.h == %{rocks: []}
    assert is_binary(IO.iodata_to_binary(:json.encode(moment)))

    status = wait(scene, &(&1.x.phase == :choosing))
    assert %{safe: 4, lost: 0, land: 1, picked: false} = status.x
    assert [%{title: _, text: _}, _, _] = status.x.offer
    # While the deck has no rule for the rocks, the offer has that card.
    assert "Avoid the rocks" in Enum.map(status.x.offer, & &1.title)
    assert birds(scene) == []
  end

  test "a card changes the deck one time, and the order of the person is the order of the rules of the next land" do
    scene = run(@near)
    status = wait(scene, &(&1.x.phase == :choosing))

    # A number that is not a card of the offer changes nothing.
    assert Scene.input(scene, %{"pick" => 7}) == :ok
    assert Scene.input(scene, %{"pick" => "avoid"}) == :ok
    refute Director.status(scene.director).x.picked

    card = Enum.find_index(status.x.offer, &(&1.title == "Avoid the rocks"))
    Scene.input(scene, %{"pick" => card})
    status = wait(scene, & &1.x.picked)
    assert names(status) == [:flow, :separation, :alignment, :cohesion, :avoid]

    # The person takes one card for each land.
    Scene.input(scene, %{"pick" => card})
    assert names(Director.status(scene.director)) == [:flow, :separation, :alignment, :cohesion, :avoid]

    # A name that is not a rule of the deck has no effect, and the rules
    # with no name stay last, in their order.
    Scene.input(scene, %{"order" => ["avoid", "nothing", "cohesion", "avoid"]})
    assert names(Director.status(scene.director)) == [:avoid, :cohesion, :flow, :separation, :alignment]
    Scene.input(scene, %{"order" => "avoid"})
    Scene.input(scene, %{"other" => true})
    assert names(Director.status(scene.director)) == [:avoid, :cohesion, :flow, :separation, :alignment]

    # The next land has the safe birds, with the rules of the deck in that order.
    Scene.input(scene, %{"go" => true})
    status = wait(scene, &(&1.x.phase == :flying and &1.x.land == 2))
    assert [["Land", 2], ["Birds", 4] | _] = status.r
    assert status.x.offer == []

    for %{pid: pid} <- birds(scene) do
      assert :gen_boid.which_rules(pid) == [:avoid, :cohesion, :flow, :separation, :alignment]
    end
  end

  test "a bird that a hawk catches is lost, and a run with no safe bird is over" do
    scene = run(@far)
    [first | rest] = birds(scene)

    # A pick, an order and a go have no effect while the flock flies.
    Scene.input(scene, %{"pick" => 0})
    Scene.input(scene, %{"order" => ["cohesion"]})
    Scene.input(scene, %{"go" => true})

    :gen_boid.cast(first.pid, :caught)
    status = wait(scene, &(&1.x.lost == 1))
    assert status.x.phase == :flying and status.x.land == 1
    assert [["Land", 1], ["Birds", 2], ["Safe", 0], ["Lost", 1] | _] = status.r
    assert names(status) == [:flow, :separation, :alignment, :cohesion]

    for bird <- rest, do: :gen_boid.cast(bird.pid, :caught)
    status = wait(scene, &(&1.x.phase == :over))
    assert %{safe: 0, lost: 3, offer: []} = status.x

    # A go starts a new run, with the first deck.
    Scene.input(scene, %{"go" => true})
    status = wait(scene, &(&1.x.phase == :flying))
    assert [["Land", 1], ["Birds", 3], ["Safe", 0], ["Lost", 0] | _] = status.r
  end

  test "after the time of a land, the birds that are still there are lost" do
    scene = run(Map.put(@far, :time, 200))
    status = wait(scene, &(&1.x.phase == :over))
    assert %{safe: 0, lost: 3} = status.x
    assert birds(scene) == []
  end

  test "a land has its rocks and its hawks, and the hawks go at its end" do
    scene = run(%{birds: 2, start: {140, 145}})
    status = Director.status(scene.director)
    assert length(status.h.rocks) == 3
    assert length(:boids.obstacles(scene.space)) == 3
    assert Enum.count(:boids.snapshot(scene.space, :local), &(&1.group == :hawks)) == 1

    wait(scene, &(&1.x.phase != :flying))
    assert Enum.count(:boids.snapshot(scene.space, :local), &(&1.group == :hawks)) == 0
  end

  test "each card changes the deck" do
    deck = Director.deck()
    assert Director.card(:avoid).title == "Avoid the rocks"
    assert {:avoid, 4.0, %{lookahead: 1.5}} = List.last(Director.take(deck, :avoid).rules)
    assert {:evade, 3.0, %{target: {:group, :hawks}}} = List.last(Director.take(deck, :evade).rules)
    assert {:dodge, 2.0, %{}} = List.last(Director.take(deck, :dodge).rules)
    # A card for a rule that the deck has adds 0.5 to its weight.
    assert {:avoid, 4.5, _} = List.last(deck |> Director.take(:avoid) |> Director.take(:avoid) |> Map.fetch!(:rules))
    assert {:cohesion, 1.5, _} = List.keyfind(Director.take(deck, :cohesion).rules, :cohesion, 0)
    assert {:separation, 2.0, %{radius: 3}} = List.keyfind(Director.take(deck, :separation).rules, :separation, 0)
    assert {:alignment, 1.5, _} = List.keyfind(Director.take(deck, :alignment).rules, :alignment, 0)
    assert {:flow, 1.5, _} = List.keyfind(Director.take(deck, :flow).rules, :flow, 0)
    assert Director.take(deck, :speed).speed == 12
    assert Director.take(deck, :eyes).perception == 14
    assert Director.take(deck, :scatter).scatter
    elders = Director.take(deck, :elders)
    assert elders.elders and List.last(elders.rules) == {:leader, 1.5, %{target: {:related, :follows}}}
    assert Director.take(elders, :elders) == elders
    assert Director.take(deck, :chicks) == deck
  end

  test "the cards New chicks, Scatter and Elders change the next land" do
    scene = run(@near)
    wait(scene, &(&1.x.phase == :choosing))

    # The person takes New chicks from an offer that has it.
    :sys.replace_state(scene.director, &%{&1 | offer: [Director.card(:chicks)]})
    Scene.input(scene, %{"pick" => 0})
    wait(scene, & &1.x.picked)

    # The deck gets the two other cards. An offer does not have them again.
    :sys.replace_state(scene.director, fn state ->
      %{
        state
        | deck: state.deck |> Director.take(:scatter) |> Director.take(:elders) |> Director.take(:avoid),
          options: Map.merge(state.options, @far)
      }
    end)

    Scene.input(scene, %{"go" => true})
    status = wait(scene, &(&1.x.phase == :flying and &1.x.land == 2))
    assert [["Land", 2], ["Birds", 9] | _] = status.r
    assert status.x.scatter and status.x.elders

    # Elders: 3 birds are elders, and each other bird follows one of them.
    rows = birds(scene)
    elders = for %{data: :elder, id: id} <- rows, do: id
    assert length(elders) == 3
    edges = :graph.edges(:boids.relations(scene.space))
    assert length(edges) == 6
    assert Enum.all?(edges, fn {from, to, label} -> label == :follows and to in elders and from not in elders end)
    kinds = Scene.frame(scene, 1).b |> Enum.chunk_every(6) |> Enum.frequencies_by(&Enum.at(&1, 4))
    assert kinds == %{0 => 6, 2 => 3}

    # Scatter: a bird that sees a hawk has other rules first, and its deck again with no hawk.
    {:ok, boid} = :boids.boid(scene.space, hd(rows).id)
    deck = [:flow, :separation, :alignment, :cohesion, :leader, :avoid]
    assert :boids_boid.which_rules(boid) == deck
    hawk = %{group: :hawks, dist: 5.0}
    assert {:ok, afraid} = Bird.handle_decide(%{neighbors: [hawk], obstacles: []}, boid)
    assert :boids_boid.which_rules(afraid) == [:evade, {:separation, :scatter}] ++ deck
    assert {:ok, ^afraid} = Bird.handle_decide(%{neighbors: [hawk], obstacles: []}, afraid)
    assert {:ok, calm} = Bird.handle_decide(%{neighbors: [], obstacles: []}, afraid)
    assert :boids_boid.which_rules(calm) == deck
    assert {:ok, ^calm} = Bird.handle_decide(%{neighbors: [], obstacles: []}, calm)

    # The offer of a deck with Scatter and Elders does not have them.
    for bird <- rows, do: :gen_boid.cast(bird.pid, :caught)
    wait(scene, &(&1.x.phase == :over))
    :sys.replace_state(scene.director, &%{&1 | phase: :flying, safe: 1, alive: MapSet.new([:last])})
    GenServer.cast(scene.director, {:safe, :last})
    status = wait(scene, &(&1.x.phase == :choosing))
    titles = Enum.map(status.x.offer, & &1.title)
    assert length(titles) == 3 and "Scatter" not in titles and "Elders" not in titles
  end

  test "a bird in a rock is lost" do
    scene = run(@far)
    [%{id: id, pos: pos} | _] = birds(scene)
    {:ok, boid} = :boids.boid(scene.space, id)
    assert {:ok, ^boid} = Bird.handle_decide(%{neighbors: [], obstacles: [%{pos: {80, 45}, radius: 5}]}, boid)
    assert {:stop, :normal, ^boid} = Bird.handle_decide(%{neighbors: [], obstacles: [%{pos: pos, radius: 5}]}, boid)
    # The director counts a bird one time.
    GenServer.cast(scene.director, {:lost, id})
    assert wait(scene, &(&1.x.lost == 1)).x.lost == 1
    assert [["Land", 1], ["Birds", 2] | _] = Director.status(scene.director).r
  end

  test "a hawk hunts a bird that it sees, catches a bird that it touches, then rests" do
    scene = run(@far)
    [%{id: id, pid: pid} | _] = birds(scene)
    {:ok, hawk} = :gen_boid.start(scene.space, Hawk, {80, 45})
    {:ok, boid} = :boids.boid(scene.space, id_of(scene, hawk))
    assert :boids_boid.which_rules(boid) == [:avoid, :wander, :cruise]
    lookup = fn ^id -> {:ok, %{pid: pid}} end
    seen = fn birds -> %{neighbors: birds, lookup: lookup} end

    # No bird: the hawk wanders, and its rules do not change.
    assert {:ok, ^boid} = Hawk.handle_decide(seen.([]), boid)
    assert {:ok, hunter} = Hawk.handle_decide(seen.([%{group: :birds, id: id, dist: 10.0}]), boid)
    assert :boids_boid.which_rules(hunter) == [:avoid, :pursue]
    assert hunter.state.mode == :hunts

    # A touch: the bird gets the message, and the hawk rests for 3 seconds.
    assert {:ok, full} = Hawk.handle_decide(seen.([%{group: :birds, id: id, dist: 1.0}]), hunter)
    assert full.state == %{mode: :rests, rest: Flight.steps(3000)}
    assert :boids_boid.which_rules(full) == [:avoid, :wander, :cruise]
    assert wait(scene, &(&1.x.lost == 1)).x.lost == 1
    assert {:ok, %{state: %{rest: rest}}} = Hawk.handle_decide(seen.([%{group: :birds, id: id, dist: 1.0}]), full)
    assert rest == Flight.steps(3000) - 1
    # A hawk that sees no bird after a hunt wanders again.
    assert {:ok, %{state: %{mode: :rests}}} = Hawk.handle_decide(seen.([]), hunter)
  end

  defp id_of(scene, pid) do
    [id] = for %{id: id, pid: ^pid} <- :boids.snapshot(scene.space, :local), do: id
    id
  end
end
