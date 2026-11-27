defmodule BoidsSite.Scenes.Game do
  @moduledoc """
  Rock Patrol: a small game. A ship flies in a field of rocks. A queen
  and its drones hunt the ship, and the drones shoot at it.

  Each thing in the game is a boid: one process with the behavior
  `gen_boid`.

  - `Ship`: a boid that a person controls. Its force is a rule of its own
    (a function).
  - `Rock`: a boid that gets a message when a shot hits it. It starts two
    smaller rocks, and stops.
  - `Shot`: a boid that lives for a short time. It senses what it hits,
    and sends a message to that boid. A shot of the ship hits the rocks,
    the drones and the queen. A bolt of a drone hits the ship.
  - `Drone`: it follows its queen by a relation (`boids:relate/4`). When
    it sees the ship, it hunts the ship and shoots bolts at it.
  - `Queen`: it starts new drones.
  """
  @behaviour BoidsSite.Scene

  @width 160
  @height 90
  @kinds [:ship, :rocks, :drones, :queen, :shots, :bolts]

  @doc "The steps of a boid in a time in milliseconds."
  def steps(milliseconds), do: max(div(milliseconds, BoidsSite.Scene.tick()), 1)

  def turn({x, y}, angle) do
    {x * :math.cos(angle) - y * :math.sin(angle), x * :math.sin(angle) + y * :math.cos(angle)}
  end

  def direction(angle), do: {:math.cos(angle), :math.sin(angle)}

  @doc "The distance at which a shot or the ship touches a boid."
  def radius(%{group: :rocks, data: size}), do: size * 2.2
  def radius(%{group: :queen}), do: 3.0
  def radius(_other), do: 1.5

  defmodule Rock do
    @moduledoc "A rock moves in a line. A hit makes two smaller rocks of it."
    @behaviour :gen_boid

    @impl true
    def init(%{pos: pos, vel: vel, size: size, space: space}) do
      speed = :boids_vec.norm(vel)

      {:ok,
       %{
         pos: pos,
         vel: vel,
         group: :rocks,
         data: size,
         perception: 12,
         min_speed: speed * 0.6,
         max_speed: speed * 1.4,
         rules: [{:cruise, 1.0, %{speed: speed}}, {:separation, 2.0, %{radius: size * 3.0, groups: [:rocks]}}],
         state: space
       }}
    end

    @impl true
    def handle_cast(:hit, %{data: size, pos: pos, vel: vel, state: space} = boid) do
      if size > 1 do
        for angle <- [-0.7, 0.7] do
          part = %{
            pos: pos,
            vel: :boids_vec.scale(BoidsSite.Scenes.Game.turn(vel, angle), 1.4),
            size: size - 1,
            space: space
          }

          {:ok, _} = :gen_boid.start(space, Rock, part)
        end
      end

      {:stop, :normal, boid}
    end
  end

  defmodule Shot do
    @moduledoc """
    A shot moves in a line for a short time. It tells the boid that it
    hits, and stops. Its arguments tell the groups that it hits (`hits`),
    the process that gets the score or `nil` (`scorer`), and its life in
    milliseconds (`life`).
    """
    @behaviour :gen_boid
    alias BoidsSite.Scenes.Game

    @impl true
    def init(%{pos: pos, vel: vel, group: group, hits: hits, scorer: scorer, life: life}) do
      speed = :boids_vec.norm(vel)
      state = %{hits: hits, scorer: scorer, steps: Game.steps(life)}

      {:ok,
       %{pos: pos, vel: vel, group: group, perception: 9, rules: [], min_speed: speed, max_speed: speed, state: state}}
    end

    # Decide: a target at the distance of its radius is hit.
    @impl true
    def handle_decide(%{neighbors: neighbors}, %{state: %{hits: hits, scorer: scorer}} = boid) do
      case Enum.find(neighbors, &(&1.group in hits and &1.dist <= Game.radius(&1) + 1.0)) do
        nil ->
          {:ok, boid}

        target ->
          # The id of a boid is its process.
          :gen_boid.cast(target.id, :hit)
          if scorer, do: :gen_boid.cast(scorer, {:scored, target.group})
          {:stop, :normal, boid}
      end
    end

    @impl true
    def handle_act(%{state: %{steps: 0}} = boid), do: {:stop, :normal, boid}
    def handle_act(%{state: state} = boid), do: {:ok, %{boid | state: %{state | steps: state.steps - 1}}}
  end

  defmodule Drone do
    @moduledoc """
    A drone stays near its queen. When it sees the ship, it hunts the
    ship, and it shoots a bolt at the ship each 1.8 seconds.
    """
    @behaviour :gen_boid
    alias BoidsSite.Scenes.Game

    @swarm [
      {{:separation, :rocks}, 3.0, %{radius: 7, groups: [:rocks]}},
      {:separation, 1.5, %{radius: 3}},
      {:alignment, 0.8},
      {:cohesion, 0.8}
    ]
    @escort [{:leader, 1.5, %{target: {:related, :guards}, distance: 6}} | @swarm]
    @hunt [{:pursue, 2.5, %{target: {:group, :ship}}} | @swarm]

    # A drone shoots at a ship at this distance or less, and at this
    # angle or less from the direction of the drone (0.35 rad).
    @range 25
    @front :math.cos(0.35)

    # The state: the mode (escorts or hunts), the steps before the next
    # bolt, the space (to start a bolt), and where the ship is (to aim).
    @impl true
    def init(%{pos: pos, space: space}) do
      state = %{mode: :escorts, wait: Game.steps(1800), space: space, aim: nil}
      {:ok, %{pos: pos, group: :drones, perception: 26, max_speed: 13, min_speed: 4, rules: @escort, state: state}}
    end

    # Decide: hunt the ship while the drone sees it.
    @impl true
    def handle_decide(%{neighbors: neighbors}, %{state: %{mode: mode} = state} = boid) do
      ship = Enum.find(neighbors, &(&1.group == :ship))
      state = %{state | aim: ship && {ship.offset, ship.dist}}

      case {ship != nil, mode} do
        {true, :escorts} -> {:ok, %{:boids_boid.update(boid, %{rules: @hunt}) | state: %{state | mode: :hunts}}}
        {false, :hunts} -> {:ok, %{:boids_boid.update(boid, %{rules: @escort}) | state: %{state | mode: :escorts}}}
        _ -> {:ok, %{boid | state: state}}
      end
    end

    # Act: shoot a bolt at a ship that is near and in front of the drone.
    @impl true
    def handle_act(%{pos: pos, vel: vel, state: %{aim: {offset, dist}, wait: 0, space: space} = state} = boid)
        when dist > 0 and dist <= @range do
      if :boids_vec.dot(vel, offset) >= @front * :boids_vec.norm(vel) * dist do
        direction = :boids_vec.scale(offset, 1 / dist)

        bolt = %{
          pos: :boids_vec.add(pos, :boids_vec.scale(direction, 2.0)),
          vel: :boids_vec.scale(direction, 30.0),
          group: :bolts,
          hits: [:ship],
          scorer: nil,
          life: 1000
        }

        {:ok, _} = :gen_boid.start(space, Shot, bolt)
        {:ok, %{boid | state: %{state | wait: Game.steps(1800)}}}
      else
        {:ok, boid}
      end
    end

    def handle_act(%{state: state} = boid), do: {:ok, %{boid | state: %{state | wait: max(state.wait - 1, 0)}}}

    @impl true
    def handle_cast(:hit, boid), do: {:stop, :normal, boid}
  end

  defmodule Queen do
    @moduledoc "A queen moves slowly, and starts a new drone each 2.5 seconds. Five hits stop it."
    @behaviour :gen_boid
    alias BoidsSite.Scenes.Game

    @impl true
    def init(%{pos: pos, space: space}) do
      rules = [
        {{:separation, :rocks}, 3.0, %{radius: 10, groups: [:rocks]}},
        {:wander, 1.0},
        {:cruise, 1.0, %{speed: 5.0}}
      ]

      {:ok,
       %{pos: pos, group: :queen, data: 5, perception: 16, max_speed: 6, rules: rules, state: %{space: space, steps: 1}}}
    end

    @impl true
    def handle_act(%{id: id, pos: pos, state: %{space: space, steps: steps} = state} = boid) do
      if rem(steps, Game.steps(2500)) == 0 and length(:boids.related_to(space, id, :guards)) < 10 do
        Queen.drone(space, id, pos)
      end

      {:ok, %{boid | state: %{state | steps: steps + 1}}}
    end

    @impl true
    def handle_cast(:hit, %{data: 1} = boid), do: {:stop, :normal, boid}
    def handle_cast(:hit, %{data: left} = boid), do: {:noreply, %{boid | data: left - 1}}

    @doc "Start a drone that guards a queen."
    def drone(space, queen, {x, y}) do
      pos = {x + :rand.uniform() * 4 - 2, y + :rand.uniform() * 4 - 2}
      {:ok, drone} = :gen_boid.start(space, Drone, %{pos: pos, space: space})
      :boids.relate(space, drone, :guards, queen)
    end
  end

  defmodule Ship do
    @moduledoc """
    The ship. A person controls it, or an autopilot. Its state has the
    keys of the person, the direction of the ship, its shield and the
    score. Its data shows them to the page.
    """
    @behaviour :gen_boid
    alias BoidsSite.Scenes.Game

    # The autopilot: stay away from the rocks, and move to the drones.
    @auto [
      {{:separation, :rocks}, 5.0, %{radius: 16, groups: [:rocks]}},
      {:dodge, 3.0, %{radius: 6, horizon: 1.5}},
      {:pursue, 0.8, %{target: {:group, :drones}}},
      {:wander, 0.6},
      {:cruise, 0.6, %{speed: 12.0}}
    ]

    @impl true
    def init(space) do
      state = %{
        space: space,
        keys: %{},
        idle: Game.steps(60_000),
        heading: 0.0,
        fire: false,
        wait: 0,
        safe: Game.steps(3000),
        shield: 3,
        score: 0,
        wrecks: 0
      }

      {:ok,
       %{
         pos: {80, 45},
         group: :ship,
         perception: 34,
         max_speed: 28,
         max_force: 40,
         rules: @auto,
         state: state,
         data: show(state)
       }}
    end

    # The force of the ship with the keys of a person: thrust in its
    # direction, and a small force against its movement.
    def engine(%{vel: vel, state: %{keys: keys, heading: heading}}, _neighbors, _seen) do
      thrust = if keys[:thrust], do: 32.0, else: 0.0
      :boids_vec.add(:boids_vec.scale(Game.direction(heading), thrust), :boids_vec.scale(vel, -0.5))
    end

    # Decide: damage from a rock or a drone that touches the ship, then
    # the direction and the trigger, from the keys or from the autopilot.
    @impl true
    def handle_decide(%{neighbors: neighbors, dt: dt}, %{state: state} = boid) do
      threats = Enum.filter(neighbors, &(&1.group in [:rocks, :drones, :queen]))
      state = damage(state, Enum.any?(threats, &(&1.dist <= Game.radius(&1) + 1.2)))
      manual = manual?(state)

      {heading, fire} =
        if manual do
          turn = if(state.keys[:left], do: 3.5, else: 0.0) - if state.keys[:right], do: 3.5, else: 0.0
          {state.heading + turn * dt, state.keys[:fire] == true}
        else
          aim(state.heading, threats, dt)
        end

      state = %{state | heading: heading, fire: fire, idle: state.idle + 1}
      rules = if manual, do: [{&Ship.engine/3, 1.0}], else: @auto
      {:ok, %{:boids_boid.update(boid, %{rules: rules}) | state: state}}
    end

    # Act: shoot, and show the state to the page.
    @impl true
    def handle_act(%{pos: pos, vel: vel, state: state} = boid) do
      state =
        if state.fire and state.wait == 0 do
          forward = Game.direction(state.heading)
          from = :boids_vec.add(pos, :boids_vec.scale(forward, 2.5))

          shot = %{
            pos: from,
            vel: :boids_vec.add(:boids_vec.scale(forward, 45.0), vel),
            group: :shots,
            hits: [:rocks, :drones, :queen],
            scorer: self(),
            life: 1200
          }

          {:ok, _} = :gen_boid.start(state.space, Shot, shot)
          %{state | wait: Game.steps(250)}
        else
          %{state | wait: max(state.wait - 1, 0)}
        end

      {:ok, %{boid | state: state, data: show(state)}}
    end

    @impl true
    def handle_cast({:keys, keys}, %{state: state} = boid),
      do: {:noreply, %{boid | state: %{state | keys: keys, idle: 0}}}

    def handle_cast({:scored, group}, %{state: state} = boid) do
      points = %{rocks: 10, drones: 25, queen: 50}[group]
      {:noreply, %{boid | state: %{state | score: state.score + points}}}
    end

    # A bolt of a drone hit the ship.
    def handle_cast(:hit, %{state: state} = boid), do: {:noreply, %{boid | state: hit(state)}}

    # With no key for 5 seconds, the autopilot flies the ship.
    defp manual?(state), do: state.idle < Game.steps(5000)

    # Each step, the safe time of the ship becomes shorter. A rock or a
    # drone that touches the ship is a hit.
    defp damage(%{safe: safe} = state, _touched) when safe > 0, do: %{state | safe: safe - 1}
    defp damage(state, false), do: state
    defp damage(state, true), do: hit(state)

    # A hit removes one part of the shield. The ship is then safe for 3
    # seconds, and a hit in that time does nothing. With no shield, the
    # ship is a wreck: the score starts again.
    defp hit(%{safe: safe} = state) when safe > 0, do: state

    defp hit(%{shield: 1} = state) do
      %{state | shield: 3, score: 0, wrecks: state.wrecks + 1, safe: Game.steps(3000)}
    end

    defp hit(state), do: %{state | shield: state.shield - 1, safe: Game.steps(3000)}

    # The autopilot turns to the nearest target, and shoots when the
    # target is in front of the ship.
    defp aim(heading, [], _dt), do: {heading, false}

    defp aim(heading, [%{offset: {x, y}, dist: dist} | _], dt) do
      error = :math.atan2(y, x) - heading
      error = :math.atan2(:math.sin(error), :math.cos(error))
      {heading + max(min(error, 5.0 * dt), -5.0 * dt), abs(error) < 0.15 and dist < 30}
    end

    defp show(state) do
      %{
        heading: state.heading,
        shield: state.shield,
        score: state.score,
        wrecks: state.wrecks,
        auto: not manual?(state),
        thrust: state.keys[:thrust] == true and manual?(state),
        safe: state.safe > 0
      }
    end
  end

  # --- The scene ---------------------------------------------------------

  @impl true
  def start(_definition) do
    {:ok, world} =
      :boids.start_world(
        bounds: {{0, 0}, {@width, @height}},
        wrap: true,
        cell_size: 12,
        defaults: %{tick: BoidsSite.Scene.tick()}
      )

    space = :boids.space(world)
    {:ok, ship} = :gen_boid.start(space, Ship, space)
    scene = %{space: space, ship: ship}
    for _ <- 1..5, do: rock(scene)
    queen(scene)
    {:ok, scene}
  end

  @impl true
  def kinds(_scene) do
    [
      %{name: "ship", shape: "ship", color: "warm", size: 2.4},
      %{name: "rocks", shape: "rock", color: "rock", size: 2.2},
      %{name: "drones", shape: "dart", color: "cool", size: 1.4},
      %{name: "queen", shape: "hex", color: "cool", size: 3.0},
      %{name: "shots", shape: "dot", color: "warm", size: 0.55},
      %{name: "bolts", shape: "dot", color: "cool", size: 0.5}
    ]
  end

  @impl true
  def look(_scene, %{group: :ship, data: %{heading: heading, shield: shield}}), do: {0, heading, shield}
  def look(_scene, %{group: :rocks, vel: vel, data: size}), do: {1, BoidsSite.Scene.angle(vel), size}
  def look(_scene, %{group: :queen, vel: vel, data: left}), do: {3, BoidsSite.Scene.angle(vel), left}

  def look(_scene, %{group: group, vel: vel}),
    do: {Enum.find_index(@kinds, &(&1 == group)), BoidsSite.Scene.angle(vel), 0}

  @impl true
  def more(%{space: space, ship: ship}, number) do
    case :boids.lookup(space, ship) do
      {:ok, %{data: data}} ->
        readings = [
          ["Score", data.score],
          ["Shield", data.shield],
          ["Wrecks", data.wrecks],
          ["Pilot", if(data.auto, do: "autopilot", else: "you")]
        ]

        # Each second: the swarms of drones, from the world as a graph.
        readings = if rem(number, steps(1000)) == 0, do: readings ++ [["Swarms", swarms(space)]], else: readings
        %{r: readings, x: %{thrust: data.thrust, safe: data.safe}}

      _ ->
        %{}
    end
  end

  defp swarms(space) do
    drones = for %{id: id, group: :drones} <- :boids.snapshot(space), do: id
    length(:graph.components(:graph.subgraph(:boids.graph(space, 8), drones)))
  end

  # The keys that the person holds down, as a list of names.
  @impl true
  def input(%{ship: ship}, %{"keys" => names}) when is_list(names) do
    keys =
      for name <- names,
          name in ["left", "right", "thrust", "fire"],
          into: %{},
          do: {String.to_existing_atom(name), true}

    :gen_boid.cast(ship, {:keys, keys})
  end

  def input(_scene, _message), do: :ok

  # Keep the game alive: new rocks for the rocks that are gone, and a new queen.
  @impl true
  def direct(%{space: space} = scene) do
    groups = Enum.frequencies_by(:boids.snapshot(space), & &1.group)
    if Map.get(groups, :rocks, 0) < 6, do: rock(scene)
    if Map.get(groups, :queen, 0) == 0, do: queen(scene)
    :ok
  end

  # A large rock at a side of the box, not near the ship.
  defp rock(%{space: space, ship: ship}) do
    {:ok, %{pos: at}} = :boids.lookup(space, ship)
    pos = Enum.random([{:rand.uniform() * @width, 0.0}, {0.0, :rand.uniform() * @height}])

    if :boids_vec.norm(:boids_space.offset(space, at, pos)) > 30 do
      vel = :boids_vec.scale(:boids_vec.random_unit(2), 3.0 + :rand.uniform() * 3.0)
      {:ok, _} = :gen_boid.start(space, Rock, %{pos: pos, vel: vel, size: 3, space: space})
    end
  end

  defp queen(%{space: space}) do
    pos = {:rand.uniform() * @width, :rand.uniform() * 20.0}
    {:ok, queen} = :gen_boid.start(space, Queen, %{pos: pos, space: space})
    for _ <- 1..5, do: Queen.drone(space, queen, pos)
  end
end
