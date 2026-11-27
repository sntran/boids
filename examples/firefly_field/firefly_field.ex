defmodule BoidsExamples.Games.FireflyField do
  @moduledoc """
  Firefly Field: a calm puzzle at night. Fireflies fly in small groups.
  Each firefly has a clock: it flashes at the end of its clock, then the
  clock starts again. A firefly that sees a neighbor flash moves its own
  clock a little forward. So the fireflies that see each other come to
  flash together, and a group that is far away flashes at its own time.

  The person moves a lantern. The fireflies near the lantern fly to it,
  so the person can bring the groups together. A level is done when all
  the fireflies flash together, three times in a row, before the dawn.

  The example shows these parts of the library:

  - Data that the neighbors see as a signal: the data of a firefly has
    the time of its last flash. A firefly reads the data of its
    neighbors, and no message goes from firefly to firefly.
  - A sync that no firefly makes: each firefly moves only its own clock,
    and the flashes of the field come together.
  - `boids:flocks/2`: the groups of fireflies that see each other.
  - Rules that are functions (the lantern), and the rule `flow` with a
    field that is a function (the wind).

  The `Director` is the process of a night: the level, the lantern, the
  wind, the count of the flashes, and the dawn.
  """
  @behaviour BoidsExamples.Scene
  use BoidsExamples.Game

  @impl BoidsExamples.Game
  def info do
    %{
      slug: "firefly-field",
      title: "Firefly Field",
      tag: "Keys",
      pitch:
        "Lead groups of fireflies with a lantern at night. The fireflies that see each other flash together. Make all of them flash at one moment before the dawn.",
      shows:
        "data that the neighbors see as a signal (the time of a flash), a sync that no firefly makes: it comes from small changes of each clock. Also the groups from flocks/2.",
      icon:
        ~S(<circle class="mark-rock" cx="28" cy="28" r="26" opacity="0.25"/><circle class="mark-warm" cx="28" cy="30" r="9" opacity="0.35"/><circle class="mark-warm" cx="28" cy="30" r="3"/><circle class="mark-ink" cx="12" cy="14" r="3"/><circle class="mark-ink" cx="44" cy="12" r="3"/><circle class="mark-ink" cx="40" cy="44" r="3"/><circle class="mark-cool" cx="16" cy="42" r="3"/>),
      order: 130
    }
  end

  @width 160
  @height 90

  # The length of the clock of a firefly, in seconds, before the factor
  # of its group.
  @period 2.0
  # A flash of a neighbor multiplies the clock by 1 + @nudge: a firefly
  # near its flash moves more. So two parts of a group that flash at
  # different times do not stay apart. A firefly counts at most @most
  # flashes in one step.
  @nudge 0.1
  @most 5
  # A firefly that just flashed does not see the flashes of others.
  @rest 0.2
  # The distance at which the fireflies fly to the lantern.
  @radius 24

  @doc "The distance at which the fireflies fly to the lantern."
  def radius, do: @radius

  @doc "The length of the clock of a firefly in a group with the factor 1, in seconds."
  def period, do: @period

  @doc """
  The flashes of one moment: a flash that comes in this time (milliseconds)
  after the last flash is in the same flash of the field. So a wave of
  flashes, from neighbor to neighbor, is one flash of the field. One flash
  of the field is at most four times this time.
  """
  def window, do: max(150, 3 * BoidsExamples.Scene.tick())

  @doc """
  True when a flash at `time` is in the flash of the field that has its
  first flash at `first` and its last flash at `last` (milliseconds).
  """
  def same_flash?(first, last, time), do: time <= last + window() and time <= first + 4 * window()

  @doc """
  The next value of the clock of a firefly, from 0 to 1, after `dt`
  seconds. `flashes` is the number of neighbors that flashed since the
  last step: each flash multiplies the clock by 1.1. The result is
  `{clock, flashed}`: at 1 the firefly flashes, and its clock starts
  again at 0.
  """
  def next_clock(clock, dt, period, flashes) do
    clock = clock + dt / period
    clock = if clock > @rest, do: clock * (1 + @nudge * min(flashes, @most)), else: clock
    if clock >= 1.0, do: {0.0, true}, else: {clock, false}
  end

  @doc """
  A place for the lantern at the start of a level: the point of a grid
  of the field that is the farthest from the groups.
  """
  def away(points) do
    grid = for x <- 10..150//10, y <- 10..80//10, do: {x * 1.0, y * 1.0}
    Enum.max_by(grid, fn spot -> Enum.min(for point <- points, do: :boids_vec.dist(spot, point)) end)
  end

  @doc """
  The light of a firefly from 0 to 10: bright at its flash, then it
  fades in 0.7 second.
  """
  def light(%{flash: flash}, now) when is_integer(flash) do
    round(10 * max(0.0, 1.0 - (now - flash) / 700))
  end

  def light(_data, _now), do: 0

  @doc """
  The levels of the game. A group is `{{X, Y}, Count, Factor}`: the
  fireflies start near the point, and the length of their clock is the
  factor times 2 seconds. A group with a factor of 1.25 or more has slow
  clocks, and the page shows it in another color.
  """
  def levels do
    [
      %{title: "Two groups", dawn: 90, wind: false, groups: [{{42, 46}, 6, 1.0}, {{118, 44}, 6, 1.18}]},
      %{
        title: "Three groups",
        dawn: 110,
        wind: false,
        groups: [{{30, 24}, 6, 1.0}, {{82, 70}, 6, 1.16}, {{132, 26}, 6, 0.88}]
      },
      %{
        title: "Wind",
        dawn: 110,
        wind: true,
        groups: [{{34, 66}, 6, 1.0}, {{86, 22}, 6, 0.86}, {{130, 64}, 6, 1.14}]
      },
      %{
        title: "Slow clocks",
        dawn: 120,
        wind: false,
        groups: [{{30, 46}, 6, 1.0}, {{80, 18}, 5, 1.3}, {{130, 60}, 6, 0.9}]
      },
      %{
        title: "Far apart",
        dawn: 150,
        wind: true,
        groups: [{{22, 18}, 5, 1.0}, {{138, 18}, 5, 1.15}, {{22, 74}, 5, 0.88}, {{138, 74}, 5, 1.28}]
      }
    ]
  end

  defmodule Firefly do
    @moduledoc """
    A firefly. Its clock grows at each step, and it flashes at the end
    of its clock. Its data has the time of its last flash (`flash`, in
    milliseconds of the monotonic clock), which its neighbors see. A
    firefly that sees neighbors flash since its last step moves its
    clock forward (`next_clock/4`).
    """
    @behaviour :gen_boid
    alias BoidsExamples.Games.FireflyField, as: Field

    @impl true
    def init(%{pos: pos, factor: factor, table: table} = options) do
      rules = [
        {:separation, 1.6, %{radius: 2.6}},
        {:cohesion, 0.7},
        {:alignment, 0.3},
        {:wander, 0.7, %{jitter: 1.5}},
        {:contain, 2.5, %{margin: 8}},
        {&Firefly.home/3, 0.6},
        {&Firefly.lantern/3, 1.6}
      ]

      rules = if Map.get(options, :wind), do: rules ++ [{:flow, 0.6, %{field: fn _pos -> wind(table) end}}], else: rules

      state = %{
        clock: Map.get(options, :clock, :rand.uniform()),
        period: Map.get(options, :period, Field.period() * factor * (0.97 + :rand.uniform() * 0.06)),
        seen: now(),
        table: table,
        home: pos
      }

      {:ok,
       %{
         pos: pos,
         vel: :boids_vec.scale(:boids_vec.random_unit(2), 1.0 + :rand.uniform()),
         group: :fireflies,
         perception: 12,
         max_speed: 6.0,
         min_speed: 0.6,
         rules: rules,
         data: %{flash: nil, slow: factor >= 1.25},
         state: state
       }}
    end

    @doc """
    The force to the home of the firefly: the place where the lantern
    left it. A firefly far from its home flies back to it.
    """
    def home(%{pos: pos, state: %{home: home}} = boid, _neighbors, _seen) do
      if :boids_vec.dist(pos, home) > 3, do: :boids_steer.arrive(boid, home, 10), else: {0.0, 0.0}
    end

    @doc """
    The force to the lantern, for a firefly at the distance of the
    lantern or nearer: to the lantern, and slower near it.
    """
    def lantern(%{pos: pos} = boid, _neighbors, %{lantern: {x, y}}) do
      if :boids_vec.dist(pos, {x, y}) <= Field.radius(), do: :boids_steer.arrive(boid, {x, y}, 8), else: {0.0, 0.0}
    end

    # handle_sense/2 adds the lantern to what the firefly perceives.
    @impl true
    def handle_sense(seen, %{state: %{table: table}} = boid) do
      lantern = :ets.lookup_element(table, :lantern, 2, {-1000.0, -1000.0})
      {:ok, Map.put(seen, :lantern, lantern), boid}
    end

    # Decide: the flashes of the neighbors since the last step move the
    # clock forward. At the end of the clock, the firefly flashes.
    @impl true
    def handle_decide(%{neighbors: neighbors, dt: dt, lantern: lantern}, %{state: state, data: data} = boid) do
      now = now()
      since = state.seen

      flashes =
        Enum.count(neighbors, &match?(%{group: :fireflies, data: %{flash: f}} when is_integer(f) and f > since, &1))

      {clock, flashed} = Field.next_clock(state.clock, dt, state.period, flashes)
      data = if flashed, do: %{data | flash: now}, else: data
      # In the light of the lantern, the home of the firefly goes with it.
      home = if :boids_vec.dist(boid.pos, lantern) <= Field.radius(), do: boid.pos, else: state.home
      {:ok, %{boid | data: data, state: %{state | clock: clock, seen: now, home: home}}}
    end

    defp wind(table), do: :ets.lookup_element(table, :wind, 2, {0.0, 0.0})
    defp now, do: System.monotonic_time(:millisecond)
  end

  defmodule Director do
    @moduledoc """
    The process of a night. It has the level, the lantern and the wind
    in a table that the fireflies read. At each tick it moves the lantern
    and reads the flashes: the flashes that come one after the other, each
    in a short time (`window/0`), are one flash of the field. When all the fireflies
    flash in one flash of the field, three times in a row, the level is
    done. At the dawn, the night ends.
    """
    use GenServer
    alias BoidsExamples.Games.FireflyField, as: Field

    # The speed of the lantern, in units for each second: slower than a
    # firefly, so the fireflies in its light follow it. A fast move
    # (the key fast) leaves them behind.
    @speed 5.0
    @fast 13.0

    def start_link(space, options), do: GenServer.start_link(__MODULE__, {space, options})
    def status(director), do: GenServer.call(director, :status)
    def input(director, message), do: GenServer.cast(director, {:input, message})

    # --- GenServer -------------------------------------------------------

    @impl true
    def init({space, options}) do
      table = :ets.new(:firefly_field, [:set, :public, read_concurrency: true])

      state = %{
        space: space,
        options: options,
        table: table,
        level: 0,
        state: :night,
        keys: %{},
        target: nil,
        lantern: {80.0, 45.0},
        wind: 0.0,
        total: 0,
        burst: nil,
        last: 0,
        best: 0,
        streak: 0,
        flashes: 0,
        groups: 0,
        seen: now(),
        start: now(),
        time: 0,
        dawn: 0
      }

      # The director stops with the world.
      Process.monitor(space.owner)
      send(self(), :tick)
      send(self(), :second)
      {:ok, level(state, Map.get(options, :level, 1))}
    end

    @impl true
    def handle_call(:status, _from, state) do
      {x, y} = state.lantern
      left = max(0, state.dawn - div(elapsed(state), 1000))

      status = %{
        r: [
          ["Level", state.level],
          ["Groups", state.groups],
          ["Last flash", "#{state.last} of #{state.total}"],
          ["Best", "#{state.best} of #{state.total}"],
          ["Dawn in", "#{left} s"]
        ],
        h: %{ground: "night"},
        x: %{
          state: state.state,
          level: state.level,
          levels: length(Field.levels()),
          title: Enum.at(Field.levels(), state.level - 1).title,
          streak: state.streak,
          last: state.last,
          best: state.best,
          total: state.total,
          groups: state.groups,
          dawn: left,
          time: round(elapsed(state) / 100) / 10,
          lantern: [Float.round(x, 1), Float.round(y, 1)],
          radius: Field.radius(),
          wind: Map.get(state.options, :wind, Enum.at(Field.levels(), state.level - 1).wind)
        }
      }

      {:reply, status, state}
    end

    @impl true
    def handle_cast({:input, %{"keys" => names}}, state) when is_list(names) do
      keys =
        for name <- names, name in ["left", "right", "up", "down", "fast"], into: %{} do
          {String.to_existing_atom(name), true}
        end

      # The keys of a direction stop a move to a point. The key fast alone
      # does not.
      moving = Map.drop(keys, [:fast]) != %{}
      {:noreply, %{state | keys: keys, target: if(moving, do: nil, else: state.target)}}
    end

    def handle_cast({:input, %{"lantern" => [x, y]}}, state) when is_number(x) and is_number(y) do
      {:noreply, %{state | target: clamp({x * 1.0, y * 1.0})}}
    end

    # The next level after a level that is done, or the same level again
    # after the dawn.
    def handle_cast({:input, %{"go" => true}}, %{state: :done} = state) do
      next = if state.level >= length(Field.levels()), do: 1, else: state.level + 1
      {:noreply, level(state, next)}
    end

    def handle_cast({:input, %{"go" => true}}, %{state: :dawn} = state), do: {:noreply, level(state, state.level)}
    def handle_cast(_message, state), do: {:noreply, state}

    @impl true
    def handle_info({:DOWN, _ref, :process, _pid, _reason}, state), do: {:stop, :normal, state}

    def handle_info(:tick, state) do
      Process.send_after(self(), :tick, BoidsExamples.Scene.tick())
      {:noreply, state |> move() |> blow() |> flashes()}
    end

    def handle_info(:second, state) do
      Process.send_after(self(), :second, 1000)
      groups = length(:boids.flocks(state.space, 12, :local))
      state = %{state | groups: groups}
      {:noreply, if(state.state == :night and elapsed(state) >= state.dawn * 1000, do: stop(state, :dawn), else: state)}
    end

    # The lantern moves with the keys, or to the point of a click.
    defp move(%{keys: keys, target: target, lantern: lantern} = state) do
      dt = BoidsExamples.Scene.tick() / 1000
      speed = if keys[:fast], do: @fast, else: @speed
      x = if(keys[:right], do: 1.0, else: 0.0) - if(keys[:left], do: 1.0, else: 0.0)
      y = if(keys[:up], do: 1.0, else: 0.0) - if(keys[:down], do: 1.0, else: 0.0)

      {lantern, target} =
        cond do
          {x, y} != {0.0, 0.0} ->
            {:boids_vec.add(lantern, :boids_vec.scale(:boids_vec.normalize({x, y}), speed * dt)), nil}

          target != nil ->
            to = :boids_vec.sub(target, lantern)

            if :boids_vec.norm(to) <= speed * dt,
              do: {target, nil},
              else: {:boids_vec.add(lantern, :boids_vec.scale(:boids_vec.normalize(to), speed * dt)), target}

          true ->
            {lantern, nil}
        end

      lantern = clamp(lantern)
      :ets.insert(state.table, {:lantern, lantern})
      %{state | lantern: lantern, target: target}
    end

    # The wind turns slowly: one turn in 40 seconds.
    defp blow(%{level: level, options: options} = state) do
      if Map.get(options, :wind, Enum.at(Field.levels(), level - 1).wind) do
        angle = elapsed(state) / 40_000 * 2 * :math.pi()
        :ets.insert(state.table, {:wind, {:math.cos(angle), :math.sin(angle)}})
      end

      state
    end

    # Read the flashes since the last tick. A flash that comes at most one
    # window after the last flash is in the same flash of the field, which
    # is at most four windows long. The burst is {first, last, ids}.
    defp flashes(%{space: space} = state) do
      now = now()
      rows = :boids.snapshot(space, :local)
      new = for %{id: id, data: %{flash: f}} <- rows, is_integer(f) and f > state.seen, do: {f, id}
      state = %{state | seen: now, total: length(rows)}

      state =
        Enum.reduce(Enum.sort(new), state, fn {time, id}, acc ->
          case acc.burst do
            {first, last, ids} ->
              if Field.same_flash?(first, last, time),
                do: %{acc | burst: {first, time, MapSet.put(ids, id)}},
                else: acc |> close() |> Map.put(:burst, {time, time, MapSet.new([id])})

            nil ->
              %{acc | burst: {time, time, MapSet.new([id])}}
          end
        end)

      case state.burst do
        {first, last, _ids} -> if Field.same_flash?(first, last, now), do: state, else: close(state)
        nil -> state
      end
    end

    # The end of a flash of the field: how many fireflies flashed in it.
    defp close(%{burst: {_first, _last, ids}} = state) do
      size = MapSet.size(ids)
      all = size >= state.total and state.total > 0
      streak = if all, do: state.streak + 1, else: 0
      state = %{state | burst: nil, last: size, best: max(state.best, size), streak: streak, flashes: state.flashes + 1}
      if state.state == :night and streak >= 3, do: stop(state, :done), else: state
    end

    defp stop(state, how), do: %{state | state: how, time: elapsed(state)}

    # Start a level: clear the world, then the groups of fireflies.
    defp level(%{space: space, options: options, table: table} = state, number) do
      for %{id: id} <- :boids.snapshot(space, :local), do: :boids.remove(space, id)
      setting = Map.merge(Enum.at(Field.levels(), number - 1), Map.take(options, [:groups, :dawn, :wind]))
      :ets.insert(table, {:wind, {0.0, 0.0}})

      for {{cx, cy}, count, factor} <- setting.groups, _ <- 1..count//1 do
        pos = {cx + :rand.uniform() * 8 - 4, cy + :rand.uniform() * 8 - 4}
        firefly = %{pos: pos, factor: factor, table: table, wind: setting.wind}
        {:ok, _} = :gen_boid.start(space, Firefly, Map.merge(firefly, Map.take(options, [:clock, :period])))
      end

      lantern = Map.get(options, :lantern, Field.away(for {point, _count, _factor} <- setting.groups, do: point))
      :ets.insert(table, {:lantern, lantern})
      total = Enum.sum(for {_point, count, _factor} <- setting.groups, do: count)

      %{
        state
        | level: number,
          state: :night,
          dawn: setting.dawn,
          keys: %{},
          target: nil,
          lantern: lantern,
          total: total,
          burst: nil,
          last: 0,
          best: 0,
          streak: 0,
          flashes: 0,
          groups: length(setting.groups),
          seen: now(),
          start: now(),
          time: 0
      }
    end

    defp clamp({x, y}), do: {min(max(x, 2.0), 158.0), min(max(y, 2.0), 88.0)}
    defp elapsed(%{state: :night, start: start}), do: now() - start
    defp elapsed(%{time: time}), do: time
    defp now, do: System.monotonic_time(:millisecond)
  end

  # --- The scene ---------------------------------------------------------

  # The argument is nil for a visitor. A test gives options of the
  # director: the level, the groups, the dawn (seconds), the wind, the
  # place of the lantern, and a clock or a period for each firefly.
  @impl true
  def start(options) do
    {:ok, world} =
      :boids.start_world(
        bounds: {{0, 0}, {@width, @height}},
        wrap: false,
        cell_size: 12,
        defaults: %{tick: BoidsExamples.Scene.tick()}
      )

    space = :boids.space(world)
    {:ok, director} = Director.start_link(space, options || %{})
    {:ok, %{space: space, director: director}}
  end

  @impl true
  def kinds(_scene) do
    [
      %{name: "fireflies", shape: "firefly", color: "ink", size: 1.4},
      %{name: "fireflies with a slow clock", shape: "firefly", color: "plum", size: 1.4}
    ]
  end

  @impl true
  def header(_scene), do: %{ground: "night"}

  @impl true
  def look(_scene, %{data: %{slow: slow} = data, vel: vel}) do
    {if(slow, do: 1, else: 0), BoidsExamples.Scene.angle(vel), light(data, System.monotonic_time(:millisecond))}
  end

  @impl true
  def more(%{director: director}, _number), do: Director.status(director)

  @impl true
  def input(%{director: director}, message), do: Director.input(director, message)
end
