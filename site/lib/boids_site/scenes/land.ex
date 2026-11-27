defmodule BoidsSite.Scenes.Land do
  @moduledoc """
  Living Land: grazers and hunters live in a land with food. They eat,
  have young, and die. A young gets the genes of its parent with small
  changes. The person does not control an animal: the person changes the
  land (the food, a drought, rocks, more animals), and sees what evolves.

  The example shows these parts of the library:

  - Processes that are born and die all the time. A young is a new
    `gen_boid` that its parent starts. An animal with no energy, or that
    a hunter eats, stops, and the world removes it.
  - The weights of the rules are genes. The rules of an animal come from
    its genes when it is born, and they do not change in its life.
  - A rule that is a function: a grazer goes to the food that it sees,
    which `handle_sense/2` adds to what the grazer perceives.
  - A message from a boid to a boid: a hunter that touches a grazer
    calls its process, and the grazer gives its energy and stops. The id
    of a boid is not its process: the hunter finds the process with the
    function `lookup` of what it perceives.
  - A world that a person changes while it runs: food, rocks, and new
    animals.

  The `Director` is the process of the land: the food, the rate of the
  food, the rocks, the count of the animals, and the history of the
  readings.
  """
  @behaviour BoidsSite.Scene

  @width 160
  @height 90

  @doc "The size of the land."
  def box, do: {@width, @height}

  # --- The genes ---------------------------------------------------------------

  @doc """
  The genes of each species: for each gene, its first value, and its
  limits. The weights of the rules are genes, and so are the maximum
  speed and the distance that an animal sees.
  """
  def genes(:grazers) do
    %{
      speed: {8.0, 3.0, 16.0},
      perception: {10.0, 5.0, 24.0},
      separation: {1.5, 0.0, 5.0},
      cohesion: {0.6, 0.0, 5.0},
      alignment: {0.6, 0.0, 5.0},
      flee: {2.0, 0.0, 6.0},
      food: {1.5, 0.0, 6.0}
    }
  end

  def genes(:hunters) do
    %{
      speed: {12.0, 4.0, 20.0},
      perception: {16.0, 6.0, 30.0},
      separation: {1.0, 0.0, 5.0},
      chase: {1.5, 0.0, 6.0},
      wander: {0.8, 0.0, 5.0}
    }
  end

  @doc "The first genes of a species."
  def first(species), do: Map.new(genes(species), fn {gene, {value, _min, _max}} -> {gene, value} end)

  @doc """
  The genes of a young: the genes of its parent, each with a small
  random change (about 8 % of the range of the gene at most), inside the
  limits of the gene.
  """
  def mutate(species, parent) do
    Map.new(genes(species), fn {gene, {_first, min, max}} ->
      change = (:rand.uniform() * 2 - 1) * 0.08 * (max - min)
      {gene, Float.round(min(max(parent[gene] + change, min), max) * 1.0, 3)}
    end)
  end

  @doc """
  The energy that an animal uses in each second: more with a higher
  speed, and more with a larger perception. This is the cost of a gene,
  so a gene is not good with no limit.
  """
  def cost(:grazers, genes), do: 0.8 + 0.015 * genes.speed * genes.speed + 0.05 * genes.perception
  def cost(:hunters, genes), do: 1.2 + 0.012 * genes.speed * genes.speed + 0.04 * genes.perception

  @doc "The energy of each species: at the birth of a founder, at most, and for a young."
  def energy(:grazers), do: %{start: 40.0, max: 100.0, birth: 70.0, food: 20.0}
  def energy(:hunters), do: %{start: 80.0, max: 150.0, birth: 110.0, meal: 30.0, full: 120.0}

  # --- An animal ----------------------------------------------------------------

  defmodule Animal do
    @moduledoc false
    alias BoidsSite.Scenes.Land

    # The state of an animal, and its first options.
    def options(species, %{id: id, pos: pos, genes: genes, generation: generation, energy: energy, land: land}, rules) do
      %{
        id: id,
        pos: pos,
        vel: :boids_vec.scale(:boids_vec.random_unit(2), genes.speed / 2),
        group: species,
        max_speed: genes.speed,
        min_speed: 1.0,
        perception: genes.perception,
        max_force: 30,
        rules: rules,
        # The generation is what the page shows of the animal.
        data: generation,
        state: %{genes: genes, generation: generation, energy: energy, land: land, species: species, dt: 0.0}
      }
    end

    @doc """
    Act: the animal uses energy for this step. With no energy, it dies.
    With enough energy, it has a young (when the land has a place for
    one), and gives the young half of its energy.
    """
    def live(module, %{pos: pos, state: state} = boid) do
      %{species: species, genes: genes, land: land, dt: dt} = state
      energy = state.energy - Land.cost(species, genes) * dt
      limits = Land.energy(species)

      cond do
        energy <= 0 ->
          die(boid, :starved)

        energy >= limits.birth and Land.Director.born?(land, species) ->
          young = %{
            pos: :boids_vec.add(pos, :boids_vec.scale(:boids_vec.random_unit(2), 1.5)),
            genes: Land.mutate(species, genes),
            generation: state.generation + 1,
            energy: energy / 2,
            land: land
          }

          {:ok, id} = Land.Director.birth(land, module, young)
          GenServer.cast(land.director, {:born, id, species, young.genes, young.generation})
          {:ok, %{boid | state: %{state | energy: energy / 2}}}

        true ->
          {:ok, %{boid | state: %{state | energy: min(energy, limits.max)}}}
      end
    end

    @doc "The animal stops. The land counts one animal less."
    def die(%{id: id, state: %{land: land, species: species}} = boid, why) do
      Land.Director.died(land, species, id, why)
      {:stop, :normal, boid}
    end
  end

  defmodule Grazer do
    @moduledoc """
    A grazer eats the food that it touches. It goes to the food that it
    sees, stays with the herd, and flees from the hunters. The weights of
    these rules, its speed and the distance that it sees are its genes.
    """
    @behaviour :gen_boid
    alias BoidsSite.Scenes.Land

    @impl true
    def init(young) do
      g = young.genes

      rules = [
        {:avoid, 3.0, %{lookahead: 1.0}},
        {:evade, g.flee, %{target: {:group, :hunters}, radius: g.perception}},
        {&Grazer.forage/3, g.food},
        {:separation, g.separation, %{radius: 2.5}},
        {:alignment, g.alignment, %{groups: :same}},
        {:cohesion, g.cohesion, %{groups: :same}},
        # A grazer that sees no food walks, and finds food.
        {:wander, 0.6},
        {:contain, 2.0, %{margin: 6}}
      ]

      {:ok, Land.Animal.options(:grazers, young, rules)}
    end

    # Sense: the nearest food that the grazer sees. A grazer that touches
    # food eats it: the first grazer that takes it from the table of the
    # food gets its energy.
    @impl true
    def handle_sense(%{dt: dt} = seen, %{pos: pos, perception: perception, state: %{land: land} = state0} = boid0) do
      # The seconds of this step, for the energy that the grazer uses.
      state = %{state0 | dt: dt}
      boid = %{boid0 | state: state}

      case Land.Director.nearest_food(land, pos, perception) do
        {id, at, dist} when dist <= 1.5 ->
          case Land.Director.eat(land, id) do
            true ->
              energy = min(state.energy + Land.energy(:grazers).food, Land.energy(:grazers).max)
              {:ok, Map.put(seen, :food, nil), %{boid | state: %{state | energy: energy}}}

            false ->
              {:ok, Map.put(seen, :food, at), boid}
          end

        {_id, at, _dist} ->
          {:ok, Map.put(seen, :food, at), boid}

        nil ->
          {:ok, Map.put(seen, :food, nil), boid}
      end
    end

    @doc "A rule that is a function: the force to the food that the grazer sees, or none."
    def forage(boid, _neighbors, %{food: {_x, _y} = at}), do: :boids_steer.seek(boid, at)
    def forage(_boid, _neighbors, _seen), do: {0.0, 0.0}

    @impl true
    def handle_act(boid), do: Land.Animal.live(__MODULE__, boid)

    # A hunter eats the grazer: the grazer gives its energy, and stops.
    @impl true
    def handle_call(:eat, _from, %{state: %{energy: energy}} = boid) do
      {:stop, :normal, stop} = Land.Animal.die(boid, :eaten)
      {:stop, :normal, {:eaten, energy}, stop}
    end
  end

  defmodule Hunter do
    @moduledoc """
    A hunter hunts the grazers that it sees, and eats a grazer that it
    touches. A hunter with much energy does not hunt: it wanders with the
    other hunters at a distance. The weights of its rules, its speed and
    the distance that it sees are its genes.
    """
    @behaviour :gen_boid
    alias BoidsSite.Scenes.Land

    @impl true
    def init(young) do
      {:ok, Land.Animal.options(:hunters, young, rules(young.genes, :hunts))}
    end

    # The rules of a hunter that hunts, and of a hunter that is full.
    defp rules(g, :hunts) do
      [
        {:avoid, 3.0, %{lookahead: 1.0}},
        {:pursue, g.chase, %{target: {:group, :grazers}, max_time: 1.0}},
        {:separation, g.separation, %{radius: 6, groups: [:hunters]}},
        {:wander, g.wander},
        {:contain, 2.0, %{margin: 6}}
      ]
    end

    defp rules(g, :full) do
      [
        {:avoid, 3.0, %{lookahead: 1.0}},
        {:separation, g.separation, %{radius: 6, groups: [:hunters]}},
        {:wander, g.wander + 0.5},
        {:cruise, 0.5, %{speed: g.speed / 3}},
        {:contain, 2.0, %{margin: 6}}
      ]
    end

    # Decide: a hunter that touches a grazer eats it. A hunter with more
    # than 85 % of its energy is full, and does not hunt.
    @impl true
    def handle_decide(%{neighbors: neighbors, lookup: lookup, dt: dt}, %{state: state0} = boid) do
      limits = Land.energy(:hunters)
      # The seconds of this step, for the energy that the hunter uses.
      state = %{state0 | dt: dt}

      state =
        case Enum.find(neighbors, &(&1.group == :grazers)) do
          %{id: id, dist: dist} when dist <= 1.5 and state.energy < limits.full ->
            # The id of a boid is not its process.
            with {:ok, %{pid: pid}} <- lookup.(id),
                 {:eaten, energy} <- eat(pid) do
              %{state | energy: min(state.energy + limits.meal + energy / 4, limits.max)}
            else
              _ -> state
            end

          _ ->
            state
        end

      mode = if state.energy >= limits.full, do: :full, else: :hunts

      case state[:mode] do
        ^mode -> {:ok, %{boid | state: state}}
        _ -> {:ok, %{:boids_boid.update(boid, %{rules: rules(state.genes, mode)}) | state: Map.put(state, :mode, mode)}}
      end
    end

    # The grazer can stop before it answers: another hunter ate it.
    defp eat(pid) do
      :gen_boid.call(pid, :eat, 500)
    catch
      :exit, _ -> :gone
    end

    @impl true
    def handle_act(boid), do: Land.Animal.live(__MODULE__, boid)
  end

  # --- The director ---------------------------------------------------------------

  defmodule Director do
    @moduledoc """
    The process of the land: the food (in a table that the grazers read
    and take from), the rate of the food, the rocks, the count of the
    animals (a counter that each animal changes at its birth and at its
    death), and the history of the readings of each second.
    """
    use GenServer
    alias BoidsSite.Scenes.Land

    @max_food 90
    @max_rocks 12

    def start_link(space, options), do: GenServer.start_link(__MODULE__, {space, options})
    def status(director, number), do: GenServer.call(director, {:status, number})
    def input(director, message), do: GenServer.cast(director, {:input, message})

    # --- What the animals use (no message to the director) ---------------------

    @doc "The nearest food at the distance `radius` or less of a position: `{id, position, distance}`, or nil."
    def nearest_food(%{food: food}, {x, y}, radius) do
      # The table goes with the director, at the end of the land.
      try do
        nearest(food, x, y, radius)
      catch
        :error, :badarg -> nil
      end
    end

    defp nearest(food, x, y, radius) do
      :ets.foldl(
        fn {id, fx, fy}, best ->
          dx = fx - x
          dy = fy - y
          d2 = dx * dx + dy * dy

          case best do
            {_, _, b2} when b2 <= d2 -> best
            _ when d2 <= radius * radius -> {id, {fx, fy}, d2}
            _ -> best
          end
        end,
        nil,
        food
      )
      |> case do
        nil -> nil
        {id, at, d2} -> {id, at, :math.sqrt(d2)}
      end
    end

    @doc "Take a food from the land. Only one grazer gets it."
    def eat(%{food: food}, id) do
      :ets.take(food, id) != []
    catch
      :error, :badarg -> false
    end

    # The counters of the animals: all the animals, the grazers and the
    # hunters. Each animal changes them at its birth and at its death,
    # with no message.
    @all 1
    @index %{grazers: 2, hunters: 3}

    @doc """
    True when the land has a place for a young of a species, and counts
    it: the count of all the animals is less than the cap. A hunter also
    needs prey: the land has a young hunter only while it has 5 grazers
    or more for each hunter (3 hunters at least). Without this limit, the
    hunters eat all the grazers, and then die. The animals that the
    person adds (`:founder`) need only a place.
    """
    def born?(land, species, how \\ :young)

    def born?(%{count: count, cap: cap}, species, how) do
      prey? =
        species == :grazers or how == :founder or
          :atomics.get(count, @index.hunters) < max(3, div(:atomics.get(count, @index.grazers), 5))

      with true <- prey?,
           n when n <= cap <- :atomics.add_get(count, @all, 1) do
        :atomics.add(count, @index[species], 1)
        true
      else
        false ->
          false

        _full ->
          :atomics.sub(count, @all, 1)
          false
      end
    end

    @doc "The animals of the land: all, or of one species."
    def animals(%{count: count}), do: :atomics.get(count, @all)
    def animals(%{count: count}, species), do: :atomics.get(count, @index[species])

    @doc "Start a young that has its place (see `born?/2`). The result has its id."
    def birth(%{space: space}, module, young) do
      id = make_ref()
      {:ok, _pid} = :gen_boid.start(space, module, Map.put(young, :id, id))
      {:ok, id}
    end

    @doc "An animal died: the land counts one animal less."
    def died(%{count: count, director: director}, species, id, why) do
      :atomics.sub(count, @all, 1)
      :atomics.sub(count, @index[species], 1)
      GenServer.cast(director, {:died, id, why})
    end

    # --- GenServer ------------------------------------------------------------------

    @impl true
    def init({space, options}) do
      options =
        Map.merge(
          %{grazers: 30, hunters: 5, food: 45, rate: 6.0, cap: 70, scale: 1.0, seed: nil},
          options
        )

      if options.seed, do: :rand.seed(:exsss, options.seed)
      :boids.set_time_scale(space, options.scale)
      food = :ets.new(:land_food, [:set, :public, read_concurrency: true, write_concurrency: true])
      count = :atomics.new(3, signed: true)

      land = %{space: space, food: food, count: count, cap: options.cap, director: self()}

      state = %{
        land: land,
        options: options,
        rate: options.rate,
        drought: 0.0,
        grown: 0.0,
        next_food: 0,
        rocks: [],
        animals: %{},
        time: 0.0,
        history: [],
        born: 0,
        eaten: 0,
        starved: 0,
        last: now()
      }

      :timer.send_interval(200, :grow)
      :timer.send_interval(1000, :second)
      {:ok, populate(state)}
    end

    @impl true
    def handle_call({:status, number}, _from, state) do
      {:reply, readings(state, number), state}
    end

    def handle_call(:land, _from, state), do: {:reply, state.land, state}
    def handle_call(:animals, _from, state), do: {:reply, state.animals, state}

    @impl true
    def handle_cast({:born, id, species, genes, generation}, state) do
      animals = Map.put(state.animals, id, %{species: species, genes: genes, generation: generation})
      {:noreply, %{state | animals: animals, born: state.born + 1}}
    end

    def handle_cast({:died, id, why}, state) when why in [:eaten, :starved] do
      {:noreply, Map.update!(%{state | animals: Map.delete(state.animals, id)}, why, &(&1 + 1))}
    end

    def handle_cast({:input, message}, state), do: {:noreply, change(message, state)}

    @impl true
    def handle_info(:grow, state) do
      # The time of the land: the time of the clock with the scale of the
      # time of the world.
      now = now()
      dt = (now - state.last) / 1000 * state.options.scale
      state = %{state | last: now, time: state.time + dt, drought: max(state.drought - dt, 0.0)}
      {:noreply, grow(state, dt)}
    end

    def handle_info(:second, state) do
      point = [round(state.time), count(state, :grazers), count(state, :hunters)]
      {:noreply, %{state | history: Enum.take([point | state.history], 180)}}
    end

    # --- The person changes the land ---------------------------------------------

    defp change(%{"food" => "more"}, state), do: %{state | rate: min(state.rate + 2.0, 20.0)}
    defp change(%{"food" => "less"}, state), do: %{state | rate: max(state.rate - 2.0, 0.0)}
    defp change(%{"drought" => true}, state), do: %{state | drought: 20.0}
    defp change(%{"add" => "grazers"}, state), do: add(state, :grazers, 5)
    defp change(%{"add" => "hunters"}, state), do: add(state, :hunters, 3)

    defp change(%{"rock" => [x, y]}, state) when is_number(x) and is_number(y) and length(state.rocks) < @max_rocks do
      {width, height} = Land.box()

      if x >= 0 and x <= width and y >= 0 and y <= height do
        rock = {x * 1.0, y * 1.0, 5.0}
        :ok = :boids.set_obstacle(state.land.space, length(state.rocks), {x, y}, 5.0)
        # Food under a rock goes.
        for {id, fx, fy} <- :ets.tab2list(state.land.food), :math.sqrt((fx - x) ** 2 + (fy - y) ** 2) < 5.5 do
          :ets.delete(state.land.food, id)
        end

        %{state | rocks: state.rocks ++ [rock]}
      else
        state
      end
    end

    defp change(%{"reset" => true}, state) do
      space = state.land.space
      for %{id: id} <- :boids.snapshot(space, :local), do: :boids.remove(space, id)
      for {_rock, id} <- Enum.with_index(state.rocks), do: :boids.remove_obstacle(space, id)
      :ets.delete_all_objects(state.land.food)
      for index <- 1..3, do: :atomics.put(state.land.count, index, 0)

      populate(%{
        state
        | rate: state.options.rate,
          drought: 0.0,
          rocks: [],
          animals: %{},
          time: 0.0,
          history: []
      })
    end

    defp change(_message, state), do: state

    # --- The land ---------------------------------------------------------------

    defp populate(state) do
      state = add(state, :grazers, state.options.grazers)
      state = add(state, :hunters, state.options.hunters)
      for _ <- 1..state.options.food//1, do: :ets.insert(state.land.food, food(state.rocks))
      state
    end

    # Founders: animals with the first genes of their species, in the
    # places that the cap leaves.
    defp add(state, species, count) do
      {width, height} = Land.box()
      module = if species == :grazers, do: Land.Grazer, else: Land.Hunter

      Enum.reduce(1..count//1, state, fn _, acc ->
        if born?(acc.land, species, :founder) do
          founder = %{
            pos: {8 + :rand.uniform() * (width - 16), 8 + :rand.uniform() * (height - 16)},
            genes: Land.first(species),
            generation: 0,
            energy: Land.energy(species).start,
            land: acc.land
          }

          {:ok, id} = birth(acc.land, module, founder)
          put_in(acc.animals[id], %{species: species, genes: founder.genes, generation: 0})
        else
          acc
        end
      end)
    end

    # New food grows at the rate of the person, with no growth in a
    # drought, up to the most food of the land.
    defp grow(%{drought: drought} = state, _dt) when drought > 0, do: state

    defp grow(state, dt) do
      grown = state.grown + state.rate * dt
      new = trunc(grown)
      room = @max_food - :ets.info(state.land.food, :size)
      for _ <- 1..min(new, room)//1, do: :ets.insert(state.land.food, food(state.rocks))
      %{state | grown: grown - new}
    end

    # A food at a random place that is not in a rock.
    defp food(rocks, tries \\ 5) do
      {width, height} = Land.box()
      {x, y} = {4 + :rand.uniform() * (width - 8), 4 + :rand.uniform() * (height - 8)}
      in_rock = Enum.any?(rocks, fn {rx, ry, radius} -> :math.sqrt((rx - x) ** 2 + (ry - y) ** 2) < radius + 1 end)

      if in_rock and tries > 0,
        do: food(rocks, tries - 1),
        else: {:erlang.unique_integer([:positive]), Float.round(x, 1), Float.round(y, 1)}
    end

    # --- The readings ------------------------------------------------------------

    defp count(state, species), do: Enum.count(state.animals, fn {_id, a} -> a.species == species end)

    defp readings(state, number) do
      grazers = count(state, :grazers)
      hunters = count(state, :hunters)
      generation = state.animals |> Map.values() |> Enum.map(& &1.generation) |> Enum.max(fn -> 0 end)

      food = for {_id, x, y} <- :ets.tab2list(state.land.food), v <- [x, y], do: v

      status = %{
        r: [
          ["Time", "#{round(state.time)} s"],
          ["Grazers", grazers],
          ["Hunters", hunters],
          ["Generation", generation],
          ["Food", div(length(food), 2)]
        ],
        h: %{rocks: for({x, y, radius} <- state.rocks, do: [x, y, radius])},
        x: %{
          food: food,
          rate: state.rate,
          drought: round(state.drought),
          rocks: length(state.rocks),
          full: animals(state.land) >= state.land.cap,
          born: state.born,
          eaten: state.eaten,
          starved: state.starved
        }
      }

      # Each second: the genes of each species, and the history of the
      # populations for the chart.
      if rem(number * BoidsSite.Scene.tick(), 1000) < BoidsSite.Scene.tick() do
        update_in(status.x, &Map.merge(&1, %{genes: averages(state), history: Enum.reverse(state.history)}))
      else
        status
      end
    end

    @doc false
    def averages(state) do
      for species <- [:grazers, :hunters], into: %{} do
        all = for {_id, %{species: ^species, genes: genes}} <- state.animals, do: genes

        averages =
          for gene <- Map.keys(Land.genes(species)), into: %{} do
            value = if all == [], do: nil, else: Float.round(Enum.sum(Enum.map(all, & &1[gene])) / length(all), 2)
            {gene, value}
          end

        {species, averages}
      end
    end

    defp now, do: System.monotonic_time(:millisecond)
  end

  # --- The scene ---------------------------------------------------------------------

  # The argument is nil for a visitor. A test gives options of the
  # director: the numbers of the animals, the food, the rate, the cap,
  # the scale of the time and a seed.
  @impl true
  def start(options) do
    {:ok, world} =
      :boids.start_world(
        bounds: {{0, 0}, {@width, @height}},
        wrap: false,
        cell_size: 12,
        defaults: %{tick: BoidsSite.Scene.tick()}
      )

    space = :boids.space(world)
    {:ok, director} = Director.start_link(space, options || %{})
    {:ok, %{space: space, director: director}}
  end

  @impl true
  def kinds(_scene) do
    [
      %{name: "grazers", shape: "dart", color: "ink", size: 1.3},
      %{name: "hunters", shape: "dart", color: "warm", size: 2.2}
    ]
  end

  # The first genes of each species, for the page: the genes of the
  # animals now show what changed.
  @impl true
  def header(_scene), do: %{first: %{grazers: first(:grazers), hunters: first(:hunters)}}

  @impl true
  def look(_scene, %{group: :hunters, vel: vel}), do: {1, BoidsSite.Scene.angle(vel), 0}
  def look(_scene, %{vel: vel}), do: {0, BoidsSite.Scene.angle(vel), 0}

  @impl true
  def more(%{director: director}, number), do: Director.status(director, number)

  @impl true
  def input(%{director: director}, message), do: Director.input(director, message)
end
