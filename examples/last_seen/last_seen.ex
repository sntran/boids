defmodule BoidsExamples.Games.LastSeen do
  @moduledoc """
  Last Seen: a game of theft and police with sightings. The person is a
  thief in a busy market square. The thief steals purses, and leaves
  through a gate. The police do not see all the square: they know only
  what the citizens tell them.

  The example shows these parts of the library:

  - Information that goes from boid to boid. A citizen that sees a theft
    becomes a witness. After a call of 1 to 4 seconds, its sighting (the
    place, the time and the coat of the thief) goes to the officer that
    is nearest to it. Officers share the newest sighting that they know
    with the officers that they see: the data of a boid is what its
    neighbors see.
  - Boids that act on old information. An officer goes to the newest
    sighting that it knows. The thief is no longer there.
  - A crowd as cover. A citizen notices a person that runs near it, or a
    person in front of it with the coat of the last sighting. A thief
    that walks with the crowd is hard to see, and a new coat makes the
    old sightings false.
  - A boid that a person controls: the force of the thief is a rule of
    its own, a function that reads the keys.

  The `Director` is the process of a level: the stalls and their purses,
  the loot, the sightings that the police got, and the end of the level.
  """
  @behaviour BoidsExamples.Scene
  use BoidsExamples.Game

  @impl BoidsExamples.Game
  def info do
    %{
      slug: "last-seen",
      title: "Last Seen",
      tag: "Keys",
      pitch:
        "Steal purses in a busy market, then leave through a gate. The police know only what the witnesses tell them: walk with the crowd, and change your coat.",
      shows:
        "information that goes from boid to boid with delays (a witness, a call, officers that share), boids that act on old information, and a crowd as cover.",
      icon:
        ~S(<rect class="mark-rock" x="6" y="6" width="14" height="10" rx="2"/><rect class="mark-rock" x="36" y="40" width="14" height="10" rx="2"/><circle class="mark-ink" cx="14" cy="34" r="4"/><circle class="mark-ink" cx="24" cy="44" r="4"/><circle class="mark-ink" cx="40" cy="22" r="4"/><circle class="mark-warm" cx="30" cy="28" r="5"/><circle class="mark-cool" cx="48" cy="12" r="4"/><circle class="mark-cool" cx="8" cy="50" r="4"/>),
      order: 25
    }
  end

  @width 160
  @height 90

  # The coats of the thief, and their colors on the page.
  @coats [:red, :green, :blue]
  @colors %{red: "warm", green: "leaf", blue: "ink"}

  @doc "The steps of a boid in a time in milliseconds."
  def steps(milliseconds), do: max(div(milliseconds, BoidsExamples.Scene.tick()), 1)

  @doc "The coats of the thief, in their order."
  def coats, do: @coats

  @doc "The name of a coat for the page."
  def coat_name(:blue), do: "dark blue"
  def coat_name(coat), do: Atom.to_string(coat)

  @doc "The time now, in milliseconds."
  def now, do: System.monotonic_time(:millisecond)

  @doc "The gates of the square: a thief with the loot of the level leaves through one of them."
  def gates do
    [
      {"West gate", {0, 37, 5, 53}},
      {"East gate", {155, 37, 160, 53}},
      {"North gate", {70, 85, 90, 90}},
      {"South gate", {70, 0, 90, 5}}
    ]
  end

  @doc "True when the point is in a gate."
  def in_gate?({x, y}),
    do: Enum.any?(gates(), fn {_name, {x0, y0, x1, y1}} -> x >= x0 and x <= x1 and y >= y0 and y <= y1 end)

  defmodule Thief do
    @moduledoc """
    The thief. The person moves it with the keys: `left`, `right`, `up`,
    `down`, and `run` (fast, but each citizen that sees it tells the
    police). Its data shows its coat, its speed, and the time of its last
    theft: the citizens and the officers that see it decide from that
    data. It tells the director when it is in a gate, and when an officer
    catches it.
    """
    @behaviour :gen_boid
    alias BoidsExamples.Games.LastSeen

    @walk 3.8
    @run 8.0

    @impl true
    def init(%{pos: pos, coat: coat, director: director}) do
      {:ok,
       %{
         pos: pos,
         group: :thief,
         perception: 6,
         max_speed: @run,
         max_force: 60,
         rules: [{:avoid, 3.0, %{lookahead: 0.6}}, {&Thief.legs/3, 1.0}],
         combine: :priority,
         data: %{coat: coat, speed: 0.0, running: false, theft_at: nil},
         state: %{keys: %{}, director: director, stopped: false}
       }}
    end

    @doc "The walk of the thief, which is the speed of the crowd."
    def walk, do: @walk

    @doc """
    The force of the thief: to the velocity that the keys ask for. With no
    key, or after the end of the level, the thief stops.
    """
    def legs(%{vel: vel, state: %{keys: keys, stopped: stopped}}, _neighbors, _seen) do
      direction =
        if stopped do
          {0.0, 0.0}
        else
          x = if(keys[:right], do: 1.0, else: 0.0) - if(keys[:left], do: 1.0, else: 0.0)
          y = if(keys[:up], do: 1.0, else: 0.0) - if(keys[:down], do: 1.0, else: 0.0)
          :boids_vec.normalize({x, y})
        end

      speed = if keys[:run], do: @run, else: @walk
      :boids_vec.scale(:boids_vec.sub(:boids_vec.scale(direction, speed), vel), 5.0)
    end

    # Act: the thief stays in the square, shows its speed, and tells the
    # director when it is in a gate.
    @impl true
    def handle_act(%{pos: {x, y}, vel: vel, data: data, state: state} = boid) do
      pos = {min(max(x, 0.5), 159.5), min(max(y, 0.5), 89.5)}
      speed = :boids_vec.norm(vel)
      if LastSeen.in_gate?(pos) and not state.stopped, do: GenServer.cast(state.director, :at_gate)
      {:ok, %{boid | pos: pos, data: %{data | speed: speed, running: speed > 5.5}}}
    end

    @impl true
    def handle_cast({:keys, keys}, %{state: state} = boid), do: {:noreply, %{boid | state: %{state | keys: keys}}}

    # A theft: the citizens and the officers that see the thief now see it.
    def handle_cast(:stole, %{data: data} = boid), do: {:noreply, %{boid | data: %{data | theft_at: LastSeen.now()}}}

    def handle_cast({:coat, coat}, %{data: data} = boid), do: {:noreply, %{boid | data: %{data | coat: coat}}}
    def handle_cast(:stop, %{state: state} = boid), do: {:noreply, %{boid | state: %{state | stopped: true}}}
    def handle_cast(:caught, %{state: %{stopped: true}} = boid), do: {:noreply, boid}

    def handle_cast(:caught, %{state: state} = boid) do
      GenServer.cast(state.director, :caught)
      {:noreply, %{boid | state: %{state | stopped: true}}}
    end
  end

  defmodule Citizen do
    @moduledoc """
    A citizen walks from stall to stall, and stays at a stall for some
    seconds. Some citizens have a purse: the thief can steal it.

    A citizen that sees something becomes a witness:

    - a theft, at the moment of the theft;
    - a person that runs, near it;
    - a person near it with the coat of the last sighting of the police
      (the director tells each citizen that coat).

    A witness stands and calls the police. The call takes some seconds.
    Then its sighting goes to the director, with the place, the time and
    the coat of the thief at the moment that the witness saw it: the
    thief can be far from there now. After a call, a citizen reports
    nothing for some seconds.
    """
    @behaviour :gen_boid
    alias BoidsExamples.Games.LastSeen

    @walk 3.4
    @remember 20_000

    @impl true
    def init(%{pos: pos, purse: purse, stalls: stalls, director: director} = options) do
      speed = Map.get(options, :speed, @walk)
      call = Map.get(options, :call, {1000, 3000})

      state = %{
        stalls: stalls,
        director: director,
        speed: speed,
        call: call,
        wanted: nil,
        wanted_at: nil,
        calling: nil,
        rest: 0,
        shop: 0
      }

      boid = %{
        pos: pos,
        vel: :boids_vec.scale(:boids_vec.random_unit(2), speed * 0.5),
        group: :citizens,
        perception: 14,
        max_speed: speed,
        data: %{purse: purse, role: :citizen},
        state: state
      }

      {:ok, Map.merge(boid, walk_to(next(stalls, pos), speed))}
    end

    @doc "The rules of a citizen that walks to a place."
    def walk_to(target, speed) do
      %{
        max_speed: speed,
        rules: [
          {:avoid, 3.0, %{lookahead: 1.2}},
          {:arrive, 1.0, %{target: target, slow_radius: 4}},
          {:separation, 1.2, %{radius: 2.2}},
          {:wander, 0.3},
          {:contain, 2.0, %{margin: 4}}
        ]
      }
    end

    # A citizen at a stall, or a witness that calls: it stands.
    defp stand(speed) do
      %{max_speed: min(speed, 0.6), rules: [{:avoid, 3.0, %{lookahead: 1.0}}, {:separation, 1.2, %{radius: 2.2}}]}
    end

    # A place in front of a random stall.
    defp next([], _pos), do: {80.0, 45.0}

    defp next(stalls, _pos) do
      %{pos: pos, r: r} = Enum.random(stalls)
      :boids_vec.add(pos, :boids_vec.scale(:boids_vec.random_unit(2), r + 3))
    end

    @impl true
    def handle_decide(%{neighbors: neighbors}, %{state: state} = boid) do
      thief = Enum.find(neighbors, &(&1.group == :thief))
      state = %{state | rest: max(state.rest - 1, 0)}
      boid = %{boid | state: state}

      what = if thief != nil and state.calling == nil, do: notice(thief, boid)

      cond do
        state.calling != nil -> {:ok, call(boid)}
        what != nil -> {:ok, witness(boid, thief, what)}
        true -> {:ok, shop(boid)}
      end
    end

    # What the citizen notices of the thief, or nil. It sees a coat only
    # in front of it, or very near, and it forgets the coat after some
    # seconds with no new sighting.
    defp notice(%{dist: dist, data: data, offset: offset}, %{vel: vel, state: state}) do
      now = LastSeen.now()

      cond do
        data.theft_at != nil and now - data.theft_at < 700 and dist <= 10 -> :theft
        state.rest > 0 -> nil
        data.running and dist <= 10 -> :running
        state.wanted == nil or data.coat != state.wanted or now - state.wanted_at > @remember -> nil
        dist <= 2.5 -> :coat
        dist <= 4.5 and :boids_vec.dot(vel, offset) > 0 -> :coat
        true -> nil
      end
    end

    # The citizen becomes a witness: it stands, and calls.
    defp witness(%{state: state, data: data} = boid, thief, what) do
      {low, high} = state.call
      steps = LastSeen.steps(low + :rand.uniform(max(high - low, 1)))
      sighting = %{pos: thief.pos, coat: thief.data.coat, what: what, time: LastSeen.now()}
      boid = :boids_boid.update(boid, stand(state.speed))
      %{boid | state: %{state | calling: %{left: steps, sighting: sighting}}, data: %{data | role: :witness}}
    end

    # A witness at the end of its call: the sighting goes to the police.
    defp call(%{state: %{calling: %{left: 0, sighting: sighting}} = state, data: data, pos: pos} = boid) do
      GenServer.cast(state.director, {:sighting, sighting, pos})
      boid = :boids_boid.update(boid, walk_to(next(state.stalls, pos), state.speed))
      %{boid | state: %{state | calling: nil, rest: LastSeen.steps(5000), shop: 0}, data: %{data | role: :citizen}}
    end

    defp call(%{state: %{calling: calling} = state} = boid) do
      %{boid | state: %{state | calling: %{calling | left: calling.left - 1}}}
    end

    # A citizen that is at its stall stays there some seconds, then walks
    # to another stall.
    defp shop(%{state: %{shop: shop} = state} = boid) when shop > 1, do: %{boid | state: %{state | shop: shop - 1}}

    defp shop(%{state: %{shop: 1} = state, pos: pos} = boid) do
      boid = :boids_boid.update(boid, walk_to(next(state.stalls, pos), state.speed))
      %{boid | state: %{state | shop: 0}}
    end

    defp shop(%{state: state, pos: pos, rules: rules} = boid) do
      case List.keyfind(rules, :arrive, 0) do
        {:arrive, _, %{target: target}} ->
          if :boids_vec.dist(pos, target) < 2.0 do
            boid = :boids_boid.update(boid, stand(state.speed))
            %{boid | state: %{state | shop: LastSeen.steps(2000 + :rand.uniform(3000))}}
          else
            boid
          end

        nil ->
          boid
      end
    end

    @impl true
    def handle_cast(:steal, %{data: data} = boid), do: {:noreply, %{boid | data: %{data | purse: false}}}

    def handle_cast({:wanted, coat}, %{state: state} = boid) do
      {:noreply, %{boid | state: %{state | wanted: coat, wanted_at: LastSeen.now()}}}
    end
  end

  defmodule Officer do
    @moduledoc """
    An officer of the police. It knows the sightings that a witness
    gave it, the sightings that it made, and the newest sighting of each
    officer that it sees: officers share what they know. Its data shows
    its mode and the newest sighting that it knows.

    - With no sighting, it patrols.
    - With sightings, it goes to the newest one. At the place, it looks,
      and then it forgets that sighting.
    - It chases a thief that it sees near it, when the thief has a coat
      of a sighting that it knows, runs, or steals at that moment. It
      runs a bit faster than the thief, and catches the thief that it
      touches. After some seconds of a chase it is tired: for some
      seconds it chases nobody.
    - A thief that it no longer sees: it goes to the place where it saw
      the thief last.
    """
    @behaviour :gen_boid
    alias BoidsExamples.Games.LastSeen

    @forget 40_000
    @tire 6000
    @rest 3000

    @impl true
    def init(%{pos: pos} = options) do
      state = %{
        known: [],
        checked: [],
        mode: :patrol,
        lost: nil,
        since: nil,
        tired: nil,
        speed: Map.get(options, :speed, 9.0)
      }

      {:ok,
       %{
         pos: pos,
         group: :officers,
         perception: 30,
         max_force: 40,
         data: %{mode: :patrol, newest: nil},
         state: state
       }
       |> Map.merge(rules(:patrol, nil, state.speed))}
    end

    @doc "The rules and the speed of an officer in a mode."
    def rules(:patrol, _target, _speed) do
      %{
        max_speed: 2.6,
        rules: [
          {:avoid, 3.0, %{lookahead: 1.2}},
          {:contain, 2.0, %{margin: 8}},
          {:separation, 1.0, %{radius: 2.5}},
          {:wander, 1.0},
          {:cruise, 0.5, %{speed: 2.4}}
        ]
      }
    end

    def rules(:search, target, _speed) do
      %{
        max_speed: 7.0,
        rules: [
          {:avoid, 3.0, %{lookahead: 1.0}},
          {:arrive, 1.0, %{target: target, slow_radius: 3}},
          {:separation, 1.0, %{radius: 2.5}}
        ]
      }
    end

    def rules(:chase, target, speed) do
      %{max_speed: speed, rules: [{:avoid, 2.0, %{lookahead: 0.5}}, {:pursue, 1.0, %{target: {:boid, target}}}]}
    end

    @impl true
    def handle_decide(%{neighbors: neighbors, lookup: lookup}, %{state: state, pos: pos} = boid) do
      now = LastSeen.now()
      # Learn the newest sighting of each officer that it sees, and forget
      # old sightings.
      shared = for %{group: :officers, data: %{newest: %{} = s}} <- neighbors, do: s
      known = Enum.reduce(shared, state.known, &learn(&1, &2, state.checked))
      known = Enum.filter(known, &(now - &1.time < @forget))
      state = %{state | known: known}
      thief = Enum.find(neighbors, &(&1.group == :thief))

      cond do
        thief != nil and (state.tired == nil or now >= state.tired) and knows?(thief, state, now) ->
          if thief.dist <= 1.6 do
            with {:ok, %{pid: pid}} <- lookup.(thief.id), do: :gen_boid.cast(pid, :caught)
          end

          # Its own sighting: one for each officer, with the newest place.
          own = %{pos: thief.pos, coat: thief.data.coat, what: :officer, time: now, id: {:officer, self()}}
          since = if state.mode == :chase, do: state.since, else: now
          state = %{state | known: learn(own, state.known, []), lost: thief.pos, since: since}

          if now - since > @tire do
            # Tired: it goes to the place of the thief, and for some
            # seconds it chases nobody.
            {:ok, mode(boid, :search, thief.pos, %{state | lost: nil, tired: now + @rest})}
          else
            {:ok, mode(boid, :chase, thief.id, state)}
          end

        state.mode == :chase and state.lost != nil ->
          # The thief is gone from its sight: to the place where it saw it last.
          {:ok, mode(boid, :search, state.lost, %{state | lost: nil})}

        state.known != [] ->
          [newest | rest] = state.known

          if :boids_vec.dist(pos, newest.pos) < 4.0 and state.mode == :search do
            # Nothing at the place: the sighting is old. The officer
            # forgets it, and does not learn it again from other officers.
            checked = Enum.take([{newest.id, newest.time} | state.checked], 20)
            {:ok, mode(boid, :patrol, nil, %{state | known: rest, checked: checked})}
          else
            {:ok, mode(boid, :search, newest.pos, state)}
          end

        true ->
          {:ok, mode(boid, :patrol, nil, state)}
      end
    end

    # The officer knows the thief: a coat of its sightings, a thief that
    # runs near it, or a theft in front of it.
    defp knows?(%{dist: dist, data: data}, %{known: known}, now) do
      cond do
        dist > 12 -> false
        data.theft_at != nil and now - data.theft_at < 700 -> true
        data.running and dist <= 9 -> true
        true -> Enum.any?(known, &(&1.coat == data.coat))
      end
    end

    # Add a sighting to what the officer knows, the newest first. A newer
    # sighting with the same id (an officer that chases) replaces the old
    # one. A sighting that the officer checked is not added again.
    defp learn(%{id: id, time: time} = sighting, known, checked) do
      cond do
        {id, time} in checked -> known
        Enum.any?(known, &(&1.id == id and &1.time >= time)) -> known
        true -> [sighting | Enum.reject(known, &(&1.id == id))] |> Enum.sort_by(& &1.time, :desc) |> Enum.take(6)
      end
    end

    # A change of mode or of target changes the rules. The same mode with
    # the same target keeps them.
    defp mode(%{state: %{mode: old}, rules: rules} = boid, mode, target, state) do
      same =
        old == mode and
          case {mode, rules} do
            {:patrol, _} -> true
            {:search, _} -> match?({:arrive, _, %{target: ^target}}, List.keyfind(rules, :arrive, 0))
            {:chase, _} -> match?({:pursue, _, %{target: {:boid, ^target}}}, List.keyfind(rules, :pursue, 0))
          end

      boid = if same, do: boid, else: :boids_boid.update(boid, rules(mode, target, state.speed))
      %{boid | state: %{state | mode: mode}, data: %{mode: mode, newest: List.first(state.known)}}
    end

    @impl true
    def handle_cast({:sighting, sighting}, %{state: state, data: data} = boid) do
      known = learn(sighting, state.known, state.checked)
      {:noreply, %{boid | state: %{state | known: known}, data: %{data | newest: List.first(known)}}}
    end
  end

  defmodule Director do
    @moduledoc """
    The process of a level. It has the stalls and their purses, the loot,
    the sightings that the police got, and the state of the level:
    `sneaking`, `caught` or `escaped`.

    - The thief asks it for a theft (the key Space): a purse of a citizen
      or of a stall near the thief.
    - A witness gives it a sighting at the end of its call. The director
      gives the sighting to the officer that is nearest to the witness,
      and tells each citizen the coat of the thief.
    - The thief in a gate with the loot of the level escapes.
    """
    use GenServer
    alias BoidsExamples.Games.LastSeen
    alias BoidsExamples.Games.LastSeen.{Citizen, Officer, Thief}

    @show 30_000
    @note 2500
    # The thief steals only when it stops: its speed is this or less.
    @still 1.0
    @keys %{"left" => :left, "right" => :right, "up" => :up, "down" => :down, "run" => :run}

    @doc """
    The levels. Each next level has more officers, fewer citizens, and
    faster calls. A stall is `{name, {x, y}, radius, kind}`, with the kind
    `:goods`, `:purse` (a stall with a purse) or `:coats` (a new coat).
    """
    def levels do
      stalls = [
        {"Fish", {38, 24}, 5, :goods},
        {"Fruit", {38, 66}, 5, :goods},
        {"Bread", {80, 66}, 5, :goods},
        {"Coats", {80, 24}, 5, :coats},
        {"Spices", {122, 24}, 5, :goods},
        {"Pots", {122, 66}, 5, :goods},
        {"Cheese", {80, 45}, 4, :goods}
      ]

      [
        %{
          citizens: 34,
          purses: 5,
          officers: [{120, 45}, {60, 10}, {100, 80}],
          call: {1500, 3500},
          need: 3,
          changes: 1,
          stalls: purse(stalls, ["Fish", "Pots"])
        },
        %{
          citizens: 30,
          purses: 4,
          officers: [{120, 45}, {60, 10}, {100, 80}, {40, 45}],
          call: {1000, 2500},
          need: 4,
          changes: 2,
          stalls: purse(stalls, ["Fruit", "Spices"])
        },
        %{
          citizens: 26,
          purses: 4,
          officers: [{120, 45}, {60, 10}, {100, 80}, {40, 45}, {80, 30}],
          call: {700, 1800},
          need: 5,
          changes: 2,
          stalls: purse(stalls, ["Bread", "Fish", "Pots"])
        }
      ]
    end

    defp purse(stalls, names) do
      for {name, pos, r, kind} <- stalls, do: {name, pos, r, if(name in names, do: :purse, else: kind)}
    end

    def start_link(world, options), do: GenServer.start_link(__MODULE__, {world, options})
    def status(director), do: GenServer.call(director, :status)
    def input(director, message), do: GenServer.cast(director, {:input, message})

    # --- GenServer -------------------------------------------------------

    @impl true
    def init({world, options}) do
      space = :boids.space(world)

      state = %{
        world: world,
        space: space,
        options: options,
        level: 0,
        state: :sneaking,
        thief: nil,
        stalls: [],
        loot: 0,
        need: 0,
        sightings: [],
        count: 0,
        wanted: nil,
        changes: 0,
        chasing: 0,
        note: nil,
        start: LastSeen.now(),
        time: 0
      }

      # The director stops with the world.
      Process.monitor(space.owner)
      send(self(), :check)
      {:ok, level(state, Map.get(options, :level, 1))}
    end

    @impl true
    def handle_call(:status, _from, state) do
      now = LastSeen.now()
      time = if state.state == :sneaking, do: now - state.start, else: state.time
      coat = thief_coat(state)

      status = %{
        r: [
          ["Level", state.level],
          ["Loot", "#{state.loot} of #{state.need}"],
          ["Sightings", state.count],
          ["Chasing", state.chasing],
          ["Coat", if(coat, do: LastSeen.coat_name(coat), else: "-")]
        ],
        h: %{ground: "sand", rocks: [], zones: zones()},
        x: %{
          state: state.state,
          level: state.level,
          levels: length(levels()),
          loot: state.loot,
          need: state.need,
          count: state.count,
          time: Float.round(time / 1000, 1),
          changes: state.changes,
          # JSON has null for nothing.
          coat: if(coat, do: LastSeen.coat_name(coat), else: :null),
          note: note(state.note, now),
          wanted: if(state.wanted, do: LastSeen.coat_name(state.wanted), else: :null),
          stalls: for({name, {x, y}, r, kind} <- state.stalls, do: [name, x, y, r, Atom.to_string(kind)]),
          sightings:
            for s <- state.sightings, now - s.time < @show do
              [
                Float.round(elem(s.pos, 0) * 1.0, 1),
                Float.round(elem(s.pos, 1) * 1.0, 1),
                Float.round((now - s.time) / 1000, 1),
                Map.fetch!(%{red: "warm", green: "leaf", blue: "ink"}, s.coat),
                Atom.to_string(s.what),
                place(s.pos, state.stalls)
              ]
            end
        }
      }

      {:reply, status, state}
    end

    def handle_call(:state, _from, state), do: {:reply, state, state}

    @impl true
    def handle_cast(:caught, %{state: :sneaking} = state), do: {:noreply, finish(state, :caught)}

    def handle_cast(:at_gate, %{state: :sneaking, loot: loot, need: need} = state) when loot >= need do
      {:noreply, finish(state, :escaped)}
    end

    # A sighting at the end of a call: to the nearest officer, and the coat
    # to each citizen.
    def handle_cast({:sighting, sighting, from}, %{state: :sneaking} = state) do
      sighting = Map.put(sighting, :id, {:call, state.count + 1})
      rows = :boids.snapshot(state.space, :local)
      officers = for %{group: :officers} = row <- rows, do: row

      if officers != [] do
        %{pid: pid} = Enum.min_by(officers, &:boids_vec.dist(&1.pos, from))
        :gen_boid.cast(pid, {:sighting, sighting})
      end

      for %{group: :citizens, pid: pid} <- rows, do: :gen_boid.cast(pid, {:wanted, sighting.coat})
      {:noreply, %{state | sightings: [sighting | state.sightings], count: state.count + 1, wanted: sighting.coat}}
    end

    def handle_cast({:input, message}, state), do: {:noreply, handle_input(message, state)}
    def handle_cast(_message, state), do: {:noreply, state}

    @impl true
    def handle_info({:DOWN, _ref, :process, _pid, _reason}, state), do: {:stop, :normal, state}

    def handle_info(:check, state) do
      Process.send_after(self(), :check, BoidsExamples.Scene.tick())
      rows = :boids.snapshot(state.space, :local)
      chasing = Enum.count(rows, &match?(%{group: :officers, data: %{mode: :chase}}, &1))
      {:noreply, %{state | chasing: chasing}}
    end

    # --- The input of the person -------------------------------------------

    defp handle_input(%{"keys" => names}, %{state: :sneaking, thief: thief} = state) when is_list(names) do
      keys = for name <- names, Map.has_key?(@keys, name), into: %{}, do: {Map.fetch!(@keys, name), true}

      :gen_boid.cast(thief, {:keys, keys})
      state
    end

    defp handle_input(%{"steal" => true}, %{state: :sneaking} = state), do: steal(state)
    defp handle_input(%{"coat" => true}, %{state: :sneaking} = state), do: change_coat(state)

    # The next level after an escape, or the same level again.
    defp handle_input(%{"go" => true}, %{state: :escaped} = state) do
      next = if state.level >= length(levels()), do: 1, else: state.level + 1
      level(state, next)
    end

    defp handle_input(%{"go" => true}, %{state: :caught} = state), do: level(state, state.level)
    defp handle_input(_message, state), do: state

    # A theft: the nearest purse of a citizen (3 units at most) or of a
    # stall (3 units from its side at most). The thief must stop for it.
    # The thief shows the theft in its data: the boids that see it now see
    # a theft.
    defp steal(%{space: space, thief: thief} = state) do
      rows = :boids.snapshot(space, :local)

      case Enum.find(rows, &(&1.group == :thief)) do
        %{pos: pos, data: %{speed: speed}} ->
          citizens =
            for %{group: :citizens, data: %{purse: true}, pos: at, pid: pid} <- rows,
                (d = :boids_vec.dist(pos, at)) <= 3.0,
                do: {d, {:citizen, pid}}

          stalls =
            for {name, at, r, :purse} <- state.stalls,
                (d = :boids_vec.dist(pos, at) - r) <= 3.0,
                do: {d, {:stall, name}}

          case Enum.sort(citizens ++ stalls) do
            [] ->
              say(state, "No purse is near you.")

            [_ | _] when speed > @still ->
              say(state, "Stop next to the purse, then steal it.")

            [{_d, target} | _] ->
              :gen_boid.cast(thief, :stole)
              take(target, %{state | loot: state.loot + 1})
          end

        nil ->
          state
      end
    end

    defp take({:citizen, pid}, state) do
      :gen_boid.cast(pid, :steal)
      state
    end

    defp take({:stall, name}, state) do
      stalls = for {n, pos, r, kind} <- state.stalls, do: {n, pos, r, if(n == name, do: :goods, else: kind)}
      %{state | stalls: stalls}
    end

    # A new coat at the Coats stall: the sightings of the old coat no
    # longer match the thief.
    defp change_coat(%{changes: changes} = state) when changes > 0 do
      rows = :boids.snapshot(state.space, :local)

      with %{pos: pos, data: %{coat: coat}} <- Enum.find(rows, &(&1.group == :thief)),
           true <-
             Enum.any?(state.stalls, fn {_, at, r, kind} -> kind == :coats and :boids_vec.dist(pos, at) - r <= 4 end) do
        new = next_coat(coat, state.wanted)
        :gen_boid.cast(state.thief, {:coat, new})
        say(%{state | changes: changes - 1}, "A new coat: #{LastSeen.coat_name(new)}.")
      else
        _ -> say(state, "Go to the Coats stall for a new coat.")
      end
    end

    defp change_coat(state), do: say(state, "You have no more new coats in this level.")

    # A short note for the page, for some seconds.
    defp say(state, text), do: %{state | note: {text, LastSeen.now() + @note}}
    defp note({text, until}, now) when now < until, do: text
    defp note(_note, _now), do: :null

    # The next coat: not the coat now, and not the coat that the police want.
    defp next_coat(coat, wanted) do
      Enum.find(LastSeen.coats(), &(&1 != coat and &1 != wanted)) || Enum.find(LastSeen.coats(), &(&1 != coat))
    end

    defp finish(state, how) do
      :gen_boid.cast(state.thief, :stop)
      %{state | state: how, time: LastSeen.now() - state.start}
    end

    # Start a level: clear the world, then the stalls, the citizens, the
    # officers and the thief.
    defp level(%{world: world, space: space, options: options} = state, number) do
      for %{id: id} <- :boids.snapshot(space, :local), do: :boids.remove(space, id)
      for %{id: id} <- :boids.obstacles(space), do: :boids.remove_obstacle(space, id)

      setting =
        Map.merge(Enum.at(levels(), number - 1), Map.take(options, [:stalls, :officers, :call, :need, :changes]))

      for {name, pos, r, _kind} <- setting.stalls, do: :ok = :boids.set_obstacle(world, name, pos, r)
      stalls = for {name, pos, r, _kind} <- setting.stalls, do: %{name: name, pos: pos, r: r}
      speed = Map.get(options, :walk, 3.4)

      for citizen <- citizens(Map.get(options, :citizens, setting.citizens), setting.purses, setting.stalls) do
        options = Map.merge(%{stalls: stalls, director: self(), call: setting.call, speed: speed}, citizen)
        {:ok, _} = :gen_boid.start(space, Citizen, options)
      end

      for pos <- setting.officers do
        {:ok, _} = :gen_boid.start(space, Officer, %{pos: pos, speed: Map.get(options, :chase, 9.0)})
      end

      thief_at = Map.get(options, :thief, {8.0, 45.0})
      {:ok, thief} = :gen_boid.start(space, Thief, %{pos: thief_at, coat: :red, director: self()})

      %{
        state
        | level: number,
          state: :sneaking,
          thief: thief,
          stalls: setting.stalls,
          loot: 0,
          need: setting.need,
          sightings: [],
          count: 0,
          wanted: nil,
          changes: setting.changes,
          chasing: 0,
          note: nil,
          start: LastSeen.now(),
          time: 0
      }
    end

    # The citizens: a number at random places away from the stalls (the
    # first ones with a purse), or the list that a test gives.
    defp citizens(list, _purses, _stalls) when is_list(list), do: list

    defp citizens(count, purses, stalls) do
      for n <- 1..count//1, do: %{pos: free_place(stalls), purse: n <= purses}
    end

    defp free_place(stalls) do
      pos = {12 + :rand.uniform() * 136, 8 + :rand.uniform() * 74}

      if Enum.any?(stalls, fn {_, at, r, _} -> :boids_vec.dist(pos, at) < r + 2 end),
        do: free_place(stalls),
        else: pos
    end

    defp thief_coat(%{space: space}) do
      case Enum.find(:boids.snapshot(space, :local), &(&1.group == :thief)) do
        %{data: %{coat: coat}} -> coat
        nil -> nil
      end
    end

    # The name of the stall that is nearest to a place, for the page.
    defp place(pos, stalls) do
      case Enum.min_by(stalls, fn {_, at, _, _} -> :boids_vec.dist(pos, at) end, fn -> nil end) do
        {name, _, _, _} -> name
        nil -> ""
      end
    end

    defp zones do
      for {name, {x0, y0, x1, y1}} <- LastSeen.gates(), do: [x0, y0, x1, y1, "cool", name]
    end
  end

  # --- The scene ---------------------------------------------------------

  # The argument is nil for a visitor. A test gives options of the
  # director: the level, the citizens (a number, or a list of maps with
  # pos, purse and speed), the officers, the stalls, the time of a call,
  # the loot that the level needs, and the place of the thief.
  @impl true
  def start(options) do
    {:ok, world} =
      :boids.start_world(
        bounds: {{0, 0}, {@width, @height}},
        wrap: false,
        cell_size: 12,
        defaults: %{tick: BoidsExamples.Scene.tick()}
      )

    {:ok, director} = Director.start_link(world, options || %{})
    {:ok, %{space: :boids.space(world), director: director}}
  end

  @impl true
  def kinds(_scene) do
    [
      %{name: "citizens", shape: "person", color: "rock", size: 1.7},
      %{name: "citizens with a purse", shape: "person", color: "gold", size: 1.7},
      %{name: "witnesses", shape: "person", color: "plum", size: 1.7},
      %{name: "officers", shape: "person", color: "cool", size: 2.0},
      %{name: "thief in a red coat", shape: "person", color: "warm", size: 2.2},
      %{name: "thief in a green coat", shape: "person", color: "leaf", size: 2.2},
      %{name: "thief in a dark blue coat", shape: "person", color: "ink", size: 2.2}
    ]
  end

  @impl true
  def header(%{director: director}), do: Director.status(director).h

  @impl true
  def look(_scene, %{group: :citizens, data: %{role: :witness}, vel: vel}), do: {2, BoidsExamples.Scene.angle(vel), 0}
  def look(_scene, %{group: :citizens, data: %{purse: true}, vel: vel}), do: {1, BoidsExamples.Scene.angle(vel), 0}
  def look(_scene, %{group: :citizens, vel: vel}), do: {0, BoidsExamples.Scene.angle(vel), 0}
  def look(_scene, %{group: :officers, vel: vel}), do: {3, BoidsExamples.Scene.angle(vel), 0}

  def look(_scene, %{group: :thief, data: %{coat: coat}, vel: vel}) do
    {4 + Enum.find_index(@coats, &(&1 == coat)), BoidsExamples.Scene.angle(vel), 0}
  end

  @impl true
  def more(%{director: director}, _number), do: Director.status(director)

  @impl true
  def input(%{director: director}, message), do: Director.input(director, message)

  @doc false
  def colors, do: @colors
end
