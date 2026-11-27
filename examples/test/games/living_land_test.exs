defmodule BoidsExamples.LandTest do
  # Living Land: animals that eat, have young and die, and a land that the
  # person changes.
  use ExUnit.Case, async: false
  alias BoidsExamples.Scene
  alias BoidsExamples.Games.LivingLand, as: Land
  alias BoidsExamples.Games.LivingLand.{Director, Grazer, Hunter}

  # An empty land: no animal, no food, and no growth of food.
  @empty %{grazers: 0, hunters: 0, food: 0, rate: 0.0}

  # Start a land in a process of its own, as a visitor. The land stops
  # with that process.
  defp land(options) do
    test = self()

    pid =
      spawn(fn ->
        send(test, {:scene, Scene.start(Land, options)})
        Process.sleep(:infinity)
      end)

    on_exit(fn -> Process.exit(pid, :kill) end)
    assert_receive {:scene, {:ok, scene}}, 5000
    Map.put(scene, :land, GenServer.call(scene.director, :land))
  end

  # Wait until the function gives a true value, for 10 seconds at most.
  defp wait(fun, tries \\ 200) do
    case fun.() do
      value when value in [false, nil] and tries > 0 ->
        Process.sleep(50)
        wait(fun, tries - 1)

      value ->
        assert value, "The land did not come to the state."
        value
    end
  end

  # Put an animal in the land, as the person does: it needs a place.
  defp animal(%{land: land}, species, pos, more \\ %{}) do
    assert Director.born?(land, species, :founder)
    module = if species == :grazers, do: Grazer, else: Hunter
    young = Map.merge(%{pos: pos, genes: Land.first(species), generation: 0, energy: 50.0, land: land}, more)
    {:ok, id} = Director.birth(land, module, young)
    id
  end

  defp state(scene, id) do
    case :boids.boid(scene.space, id) do
      {:ok, %{state: state}} -> state
      {:error, :not_found} -> nil
    end
  end

  defp food(%{land: land}, x, y), do: :ets.insert(land.food, {:erlang.unique_integer([:positive]), x, y})
  defp status(scene, number \\ 1), do: Director.status(scene.director, number)
  defp reading(status, name), do: Enum.find_value(status.r, fn [label, value] -> label == name && value end)

  defp species(scene, group),
    do: for(%{id: id, group: ^group} <- :boids.snapshot(scene.space, :local), do: id)

  test "the land starts with its animals and its food, and the page gets JSON" do
    scene = land(%{grazers: 6, hunters: 2, food: 10, rate: 0.0})
    assert length(species(scene, :grazers)) == 6
    assert length(species(scene, :hunters)) == 2
    assert :ets.info(scene.land.food, :size) == 10
    assert Director.animals(scene.land) == 8
    assert Director.animals(scene.land, :grazers) == 6

    header = Scene.header(scene)
    assert header.box == [160, 90]
    assert Enum.map(header.kinds, & &1.name) == ["grazers", "hunters"]
    assert header.first.grazers.speed == 8.0
    assert is_binary(IO.iodata_to_binary(:json.encode(header)))

    # A moment has the food. The moment of each second also has the genes
    # and the history.
    status = status(scene)
    assert ["Grazers", 6] in status.r and ["Hunters", 2] in status.r
    assert length(status.x.food) == 20
    refute Map.has_key?(status.x, :genes)
    each_second = status(scene, div(1000, Scene.tick()))
    assert each_second.x.genes.grazers.speed == 8.0
    assert each_second.x.genes.hunters.chase == 1.5
    assert is_list(each_second.x.history)
    assert is_binary(IO.iodata_to_binary(:json.encode(Scene.frame(scene, 20))))
  end

  test "a grazer that touches food eats it, and gets energy" do
    scene = land(@empty)
    id = animal(scene, :grazers, {50.0, 50.0}, %{energy: 30.0})
    food(scene, 50.5, 50.0)
    assert wait(fn -> :ets.info(scene.land.food, :size) == 0 end)
    # 30 + 20 for the food, less the energy of some steps.
    assert state(scene, id).energy > 45
  end

  test "a grazer goes to the food that it sees" do
    scene = land(@empty)
    id = animal(scene, :grazers, {50.0, 45.0}, %{energy: 30.0})
    food(scene, 56.0, 45.0)
    assert Director.nearest_food(scene.land, {50.0, 45.0}, 10) |> elem(2) == 6.0
    assert Director.nearest_food(scene.land, {50.0, 45.0}, 5) == nil
    assert wait(fn -> :ets.info(scene.land.food, :size) == 0 end)
    assert state(scene, id).energy > 40
    assert Grazer.forage(%{pos: {0, 0}, vel: {0, 0}, max_speed: 5}, [], %{food: nil}) == {0.0, 0.0}
  end

  test "an animal with no energy dies, and the land counts it" do
    scene = land(@empty)
    grazer = animal(scene, :grazers, {40.0, 40.0}, %{energy: 0.2})
    hunter = animal(scene, :hunters, {100.0, 40.0}, %{energy: 0.2})
    assert wait(fn -> state(scene, grazer) == nil and state(scene, hunter) == nil end)
    assert wait(fn -> status(scene).x.starved == 2 end)
    assert Director.animals(scene.land) == 0
  end

  test "a young has the genes of its parent with small changes, inside the limits" do
    for species <- [:grazers, :hunters], _ <- 1..200 do
      parent = Land.first(species)
      young = Land.mutate(species, parent)

      for {gene, {_first, min, max}} <- Land.genes(species) do
        assert young[gene] >= min and young[gene] <= max
        assert abs(young[gene] - parent[gene]) <= 0.08 * (max - min) + 0.001
      end
    end

    # A gene at its limit stays in the limits.
    top = Map.new(Land.genes(:grazers), fn {gene, {_first, _min, max}} -> {gene, max} end)
    assert Land.mutate(:grazers, top).speed <= 16.0

    # A faster animal and an animal that sees more use more energy.
    first = Land.first(:grazers)
    assert Land.cost(:grazers, %{first | speed: 12.0}) > Land.cost(:grazers, first)
    assert Land.cost(:grazers, %{first | perception: 20.0}) > Land.cost(:grazers, first)
  end

  test "a grazer with enough energy has a young with half of its energy" do
    scene = land(@empty)
    parent = animal(scene, :grazers, {80.0, 45.0}, %{energy: 69.0})
    food(scene, 80.3, 45.0)
    assert wait(fn -> length(species(scene, :grazers)) == 2 end)
    [young] = species(scene, :grazers) -- [parent]

    young_state = wait(fn -> state(scene, young) end)
    assert young_state.generation == 1
    assert young_state.energy < 50 and state(scene, parent).energy < 50
    assert young_state.genes != Land.first(:grazers)
    assert Director.animals(scene.land, :grazers) == 2
    # The director knows the young.
    assert wait(fn -> reading(status(scene), "Generation") == 1 end)
    assert wait(fn -> status(scene).x.born == 1 end)
  end

  test "the cap stops the births, and a young hunter needs prey" do
    scene = land(Map.merge(@empty, %{cap: 2}))
    parent = animal(scene, :grazers, {80.0, 45.0}, %{energy: 69.0})
    _other = animal(scene, :grazers, {20.0, 20.0})
    refute Director.born?(scene.land, :grazers)
    food(scene, 80.3, 45.0)
    assert wait(fn -> state(scene, parent).energy > 80 end)
    assert length(species(scene, :grazers)) == 2
    # The person cannot add more animals than the cap either.
    Scene.input(scene, %{"add" => "grazers"})
    Process.sleep(200)
    assert length(species(scene, :grazers)) == 2
    assert status(scene).x.full

    # With no grazers, the land has 3 young hunters at most.
    land = land(@empty).land
    assert Enum.count(1..5, fn _ -> Director.born?(land, :hunters) end) == 3
    assert Director.born?(land, :hunters, :founder)
  end

  test "a hunter that touches a grazer eats it" do
    scene = land(@empty)
    grazer = animal(scene, :grazers, {80.0, 45.0}, %{energy: 40.0})
    hunter = animal(scene, :hunters, {80.5, 45.0}, %{energy: 60.0})
    assert wait(fn -> state(scene, grazer) == nil end)
    # 60 + 30 for the meal + a quarter of the energy of the grazer.
    assert state(scene, hunter).energy > 90
    assert wait(fn -> status(scene).x.eaten == 1 end)
    assert Director.animals(scene.land) == 1
  end

  test "a full hunter does not hunt" do
    # With the cap, the hunter has no young, and stays full.
    scene = land(Map.put(@empty, :cap, 2))
    grazer = animal(scene, :grazers, {80.0, 45.0}, %{energy: 40.0})
    hunter = animal(scene, :hunters, {80.8, 45.0}, %{energy: 140.0})
    Process.sleep(500)
    assert state(scene, grazer) != nil
    assert {:ok, %{rules: rules}} = :boids.boid(scene.space, hunter)
    refute List.keymember?(rules, :pursue, 0)
  end

  test "food grows at the rate of the person, and a drought stops it" do
    scene = land(%{@empty | rate: 20.0})
    assert wait(fn -> :ets.info(scene.land.food, :size) >= 10 end)

    Scene.input(scene, %{"drought" => true})
    assert wait(fn -> status(scene).x.drought > 0 end)
    :ets.delete_all_objects(scene.land.food)
    Process.sleep(600)
    assert :ets.info(scene.land.food, :size) == 0

    # The rate is 20 at most, and 0 at least.
    Scene.input(scene, %{"food" => "more"})
    Scene.input(scene, %{"food" => "less"})
    Scene.input(scene, %{"food" => "less"})
    assert wait(fn -> status(scene).x.rate == 16.0 end)
    for _ <- 1..12, do: Scene.input(scene, %{"food" => "less"})
    assert wait(fn -> status(scene).x.rate == 0.0 end)
  end

  test "a rock of the person is in the world, and the food is not in it" do
    scene = land(%{@empty | food: 0})
    food(scene, 41.0, 30.0)
    Scene.input(scene, %{"rock" => [40, 30]})
    assert wait(fn -> :boids.obstacles(scene.space) != [] end)
    assert [%{pos: {40, 30}, radius: 5.0}] = :boids.obstacles(scene.space)
    assert status(scene).h.rocks == [[40.0, 30.0, 5.0]]
    assert :ets.info(scene.land.food, :size) == 0

    # A rock out of the land, a bad message, and more than 12 rocks.
    for message <- [
          %{"rock" => [500, 30]},
          %{"rock" => "here"},
          %{"food" => "lots"},
          %{"add" => "wolves"},
          %{"go" => 1}
        ] do
      Scene.input(scene, message)
    end

    for n <- 1..15, do: Scene.input(scene, %{"rock" => [10 * n, 80]})
    assert wait(fn -> length(:boids.obstacles(scene.space)) == 12 end)
  end

  test "the person adds animals, and starts the land again" do
    scene = land(%{grazers: 4, hunters: 1, food: 5, rate: 0.0})
    Scene.input(scene, %{"add" => "grazers"})
    Scene.input(scene, %{"add" => "hunters"})
    Scene.input(scene, %{"rock" => [80, 45]})
    assert wait(fn -> length(species(scene, :grazers)) == 9 and length(species(scene, :hunters)) == 4 end)

    Scene.input(scene, %{"reset" => true})
    assert wait(fn -> length(species(scene, :grazers)) == 4 and length(species(scene, :hunters)) == 1 end)
    assert :boids.obstacles(scene.space) == []
    assert Director.animals(scene.land) == 5
    status = status(scene)
    assert status.x.born == 0 and status.h.rocks == []
  end

  test "with no food, the grazers die" do
    scene = land(Map.merge(@empty, %{grazers: 8, scale: 3.0}))
    assert wait(fn -> species(scene, :grazers) == [] end)
    assert status(scene).x.starved == 8
  end

  @tag timeout: 120_000
  test "a land with the first settings lives with the two species for 60 seconds" do
    scene = land(%{scale: 3.0})
    # 60 seconds of the land in 20 seconds of the clock.
    Process.sleep(20_000)
    status = status(scene, div(1000, Scene.tick()))
    assert reading(status, "Grazers") > 0
    assert reading(status, "Hunters") > 0
    assert reading(status, "Generation") >= 1
    assert status.x.born > 0
    assert length(status.x.history) >= 15
  end
end
