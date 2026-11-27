defmodule BoidsSite.Scenes.Herd do
  @moduledoc """
  Quiet Herd: a stealth game. The person moves a fox across a field of
  grazing deer, to the far side. A deer that sees the fox too near
  becomes alert, then afraid. Fear goes from deer to deer: a wave. When
  many deer are afraid, the guards come and hunt the fox.

  The example shows these parts of the library:

  - A state in each boid that changes its rules: a deer is `calm`,
    `alert` or `afraid`, and each level has its own rules.
  - A behavior of the herd that no boid has: no code makes a wave. Each
    deer looks only at its neighbors, and the wave comes from these
    local decisions.
  - The data that the neighbors see: the fox shows its speed and if it
    is in the grass, and a deer shows its fear. A deer decides from the
    data of its neighbors.
  - A boid that a person controls: the force of the fox is a rule of its
    own, a function that reads the keys.

  The `Director` is the process of a try: the field, the time, the count
  of the afraid deer, and the alarm that calls the guards.
  """
  @behaviour BoidsSite.Scene

  @width 160
  @height 90
  @goal 152

  @doc "The steps of a boid in a time in milliseconds."
  def steps(milliseconds), do: max(div(milliseconds, BoidsSite.Scene.tick()), 1)

  @doc """
  The distance at which a deer notices the fox: larger when the fox
  moves fast, and small when the fox is in the grass.
  """
  def alarm(%{hidden: true}), do: 4.0
  def alarm(%{speed: speed}), do: 5.0 + 1.1 * speed

  @doc "True when the point is in one of the zones of grass."
  def in_grass?({x, y}, grass),
    do: Enum.any?(grass, fn {x0, y0, x1, y1} -> x >= x0 and x <= x1 and y >= y0 and y <= y1 end)

  defmodule Fox do
    @moduledoc """
    The fox. The person moves it with the keys: `left`, `right`, `up`,
    `down`, and `run` (fast, but the deer notice it from far away). Its
    data shows its speed and if it is in the grass. It tells the
    director when it reaches the far side, or when a guard catches it.
    """
    @behaviour :gen_boid
    alias BoidsSite.Scenes.Herd

    @walk 5.0
    @run 14.0

    @impl true
    def init(%{pos: pos, grass: grass, director: director}) do
      state = %{keys: %{}, grass: grass, director: director, stopped: false}

      {:ok,
       %{
         pos: pos,
         group: :fox,
         perception: 6,
         max_speed: @run,
         max_force: 70,
         rules: [{&Fox.legs/3, 1.0}],
         data: %{speed: 0.0, hidden: Herd.in_grass?(pos, grass), running: false},
         state: state
       }}
    end

    @doc """
    The force of the fox: to the velocity that the keys ask for. With no
    key, or after the end of the try, the fox stops.
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

    # Act: the fox stays in the field, shows its speed to the deer, and
    # tells the director when it reaches the far side.
    @impl true
    def handle_act(%{pos: {x, y}, vel: vel, state: state} = boid) do
      pos = {min(max(x, 1.0), 159.0), min(max(y, 1.0), 89.0)}
      speed = :boids_vec.norm(vel)
      data = %{speed: speed, hidden: Herd.in_grass?(pos, state.grass), running: speed > 9.0}

      state =
        if elem(pos, 0) >= 152 and not state.stopped do
          GenServer.cast(state.director, :done)
          %{state | stopped: true}
        else
          state
        end

      {:ok, %{boid | pos: pos, data: data, state: state}}
    end

    @impl true
    def handle_cast({:keys, keys}, %{state: state} = boid), do: {:noreply, %{boid | state: %{state | keys: keys}}}

    def handle_cast(:caught, %{state: %{stopped: true}} = boid), do: {:noreply, boid}

    def handle_cast(:caught, %{state: state} = boid) do
      GenServer.cast(state.director, :caught)
      {:noreply, %{boid | state: %{state | stopped: true}}}
    end
  end

  defmodule Deer do
    @moduledoc """
    A deer of the herd. Its state has its fear: `calm`, `alert` or
    `afraid`. Its data shows its fear to its neighbors, with the place
    that the fear comes from, and the number of deer between it and the
    fox (`hop`).

    - A calm deer grazes. It becomes alert when it sees the fox nearer
      than the distance of alarm (`BoidsSite.Scenes.Herd.alarm/1`), or an
      afraid neighbor.
    - An alert deer stands and looks. It becomes afraid when the fox
      comes nearer, runs, or stays near for 2 seconds.
    - A deer becomes afraid when it sees 2 afraid neighbors, or 1 afraid
      neighbor very near. Fear goes 3 deer far from the fox at most.
    - An afraid deer flees from the place of the fear, then calms down.
      For some seconds after that, only the fox can make it afraid again.
    """
    @behaviour :gen_boid
    alias BoidsSite.Scenes.Herd

    @hops 3
    @field {{28, 4}, {132, 86}}

    @impl true
    def init(pos) do
      {:ok,
       %{
         pos: pos,
         vel: :boids_vec.scale(:boids_vec.random_unit(2), 0.5),
         group: :deer,
         perception: 22,
         data: %{fear: :calm, from: nil, hop: 0},
         state: %{fear: :calm, timer: 0, watch: 0, rest: 0}
       }
       |> Map.merge(look(:calm, nil))}
    end

    @doc "The rules and the speed of a deer for a level of fear."
    def look(:calm, _from) do
      %{
        max_speed: 1.6,
        rules: [
          {:contain, 3.0, %{bounds: @field, margin: 6}},
          {:separation, 1.4, %{radius: 3}},
          {:cohesion, 0.5},
          {:alignment, 0.3},
          {:wander, 0.8}
        ]
      }
    end

    def look(:alert, _from) do
      %{max_speed: 0.6, rules: [{:contain, 3.0, %{bounds: @field, margin: 6}}, {:separation, 1.4, %{radius: 3}}]}
    end

    def look(:afraid, from) do
      %{
        max_speed: 15,
        rules: [
          {:contain, 3.0, %{bounds: {{2, 2}, {158, 88}}, margin: 4}},
          {:flee, 3.0, %{target: from}},
          {:separation, 1.6, %{radius: 3}},
          {:alignment, 1.0}
        ]
      }
    end

    @impl true
    def handle_decide(%{neighbors: neighbors}, %{state: state, data: data} = boid) do
      fox = Enum.find(neighbors, &(&1.group == :fox))
      alarm = if fox, do: Herd.alarm(fox.data), else: 0.0
      sees_fox = fox != nil and fox.dist <= alarm
      afraid = for n <- neighbors, n.group == :deer, match?(%{fear: :afraid}, n.data), do: n
      near = for n <- afraid, n.data.hop < @hops, n.dist <= 10, do: n
      close = Enum.filter(near, &(&1.dist <= 4))

      state = %{state | timer: max(state.timer - 1, 0), rest: max(state.rest - 1, 0)}
      watch = if sees_fox, do: state.watch + 1, else: 0

      cond do
        # The fox is near: it runs, it comes nearer, or it stayed near.
        sees_fox and (fox.data.running or fox.dist <= 0.6 * alarm or watch >= Herd.steps(2000) or state.fear == :afraid) ->
          {:ok, fear(boid, :afraid, fox.pos, 0, %{state | watch: watch, timer: Herd.steps(3500)})}

        sees_fox ->
          {:ok,
           fear(boid, max_fear(state.fear, :alert), data.from, data.hop, %{
             state
             | watch: watch,
               timer: Herd.steps(2000)
           })}

        # Fear from the neighbors.
        state.rest == 0 and state.fear != :afraid and (length(near) >= 2 or close != []) ->
          source = Enum.min_by(near, & &1.data.hop)

          {:ok,
           fear(boid, :afraid, source.data.from, source.data.hop + 1, %{state | watch: 0, timer: Herd.steps(3000)})}

        afraid != [] and state.fear == :calm and state.rest == 0 ->
          {:ok, fear(boid, :alert, data.from, data.hop, %{state | watch: 0, timer: Herd.steps(1500)})}

        # The end of the fear.
        state.fear != :calm and state.timer == 0 ->
          rest = if state.fear == :afraid, do: Herd.steps(4000), else: 0
          {:ok, fear(boid, :calm, nil, 0, %{state | watch: 0, rest: rest})}

        true ->
          {:ok, %{boid | state: %{state | watch: watch}}}
      end
    end

    # A scene or a test can make a deer afraid of a point.
    @impl true
    def handle_cast({:scare, from}, %{state: state} = boid) do
      {:noreply, fear(boid, :afraid, from, 0, %{state | timer: Herd.steps(3500)})}
    end

    defp max_fear(:afraid, _level), do: :afraid
    defp max_fear(_fear, level), do: level

    # A change of the fear changes the rules, and the data that the
    # neighbors see.
    defp fear(%{state: %{fear: fear}, data: %{from: from}} = boid, fear, from, hop, state) do
      %{boid | state: state, data: %{boid.data | hop: hop}}
    end

    defp fear(boid, level, from, hop, state) do
      boid = :boids_boid.update(boid, look(level, from))
      %{boid | state: %{state | fear: level}, data: %{fear: level, from: from, hop: hop}}
    end
  end

  defmodule Guard do
    @moduledoc """
    A guard rests at its post, and sees only near it. Some guards rest at
    the far side. When the director rings the alarm, a guard goes to the
    place of the fear. It hunts the fox that it sees, faster than the fox
    runs, and catches the fox that it touches. After 8 seconds with no
    alarm and no fox, it goes back to its post.
    """
    @behaviour :gen_boid
    alias BoidsSite.Scenes.Herd

    @impl true
    def init(post) do
      {:ok,
       %{
         pos: post,
         group: :guards,
         perception: 24,
         max_force: 90,
         rules: [{:arrive, 1.0, %{target: post}}],
         max_speed: 6,
         state: %{post: post, mode: :rests, timer: 0}
       }}
    end

    @impl true
    def handle_decide(%{neighbors: neighbors, lookup: lookup}, %{state: state} = boid) do
      fox = Enum.find(neighbors, &(&1.group == :fox))
      # A guard that rests sees the fox only near it. The grass hides the fox.
      sight = if(state.mode == :rests, do: 6, else: 24)
      sight = if fox && fox.data.hidden, do: min(sight, 5), else: sight
      sees = fox != nil and fox.dist <= sight
      timer = max(state.timer - 1, 0)

      cond do
        sees and fox.dist <= 3.0 ->
          with {:ok, %{pid: pid}} <- lookup.(fox.id), do: :gen_boid.cast(pid, :caught)
          {:ok, mode(boid, :hunts, %{state | timer: Herd.steps(8000)})}

        sees ->
          {:ok, mode(boid, :hunts, %{state | timer: Herd.steps(8000)})}

        state.mode != :rests and timer == 0 ->
          {:ok, mode(boid, :rests, %{state | timer: 0})}

        true ->
          {:ok, %{boid | state: %{state | timer: timer}}}
      end
    end

    @impl true
    def handle_cast({:alarm, point}, %{state: %{mode: :hunts}} = boid) when is_tuple(point), do: {:noreply, boid}

    def handle_cast({:alarm, point}, %{state: state} = boid) do
      {:noreply, mode(boid, {:searches, point}, %{state | timer: Herd.steps(8000)})}
    end

    defp mode(%{state: %{mode: mode}} = boid, mode, state), do: %{boid | state: state}

    defp mode(boid, mode, state) do
      rules =
        case mode do
          :rests -> %{rules: [{:arrive, 1.0, %{target: state.post}}], max_speed: 6}
          :hunts -> %{rules: [{:pursue, 1.0, %{target: {:group, :fox}}}], max_speed: 20}
          {:searches, point} -> %{rules: [{:seek, 1.0, %{target: point}}], max_speed: 12}
        end

      %{:boids_boid.update(boid, rules) | state: %{state | mode: mode}}
    end
  end

  defmodule Director do
    @moduledoc """
    The process of a try: the field, the state (`sneaking`, `caught` or
    `done`), the time, and the count of the afraid deer. At each tick it
    counts the afraid deer. When they are as many as the limit of the
    field, it rings the alarm: each guard goes to the place of the fear.
    """
    use GenServer
    alias BoidsSite.Scenes.Herd

    @doc """
    The fields of the game. Each next field has more deer, less grass and
    more guards. A grass zone is `{X0, Y0, X1, Y1}`.
    """
    def fields do
      [
        %{
          deer: 22,
          limit: 6,
          guards: [{146, 45}, {80, 86}],
          grass: [{18, 30, 44, 62}, {52, 6, 80, 28}, {84, 58, 112, 84}, {112, 22, 138, 48}]
        },
        %{
          deer: 32,
          limit: 5,
          guards: [{146, 30}, {146, 60}, {80, 4}],
          grass: [{22, 34, 42, 58}, {70, 60, 92, 80}, {110, 16, 130, 36}]
        },
        %{
          deer: 38,
          limit: 5,
          guards: [{146, 33}, {146, 57}, {70, 4}, {100, 86}],
          grass: [{28, 46, 50, 68}, {94, 20, 116, 42}]
        }
      ]
    end

    def start_link(space, options), do: GenServer.start_link(__MODULE__, {space, options})
    def status(director), do: GenServer.call(director, :status)
    def input(director, message), do: GenServer.cast(director, {:input, message})

    # --- GenServer -------------------------------------------------------

    @impl true
    def init({space, options}) do
      state = %{
        space: space,
        options: options,
        field: 0,
        state: :sneaking,
        fox: nil,
        guards: [],
        grass: [],
        limit: 0,
        afraid: 0,
        most: 0,
        alarm: false,
        alarms: 0,
        rang: 0,
        start: now(),
        time: 0,
        running: false,
        hidden: false
      }

      # The director stops with the world.
      Process.monitor(space.owner)
      send(self(), :check)
      {:ok, field(state, Map.get(options, :field, 1))}
    end

    @impl true
    def handle_call(:status, _from, state) do
      time = if state.state == :sneaking, do: now() - state.start, else: state.time
      seconds = Float.round(time / 1000, 1)

      status = %{
        r: [["Field", state.field], ["Time", seconds], ["Afraid", state.afraid], ["Most afraid", state.most]],
        h: %{zones: zones(state)},
        x: %{
          state: state.state,
          field: state.field,
          fields: length(fields()),
          time: seconds,
          most: state.most,
          limit: state.limit,
          alarm: state.alarm,
          alarms: state.alarms,
          thrust: state.running,
          safe: state.hidden
        }
      }

      {:reply, status, state}
    end

    @impl true
    def handle_cast(:done, %{state: :sneaking} = state), do: {:noreply, stop(state, :done)}
    def handle_cast(:caught, %{state: :sneaking} = state), do: {:noreply, stop(state, :caught)}

    def handle_cast({:input, %{"keys" => names}}, %{state: :sneaking, fox: fox} = state) when is_list(names) do
      keys =
        for name <- names, name in ["left", "right", "up", "down", "run"], into: %{} do
          {String.to_existing_atom(name), true}
        end

      :gen_boid.cast(fox, {:keys, keys})
      {:noreply, state}
    end

    # The next field after the far side, or the same field again.
    def handle_cast({:input, %{"go" => true}}, %{state: :done} = state) do
      next = if state.field >= length(fields()), do: 1, else: state.field + 1
      {:noreply, field(state, next)}
    end

    def handle_cast({:input, %{"go" => true}}, %{state: :caught} = state), do: {:noreply, field(state, state.field)}
    def handle_cast(_message, state), do: {:noreply, state}

    @impl true
    def handle_info({:DOWN, _ref, :process, _pid, _reason}, state), do: {:stop, :normal, state}

    def handle_info(:check, state) do
      Process.send_after(self(), :check, BoidsSite.Scene.tick())
      {:noreply, check(state)}
    end

    # Count the afraid deer. At the limit, ring the alarm: each guard goes
    # to the place of the fear. While the fear stays at the limit, the
    # alarm rings again each second.
    defp check(%{state: :sneaking, space: space} = state) do
      rows = :boids.snapshot(space, :local)
      afraid = for %{group: :deer, data: %{fear: :afraid, from: from}} <- rows, from != nil, do: from
      fox = Enum.find(rows, &(&1.group == :fox))
      count = length(afraid)

      ring = count >= state.limit and (not state.alarm or now() - state.rang >= 1000)

      if ring do
        point = :boids_vec.scale(Enum.reduce(afraid, {0.0, 0.0}, &:boids_vec.add/2), 1 / count)
        for guard <- state.guards, do: :gen_boid.cast(guard, {:alarm, point})
      end

      %{
        state
        | afraid: count,
          most: max(state.most, count),
          alarm: count >= state.limit,
          alarms: state.alarms + if(ring and not state.alarm, do: 1, else: 0),
          rang: if(ring, do: now(), else: state.rang),
          running: fox != nil and fox.data.running,
          hidden: fox != nil and fox.data.hidden
      }
    end

    defp check(state), do: state

    defp stop(state, how), do: %{state | state: how, time: now() - state.start, afraid: 0, alarm: false}

    # Start a field: clear the world, then the deer, the guards and the fox.
    defp field(%{space: space, options: options} = state, number) do
      for %{id: id} <- :boids.snapshot(space, :local), do: :boids.remove(space, id)
      setting = Map.merge(Enum.at(fields(), number - 1), Map.take(options, [:deer, :limit, :guards, :grass]))

      for pos <- positions(setting.deer) do
        {:ok, _} = :gen_boid.start(space, Deer, pos)
      end

      guards =
        for post <- setting.guards do
          {:ok, pid} = :gen_boid.start(space, Guard, post)
          pid
        end

      fox_at = Map.get(options, :fox, {6.0, 45.0})
      {:ok, fox} = :gen_boid.start(space, Fox, %{pos: fox_at, grass: setting.grass, director: self()})

      %{
        state
        | field: number,
          state: :sneaking,
          fox: fox,
          guards: guards,
          grass: setting.grass,
          limit: setting.limit,
          afraid: 0,
          most: 0,
          alarm: false,
          alarms: 0,
          start: now(),
          time: 0,
          running: false,
          hidden: false
      }
    end

    # A number of deer at random places of the middle of the field, or the
    # places that a test gives.
    defp positions(places) when is_list(places), do: places

    defp positions(count) do
      for _ <- 1..count//1, do: {32 + :rand.uniform() * 96, 8 + :rand.uniform() * 74}
    end

    defp zones(state) do
      grass = for {x0, y0, x1, y1} <- state.grass, do: [x0, y0, x1, y1, "cool"]
      [[Herd.goal(), 0, 160, 90, "warm"] | grass]
    end

    defp now, do: System.monotonic_time(:millisecond)
  end

  @doc "The x of the far side: the fox that reaches it is done."
  def goal, do: @goal

  # --- The scene ---------------------------------------------------------

  # The argument is nil for a visitor. A test gives options of the
  # director: the field, the deer (a number, or a list of places), the
  # limit of the alarm, the guards, the grass, and the place of the fox.
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
      %{name: "calm deer", shape: "dart", color: "rock", size: 1.3},
      %{name: "alert deer", shape: "dart", color: "ink", size: 1.4},
      %{name: "afraid deer", shape: "dart", color: "warm", size: 1.4},
      %{name: "fox", shape: "ship", color: "cool", size: 2.0},
      %{name: "guards", shape: "hex", color: "ink", size: 2.0}
    ]
  end

  @impl true
  def header(%{director: director}), do: Director.status(director).h

  @impl true
  def look(_scene, %{group: :deer, data: %{fear: fear}, vel: vel}) do
    {Enum.find_index([:calm, :alert, :afraid], &(&1 == fear)), BoidsSite.Scene.angle(vel), 0}
  end

  def look(_scene, %{group: :fox, vel: vel}), do: {3, BoidsSite.Scene.angle(vel), 0}
  def look(_scene, %{vel: vel}), do: {4, BoidsSite.Scene.angle(vel), 0}

  @impl true
  def more(%{director: director}, _number), do: Director.status(director)

  @impl true
  def input(%{director: director}, message), do: Director.input(director, message)
end
