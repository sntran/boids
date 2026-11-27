defmodule BoidsSite.Scenes.Flight do
  @moduledoc """
  Long Flight: a game where the person leads a flock of birds through
  lands with rocks and hawks. The person never controls a bird: between
  two lands, the person takes a card (a rule, or a change of the birds),
  and puts the rules of the flock in an order.

  The example shows these parts of the library:

  - The rules of a boid are data. The deck of the person is the list of
    the rules of each bird, and it changes from land to land.
  - With `combine => priority`, the order of the rules is their
    priority: the first rule uses the force first.
  - `Bird` changes its rules while it runs: with the card "Scatter", a
    bird that sees a hawk has other rules first.
  - A relation: with the card "Elders", each bird follows the nearest
    elder (`boids:relate/4`, the target `{related, follows}`).
  - Messages between boids: a hawk sends `caught` to the process of the
    bird that it touches. The id of a boid is not its process: the hawk
    finds the process with the function `lookup` of what it perceives.
  - Boids that stop: a bird that is safe, caught or in a rock stops, and
    the world removes it.

  The `Director` is the process of a run: it has the land, the deck and
  the counts, and it starts and clears the lands.
  """
  @behaviour BoidsSite.Scene

  @width 160
  @height 90
  @exit 150

  @doc "The steps of a boid in a time in milliseconds."
  def steps(milliseconds), do: max(div(milliseconds, BoidsSite.Scene.tick()), 1)

  defmodule Bird do
    @moduledoc """
    A bird of the flock. Its rules are the deck of the person. It tells
    the director when it is safe (at the exit) or lost (caught by a hawk,
    or in a rock), and stops.
    """
    @behaviour :gen_boid

    @scatter [{:evade, 4.0, %{target: {:group, :hawks}}}, {{:separation, :scatter}, 3.0, %{}}]

    @impl true
    def init(%{deck: deck, director: director} = bird) do
      state = %{director: director, rules: deck.rules, scatter: deck.scatter, mode: :deck}

      {:ok,
       %{
         id: bird.id,
         pos: bird.pos,
         vel: {deck.speed / 2, 0},
         group: :birds,
         data: if(bird.elder, do: :elder, else: :bird),
         max_speed: deck.speed,
         min_speed: 4,
         perception: deck.perception,
         combine: :priority,
         rules: deck.rules,
         state: state
       }}
    end

    # Decide: a bird in a rock is lost. With the card "Scatter", a bird
    # that sees a hawk has the rules of the scatter before its deck.
    @impl true
    def handle_decide(%{neighbors: neighbors, obstacles: rocks}, %{pos: pos, state: state} = boid) do
      hawk = state.scatter and Enum.any?(neighbors, &(&1.group == :hawks))

      cond do
        Enum.any?(rocks, &(:boids_vec.dist(pos, &1.pos) < &1.radius)) -> gone(boid, :lost)
        hawk and state.mode == :deck -> {:ok, mode(boid, :scatter, @scatter ++ state.rules)}
        not hawk and state.mode == :scatter -> {:ok, mode(boid, :deck, state.rules)}
        true -> {:ok, boid}
      end
    end

    # Act: a bird at the exit (x of 150 or more) is safe.
    @impl true
    def handle_act(%{pos: {x, _y}} = boid) when x >= 150, do: gone(boid, :safe)
    def handle_act(boid), do: {:ok, boid}

    # A hawk caught the bird.
    @impl true
    def handle_cast(:caught, boid), do: gone(boid, :lost)

    defp mode(boid, mode, rules), do: %{:boids_boid.update(boid, %{rules: rules}) | state: %{boid.state | mode: mode}}

    defp gone(%{id: id, state: %{director: director}} = boid, how) do
      GenServer.cast(director, {how, id})
      {:stop, :normal, boid}
    end
  end

  defmodule Hawk do
    @moduledoc "A hawk wanders. It hunts a bird that it sees, catches a bird that it touches, then rests for 3 seconds."
    @behaviour :gen_boid
    alias BoidsSite.Scenes.Flight

    @hunt [{:avoid, 4.0, %{lookahead: 1.5}}, {:pursue, 1.0, %{target: {:group, :birds}}}]
    @rest [{:avoid, 4.0, %{lookahead: 1.5}}, {:wander, 1.0}, {:cruise, 0.5, %{speed: 4.0}}]

    @impl true
    def init(pos) do
      {:ok,
       %{
         pos: pos,
         group: :hawks,
         perception: 22,
         max_speed: 13,
         rules: @rest,
         combine: :priority,
         state: %{rest: 0, mode: :rests}
       }}
    end

    @impl true
    def handle_decide(%{neighbors: neighbors, lookup: lookup}, %{state: %{rest: rest, mode: mode} = state} = boid) do
      birds = Enum.filter(neighbors, &(&1.group == :birds))

      cond do
        rest > 0 ->
          {:ok, mode(boid, :rests, @rest, mode, %{state | rest: rest - 1})}

        match?([%{dist: dist} | _] when dist <= 1.5, birds) ->
          # The id of a boid is not its process.
          with {:ok, %{pid: pid}} <- lookup.(hd(birds).id), do: :gen_boid.cast(pid, :caught)
          {:ok, mode(boid, :rests, @rest, mode, %{state | rest: Flight.steps(3000)})}

        birds != [] ->
          {:ok, mode(boid, :hunts, @hunt, mode, state)}

        true ->
          {:ok, mode(boid, :rests, @rest, mode, state)}
      end
    end

    # The rules of the boid change only when the mode changes.
    defp mode(boid, mode, _rules, mode, state), do: %{boid | state: state}

    defp mode(boid, mode, rules, _other, state),
      do: %{:boids_boid.update(boid, %{rules: rules}) | state: %{state | mode: mode}}
  end

  defmodule Director do
    @moduledoc """
    The process of a run: the land, the deck of the person, the phase
    (`flying`, `choosing` or `over`), the counts of the birds, and the
    cards of the offer.
    """
    use GenServer
    alias BoidsSite.Scenes.Flight

    @cards [
      %{id: :avoid, title: "Avoid the rocks", text: "The birds fly around the rocks."},
      %{id: :evade, title: "Evade the hawks", text: "A bird moves away from where a hawk will be."},
      %{id: :dodge, title: "Dodge", text: "A bird moves away from a boid that comes too near."},
      %{id: :cohesion, title: "Stay together", text: "The weight of cohesion + 0.5."},
      %{id: :separation, title: "Keep a distance", text: "The weight of separation + 0.5."},
      %{id: :alignment, title: "One direction", text: "The weight of alignment + 0.5."},
      %{id: :flow, title: "Go to the exit", text: "The weight of the rule to the exit (flow) + 0.5."},
      %{id: :speed, title: "Fast wings", text: "The maximum speed of the birds + 2."},
      %{id: :eyes, title: "Sharp eyes", text: "The birds see 4 units more."},
      %{id: :chicks, title: "New chicks", text: "5 more birds in the next land."},
      %{id: :scatter, title: "Scatter", text: "While a bird sees a hawk, it evades and keeps a distance first."},
      %{id: :elders, title: "Elders", text: "3 birds are elders. Each other bird follows the nearest elder."}
    ]

    def start_link(space, options), do: GenServer.start_link(__MODULE__, {space, options})
    def status(director), do: GenServer.call(director, :status)
    def input(director, message), do: GenServer.cast(director, {:input, message})

    @doc "The deck of a new run."
    def deck do
      %{
        rules: [
          # To the exit: each bird flies to the east.
          {:flow, 1.0, %{field: {1, 0}}},
          {:separation, 1.5, %{radius: 3}},
          {:alignment, 1.0, %{}},
          {:cohesion, 1.0, %{}}
        ],
        speed: 10,
        perception: 10,
        scatter: false,
        elders: false
      }
    end

    @doc "The deck with a card."
    def take(deck, card) when card in [:cohesion, :separation, :alignment, :flow, :avoid, :evade, :dodge] do
      new = %{
        avoid: {:avoid, 4.0, %{lookahead: 1.5}},
        evade: {:evade, 3.0, %{target: {:group, :hawks}, radius: 16}},
        dodge: {:dodge, 2.0, %{}}
      }

      # A card for a rule that the deck has adds 0.5 to its weight.
      case List.keyfind(deck.rules, card, 0) do
        {^card, weight, options} -> %{deck | rules: List.keyreplace(deck.rules, card, 0, {card, weight + 0.5, options})}
        nil -> %{deck | rules: deck.rules ++ [new[card]]}
      end
    end

    def take(deck, :speed), do: %{deck | speed: deck.speed + 2}
    def take(deck, :eyes), do: %{deck | perception: deck.perception + 4}
    def take(deck, :scatter), do: %{deck | scatter: true}
    def take(%{elders: true} = deck, :elders), do: deck

    def take(deck, :elders) do
      %{deck | elders: true, rules: deck.rules ++ [{:leader, 1.5, %{target: {:related, :follows}}}]}
    end

    def take(deck, _card), do: deck

    # --- GenServer -------------------------------------------------------

    @impl true
    def init({space, options}) do
      state = %{
        space: space,
        options: Map.merge(%{birds: 30, rocks: nil, hawks: nil, time: 90_000, start: {5, 25}}, options),
        land: 0,
        deck: deck(),
        phase: :choosing,
        next: 0,
        alive: MapSet.new(),
        hawks: [],
        rocks: [],
        safe: 0,
        lost: 0,
        offer: [],
        picked: false,
        deadline: 0
      }

      {:ok, land(%{state | next: state.options.birds})}
    end

    @impl true
    def handle_call(:status, _from, state) do
      state = late(state)
      left = if state.phase == :flying, do: max(div(state.deadline - now(), 1000), 0), else: 0

      status = %{
        r: [
          ["Land", state.land],
          ["Birds", MapSet.size(state.alive)],
          ["Safe", state.safe],
          ["Lost", state.lost],
          ["Seconds", left]
        ],
        h: %{rocks: for({x, y, radius} <- state.rocks, do: [x, y, radius])},
        x: %{
          phase: state.phase,
          land: state.land,
          safe: state.safe,
          lost: state.lost,
          picked: state.picked,
          offer: for(card <- state.offer, do: Map.take(card, [:title, :text])),
          deck: for({name, weight, _options} <- state.deck.rules, do: %{name: name, weight: weight}),
          speed: state.deck.speed,
          perception: state.deck.perception,
          scatter: state.deck.scatter,
          elders: state.deck.elders
        }
      }

      {:reply, status, state}
    end

    @impl true
    def handle_cast({how, id}, state) when how in [:safe, :lost] do
      # A bird tells one time that it is safe or lost.
      if MapSet.member?(state.alive, id) do
        state = %{state | alive: MapSet.delete(state.alive, id)} |> Map.update!(how, &(&1 + 1))
        {:noreply, if(MapSet.size(state.alive) == 0, do: finish(state), else: state)}
      else
        {:noreply, state}
      end
    end

    def handle_cast({:input, %{"pick" => number}}, %{phase: :choosing, picked: false} = state)
        when is_integer(number) do
      case Enum.at(state.offer, number) do
        %{id: :chicks} -> {:noreply, %{state | next: state.next + 5, picked: true}}
        %{id: card} -> {:noreply, %{state | deck: take(state.deck, card), picked: true}}
        nil -> {:noreply, state}
      end
    end

    def handle_cast({:input, %{"order" => names}}, %{phase: :choosing, deck: deck} = state) when is_list(names) do
      # The rules in the order of the person. A name that is not a rule
      # of the deck has no effect, and a rule with no name stays last.
      named = for name <- names, rule = Enum.find(deck.rules, &(to_string(elem(&1, 0)) == name)), do: rule
      rules = Enum.uniq(named) ++ (deck.rules -- named)
      {:noreply, %{state | deck: %{deck | rules: rules}}}
    end

    def handle_cast({:input, %{"go" => true}}, %{phase: :choosing} = state), do: {:noreply, land(state)}

    def handle_cast({:input, %{"go" => true}}, %{phase: :over} = state) do
      {:noreply, land(%{state | land: 0, deck: deck(), next: state.options.birds})}
    end

    def handle_cast(_message, state), do: {:noreply, state}

    # --- A land -----------------------------------------------------------

    # Start the next land: its rocks, its hawks, and the birds of the flock.
    defp land(%{space: space, options: options, deck: deck} = state) do
      number = state.land + 1

      for {_rock, id} <- Enum.with_index(state.rocks), do: :boids.remove_obstacle(space, id)

      rocks =
        for _ <- 1..(options.rocks || number + 2)//1 do
          {45 + :rand.uniform() * 80, 8 + :rand.uniform() * 74, 4 + :rand.uniform() * 4}
        end

      for {{x, y, radius}, id} <- Enum.with_index(rocks), do: :ok = :boids.set_obstacle(space, id, {x, y}, radius)

      hawks =
        for _ <- 1..(options.hawks || 1 + div(number, 2))//1 do
          {:ok, pid} = :gen_boid.start(space, Hawk, {60 + :rand.uniform() * 80, :rand.uniform() * 90})
          pid
        end

      {from, to} = options.start

      birds =
        for n <- 1..state.next do
          id = make_ref()
          pos = {from + :rand.uniform() * (to - from), 5 + :rand.uniform() * 80}
          elder = deck.elders and n <= 3
          {:ok, _pid} = :gen_boid.start(space, Bird, %{id: id, pos: pos, deck: deck, director: self(), elder: elder})
          {id, pos, elder}
        end

      # With the card "Elders", each bird follows the nearest elder.
      elders = for {id, pos, true} <- birds, do: {id, pos}

      for {id, pos, false} <- birds, elders != [] do
        {elder, _pos} = Enum.min_by(elders, fn {_id, at} -> :boids_vec.dist(pos, at) end)
        :ok = :boids.relate(space, id, :follows, elder)
      end

      %{
        state
        | land: number,
          phase: :flying,
          rocks: rocks,
          hawks: hawks,
          alive: MapSet.new(birds, &elem(&1, 0)),
          safe: 0,
          lost: 0,
          offer: [],
          picked: false,
          deadline: now() + options.time
      }
    end

    # After the time of a land, the birds that are still there are lost.
    defp late(%{phase: :flying, deadline: deadline, space: space} = state) do
      if now() > deadline do
        for id <- state.alive, do: :boids.remove(space, id)
        finish(%{state | lost: state.lost + MapSet.size(state.alive), alive: MapSet.new()})
      else
        state
      end
    end

    defp late(state), do: state

    # The end of a land: the hawks go. With safe birds, the person takes
    # a card. With no safe bird, the run is over.
    defp finish(%{space: space} = state) do
      for %{id: id, group: :hawks} <- :boids.snapshot(space, :local), do: :boids.remove(space, id)

      if state.safe > 0 do
        %{state | phase: :choosing, next: state.safe, hawks: [], offer: offer(state.deck)}
      else
        %{state | phase: :over, hawks: [], offer: []}
      end
    end

    # 3 cards. A card that the deck can have one time only is not in the
    # offer again. While the deck has no rule for the rocks, the offer has
    # that card: without it, the rocks take a third of the flock.
    defp offer(deck) do
      cards = Enum.reject(@cards, &((&1.id == :scatter and deck.scatter) or (&1.id == :elders and deck.elders)))

      case List.keymember?(deck.rules, :avoid, 0) do
        true -> Enum.take_random(cards, 3)
        false -> Enum.shuffle([card(:avoid) | Enum.take_random(Enum.reject(cards, &(&1.id == :avoid)), 2)])
      end
    end

    @doc "A card of the game, from its id."
    def card(id), do: Enum.find(@cards, &(&1.id == id))

    defp now, do: System.monotonic_time(:millisecond)
  end

  # --- The scene ---------------------------------------------------------

  # The argument is nil for a visitor. A test gives options of the
  # director: the number of birds, rocks and hawks, the time of a land,
  # and where the birds start.
  @impl true
  def start(options) do
    {:ok, world} =
      :boids.start_world(bounds: {{0, 0}, {@width, @height}}, wrap: false, defaults: %{tick: BoidsSite.Scene.tick()})

    space = :boids.space(world)
    {:ok, director} = Director.start_link(space, options || %{})
    {:ok, %{space: space, director: director}}
  end

  @impl true
  def kinds(_scene) do
    [
      %{name: "birds", shape: "dart", color: "ink", size: 1.2},
      %{name: "hawks", shape: "dart", color: "warm", size: 2.4},
      %{name: "elders", shape: "dart", color: "cool", size: 1.6}
    ]
  end

  # The exit of a land, for the page.
  @impl true
  def header(_scene), do: %{zones: [[@exit, 0, @width, @height, "cool"]]}

  @impl true
  def look(_scene, %{group: :hawks, vel: vel}), do: {1, BoidsSite.Scene.angle(vel), 0}
  def look(_scene, %{data: :elder, vel: vel}), do: {2, BoidsSite.Scene.angle(vel), 0}
  def look(_scene, %{vel: vel}), do: {0, BoidsSite.Scene.angle(vel), 0}

  @impl true
  def more(%{director: director}, _number), do: Director.status(director)

  @impl true
  def input(%{director: director}, message), do: Director.input(director, message)
end
