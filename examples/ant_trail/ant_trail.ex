defmodule BoidsExamples.Games.AntTrail do
  @moduledoc """
  Ant Trail: ants leave their nest and search for food. An ant that finds
  food takes a piece, and goes home. On its way home, it leaves a scent
  on the ground. The other ants follow the scent, and a trail grows from
  the nest to the food. No ant knows the trail: it comes from the scent
  of many ants. The person places food and rocks, and sends rain that
  washes the scent away.

  The example shows these parts of the library:

  - The rule `flow` with a field that is a function of a position. The
    field of an ant that searches is the direction to the stronger scent
    near it (`field/1`).
  - A shared state of the world that the boids read and write: the scent
    is a grid in an ETS table of the land. Each ant with food marks its
    cell, and each ant that searches reads the cells near it. The scent
    fades with the time.
  - A path that emerges: the mark of an ant with food is stronger near
    the food than near the nest, so the scent shows the way to the food.
    A cell keeps its strongest mark. A short way gets new marks more
    frequently than a long way, and its marks are stronger, so the trail
    takes the short way.
  - A state of each boid that changes its rules: an ant that searches,
    and an ant with food.

  The `Director` is the process of the land: the tables of the food and
  of the scent, the rocks, the count of the food at the nest, and the
  length of the last trips.
  """
  @behaviour BoidsExamples.Scene
  use BoidsExamples.Game

  @impl BoidsExamples.Game
  def info do
    %{
      slug: "ant-trail",
      title: "Ant Trail",
      tag: "Watch and change",
      pitch:
        "Ants search for food, and an ant with food leaves a scent on its way home. Place food and rocks, and see the ants make a trail.",
      shows:
        "the rule flow with a field that is a function, a grid of scent that the boids read and write, and a trail that no ant knows.",
      icon:
        ~S(<circle class="mark-rock" cx="14" cy="42" r="8"/><path class="mark-cool" d="M18 36 Q30 30 44 16" stroke-width="3" fill="none" opacity="0.5"/><circle class="mark-ink" cx="24" cy="31" r="3"/><circle class="mark-ink" cx="33" cy="25" r="3"/><circle class="mark-warm" cx="44" cy="15" r="4"/>),
      order: 110
    }
  end

  @width 160
  @height 90

  # The nest: its center and its radius.
  @nest {20.0, 45.0}
  @nest_radius 5.0

  # The grid of the scent: cells of 2 by 2 units.
  @cell 2.0
  @columns 80
  @rows 45

  # An ant smells the scent at 8 points on a circle of 3 units round it.
  # It does not follow a scent of less than 1 at each point: an old
  # trail goes.
  @sense 3.0
  @faint 8.0
  @ring for k <- 0..7, do: {:math.cos(k * :math.pi() / 4), :math.sin(k * :math.pi() / 4)}

  # An ant with food marks its cell with a scent of 10 at the food. The
  # scent of its mark falls with the distance that the ant walked from
  # the food: it is half at 28 units. So the scent is stronger near the
  # food. A cell keeps the strongest mark, and the scent of a mark falls
  # to half in 8 seconds of the land.
  @max_scent 10.0
  @reach 40.0
  @half_life 8_000

  # The most ants, piles of food and rocks of the land, and the pieces of
  # food of a pile.
  @ants 40
  @max_piles 8
  @max_rocks 10
  @pile 40
  @rock_radius 4.0

  @doc "The size of the land."
  def box, do: {@width, @height}

  @doc "The nest: its center and its radius."
  def nest, do: {@nest, @nest_radius}

  @doc "The most ants of the land."
  def ants, do: @ants

  @doc "The limits of the land: the most piles of food and rocks, the pieces of a pile, and the radius of a rock."
  def limits, do: %{piles: @max_piles, rocks: @max_rocks, pieces: @pile, rock: @rock_radius}

  @doc "The time in which the scent of a cell falls to half, in milliseconds of the land."
  def half_life, do: @half_life

  @doc "The layouts of the land that the person can start."
  def layouts, do: ~w(piles bridge empty)

  # --- The scent ----------------------------------------------------------------

  @doc "The cell of the grid of the scent at a position, or nil out of the land."
  def cell({x, y}) when x >= 0 and y >= 0 and x < @width and y < @height do
    trunc(x / @cell) + trunc(y / @cell) * @columns
  end

  def cell(_pos), do: nil

  @doc "The center of a cell of the grid."
  def center(index), do: {(rem(index, @columns) + 0.5) * @cell, (div(index, @columns) + 0.5) * @cell}

  @doc "The time of the land in milliseconds: the time of the clock with the scale of the time."
  def time(%{t0: t0, scale: scale}), do: (System.monotonic_time(:millisecond) - t0) * scale

  @doc "The scent at a position now: it falls to half in each half life."
  def scent(land, pos), do: at(land, pos, time(land))

  defp value(%{scent: table, half_life: half_life}, index, now) do
    case :ets.lookup(table, index) do
      [{_, value, at}] -> value * :math.pow(0.5, (now - at) / half_life)
      [] -> 0.0
    end
  catch
    # The table goes with the director, at the end of the land.
    :error, :badarg -> 0.0
  end

  @doc """
  Mark a position with a scent: its cell gets the scent, and each of the
  4 cells next to it gets the half of the scent. A cell keeps the
  stronger scent: its scent now, or the new scent. So many ants on the
  same way do not add their scent: the scent tells how near the food is,
  and how new the trail is.
  """
  def mark(land, {x, y}, scent) do
    now = time(land)
    put(land, cell({x, y}), scent, now)

    for pos <- [{x + @cell, y}, {x - @cell, y}, {x, y + @cell}, {x, y - @cell}],
        do: put(land, cell(pos), scent / 2, now)

    :ok
  end

  defp put(_land, nil, _scent, _now), do: :ok

  defp put(land, index, scent, now) do
    if scent > value(land, index, now), do: :ets.insert(land.scent, {index, min(scent, @max_scent), now})
    :ok
  catch
    # The table goes with the director, at the end of the land.
    :error, :badarg -> :ok
  end

  @doc """
  The field of the scent: a function of a position, for the rule `flow`.
  It gives the direction to the stronger scent near the position: the sum
  of the directions to 8 points on a circle round the position, each
  with the scent at that point. Where the ground has almost no scent, or
  where the scent is the same at all sides, it gives a zero vector.
  """
  def field(land) do
    fn {x, y} ->
      now = time(land)

      {gx, gy, total} =
        Enum.reduce(@ring, {0.0, 0.0, 0.0}, fn {ux, uy}, {gx, gy, total} ->
          s = at(land, {x + ux * @sense, y + uy * @sense}, now)
          {gx + s * ux, gy + s * uy, total + s}
        end)

      if total < @faint or :math.sqrt(gx * gx + gy * gy) < 0.1 * total, do: {0.0, 0.0}, else: {gx, gy}
    end
  end

  defp at(land, pos, now) do
    case cell(pos) do
      nil -> 0.0
      index -> value(land, index, now)
    end
  end

  @doc "The cells with scent: a list of `{index, scent}`, with the scent now."
  def cells(land) do
    now = time(land)

    for {index, value, at} <- :ets.tab2list(land.scent),
        scent = value * :math.pow(0.5, (now - at) / land.half_life),
        scent >= 0.1,
        do: {index, scent}
  end

  # --- The food -----------------------------------------------------------------

  @doc "The piles of food: a list of `{id, x, y, pieces}`."
  def piles(%{food: food}), do: :ets.tab2list(food)

  @doc "The nearest pile of food at the distance `radius` or less: `{id, position, distance}`, or nil."
  def nearest_pile(land, {x, y}, radius) do
    land
    |> piles()
    |> Enum.map(fn {id, fx, fy, _pieces} -> {id, {fx, fy}, :math.sqrt((fx - x) ** 2 + (fy - y) ** 2)} end)
    |> Enum.filter(fn {_id, _at, dist} -> dist <= radius end)
    |> Enum.min_by(fn {_id, _at, dist} -> dist end, fn -> nil end)
  catch
    :error, :badarg -> nil
  end

  @doc "Take a piece of a pile. Only one ant gets each piece. The last piece removes the pile."
  def take(%{food: food}, id) do
    case :ets.update_counter(food, id, {4, -1}) do
      left when left > 0 ->
        true

      0 ->
        :ets.delete(food, id)
        true

      _less ->
        :ets.delete(food, id)
        false
    end
  catch
    :error, :badarg -> false
  end

  # --- An ant ---------------------------------------------------------------------

  defmodule Ant do
    @moduledoc """
    An ant. An ant that searches wanders, goes to the food that it sees,
    and follows the scent (the rule `flow` with the field of the scent).
    An ant that touches food takes a piece, and its rules change: it goes
    home, and leaves scent on its way. At the nest, it gives the food, and
    searches again.
    """
    @behaviour :gen_boid
    alias BoidsExamples.Games.AntTrail

    @impl true
    def init(%{id: id, pos: pos, land: land}) do
      {:ok,
       %{
         id: id,
         pos: pos,
         vel: :boids_vec.scale(:boids_vec.random_unit(2), 5.0),
         group: :ants,
         max_speed: 9.0,
         min_speed: 3.0,
         perception: 8.0,
         max_force: 30,
         rules: rules(:search, land),
         data: :search,
         state: %{mode: :search, land: land, walked: 0.0, dt: 0.0}
       }}
    end

    @doc "The rules of an ant that searches, and of an ant with food."
    def rules(:search, land) do
      follow = if land.follow, do: [{:flow, 2.2, %{field: AntTrail.field(land), predict: 0.3}}], else: []

      [{:avoid, 4.0, %{lookahead: 0.8}}, {&Ant.to_food/3, 3.0}] ++
        follow ++
        [
          {:wander, 1.0, %{jitter: 3.0}},
          {:separation, 0.5, %{radius: 1.5}},
          {:contain, 3.0, %{margin: 5}}
        ]
    end

    def rules(:carry, _land) do
      {nest, _radius} = AntTrail.nest()

      [
        {:avoid, 4.0, %{lookahead: 0.8}},
        {:seek, 2.0, %{target: nest}},
        {:wander, 0.3},
        {:separation, 0.5, %{radius: 1.5}},
        {:contain, 3.0, %{margin: 5}}
      ]
    end

    @doc "A rule that is a function: the force to the food that the ant sees, or none."
    def to_food(boid, _neighbors, %{food: {_x, _y} = at}), do: :boids_steer.seek(boid, at)
    def to_food(_boid, _neighbors, _seen), do: {0.0, 0.0}

    # Sense: an ant that searches sees the nearest food, and takes a piece
    # of food that it touches. An ant with food that comes to the nest
    # gives the food, and searches again.
    @impl true
    def handle_sense(%{dt: dt} = seen, %{pos: pos, perception: perception, state: state0} = boid0) do
      state = %{state0 | dt: dt}
      boid = %{boid0 | state: state}
      land = state.land

      case state.mode do
        :search ->
          case AntTrail.nearest_pile(land, pos, perception) do
            {id, at, dist} when dist <= 1.6 ->
              if AntTrail.take(land, id),
                do: {:ok, Map.put(seen, :food, nil), carry(boid)},
                else: {:ok, Map.put(seen, :food, at), boid}

            {_id, at, _dist} ->
              {:ok, Map.put(seen, :food, at), boid}

            nil ->
              {:ok, Map.put(seen, :food, nil), boid}
          end

        :carry ->
          {nest, radius} = AntTrail.nest()

          if :boids_vec.dist(pos, nest) <= radius do
            AntTrail.Director.home(land, state.walked)
            {:ok, Map.put(seen, :food, nil), search(boid)}
          else
            {:ok, Map.put(seen, :food, nil), boid}
          end
      end
    end

    # Act: an ant with food leaves scent in its cell. The scent is
    # stronger near the food: it falls with the distance that the ant
    # walked from the food.
    @impl true
    def handle_act(%{pos: pos, vel: vel, state: %{mode: :carry, land: land, walked: walked, dt: dt} = state} = boid) do
      AntTrail.mark(land, pos, AntTrail.strength(walked))
      {:ok, %{boid | state: %{state | walked: walked + :boids_vec.norm(vel) * dt}}}
    end

    def handle_act(boid), do: {:ok, boid}

    defp carry(%{state: state} = boid) do
      changed = :boids_boid.update(boid, %{rules: rules(:carry, state.land), data: :carry})
      %{changed | state: %{state | mode: :carry, walked: 0.0}}
    end

    # The ant gives the food at the nest, and goes out again: it turns
    # back.
    defp search(%{vel: vel, state: state} = boid) do
      changed =
        :boids_boid.update(boid, %{rules: rules(:search, state.land), data: :search, vel: :boids_vec.neg(vel)})

      %{changed | state: %{state | mode: :search, walked: 0.0}}
    end
  end

  @doc "The scent of the mark of an ant with food, after it walked `walked` units from the food."
  def strength(walked), do: @max_scent * :math.exp(-walked / @reach)

  # --- The director ---------------------------------------------------------------

  defmodule Director do
    @moduledoc """
    The process of the land: the tables of the food and of the scent, the
    ants that it starts from the nest, the rocks, the food at the nest,
    and the length of the last trips. The ants read and write the tables
    with no message to the director. An ant tells the director when it
    brings food home.
    """
    use GenServer
    alias BoidsExamples.Games.AntTrail

    def start_link(space, options), do: GenServer.start_link(__MODULE__, {space, options})
    def status(director, number), do: GenServer.call(director, {:status, number})
    def input(director, message), do: GenServer.cast(director, {:input, message})
    def state(director), do: GenServer.call(director, :state)

    @doc "An ant brought a piece of food home, after a trip of `walked` units."
    def home(%{director: director}, walked), do: GenServer.cast(director, {:home, walked})

    # --- GenServer ------------------------------------------------------------------

    @impl true
    def init({space, options}) do
      options =
        Map.merge(
          %{
            ants: AntTrail.ants(),
            layout: "piles",
            scale: 1.0,
            half_life: AntTrail.half_life(),
            follow: true,
            seed: nil
          },
          options
        )

      if options.seed, do: :rand.seed(:exsss, options.seed)
      :boids.set_time_scale(space, options.scale)

      land = %{
        space: space,
        food: :ets.new(:ant_food, [:set, :public, read_concurrency: true, write_concurrency: true]),
        scent: :ets.new(:ant_scent, [:set, :public, read_concurrency: true, write_concurrency: true]),
        director: self(),
        t0: System.monotonic_time(:millisecond),
        scale: options.scale * 1.0,
        half_life: options.half_life,
        follow: options.follow
      }

      state = %{
        land: land,
        options: options,
        home: 0,
        trips: [],
        rocks: [],
        started: 0,
        layout: options.layout,
        piles: 0
      }

      # A part of the ants comes out of the nest at once, and the others
      # one after the other.
      :timer.send_interval(200, :spawn)
      :timer.send_interval(1000, :second)
      {:ok, state |> layout(options.layout) |> spawn_ants(min(12, options.ants))}
    end

    @impl true
    def handle_call({:status, number}, _from, state), do: {:reply, readings(state, number), state}
    def handle_call(:state, _from, state), do: {:reply, state, state}

    @impl true
    def handle_cast({:home, walked}, state) do
      {:noreply, %{state | home: state.home + 1, trips: Enum.take([walked | state.trips], 10)}}
    end

    def handle_cast({:input, message}, state), do: {:noreply, change(message, state)}

    @impl true
    def handle_info(:spawn, state) do
      if state.started < state.options.ants, do: {:noreply, spawn_ants(state, 1)}, else: {:noreply, state}
    end

    # Each second: the cells with almost no scent go from the table.
    def handle_info(:second, %{land: land} = state) do
      now = AntTrail.time(land)

      for {index, value, at} <- :ets.tab2list(land.scent), value * :math.pow(0.5, (now - at) / land.half_life) < 0.05 do
        :ets.delete(land.scent, index)
      end

      {:noreply, state}
    end

    # --- The person changes the land ----------------------------------------------

    defp change(%{"place" => [x, y], "item" => "food"}, state) when is_number(x) and is_number(y) do
      limits = AntTrail.limits()

      if length(AntTrail.piles(state.land)) < limits.piles and free?(state, {x, y}, 3.0) and
           AntTrail.nearest_pile(state.land, {x, y}, 4.0) == nil,
         do: pile(state, {x, y}, limits.pieces),
         else: state
    end

    defp change(%{"place" => [x, y], "item" => "rock"}, state) when is_number(x) and is_number(y) do
      if length(state.rocks) < AntTrail.limits().rocks and free?(state, {x, y}, 0.0),
        do: rock(state, {x, y}),
        else: state
    end

    defp change(%{"rain" => true}, state) do
      :ets.delete_all_objects(state.land.scent)
      state
    end

    defp change(%{"layout" => name}, state) when is_binary(name) do
      if name in AntTrail.layouts(), do: restart(state, name), else: state
    end

    defp change(_message, state), do: state

    # A place for a pile or a rock: in the land, not at the nest, and not
    # in a rock. A pile also needs a place with no other pile near it.
    defp free?(state, {x, y} = pos, margin) do
      {{nx, ny}, radius} = AntTrail.nest()
      {width, height} = AntTrail.box()

      x >= 4 and x <= width - 4 and y >= 4 and y <= height - 4 and
        :math.sqrt((x - nx) ** 2 + (y - ny) ** 2) > radius + 5 and
        not Enum.any?(state.rocks, fn {rx, ry, r} -> :boids_vec.dist(pos, {rx, ry}) < r + margin end)
    end

    defp pile(state, {x, y}, pieces) do
      :ets.insert(state.land.food, {state.piles, x * 1.0, y * 1.0, pieces})
      %{state | piles: state.piles + 1}
    end

    defp rock(state, {x0, y0}) do
      {x, y} = {x0 * 1.0, y0 * 1.0}
      radius = AntTrail.limits().rock
      :ok = :boids.set_obstacle(state.land.space, {:rock, length(state.rocks)}, {x, y}, radius)

      # The food under a rock goes.
      for {id, fx, fy, _pieces} <- AntTrail.piles(state.land), :boids_vec.dist({fx, fy}, {x, y}) < radius + 1 do
        :ets.delete(state.land.food, id)
      end

      %{state | rocks: state.rocks ++ [{x, y, radius}]}
    end

    # --- The layouts --------------------------------------------------------------

    # The land of a layout: "piles" (food near the nest and food far from
    # it), "bridge" (food behind a wall of rocks, with a short way below
    # the wall and a long way above it) and "empty".
    defp layout(state, "piles") do
      pieces = AntTrail.limits().pieces
      state |> pile({55, 62}, pieces) |> pile({135, 25}, pieces)
    end

    defp layout(state, "bridge") do
      state = Enum.reduce([36, 44, 52, 60, 68], state, fn y, acc -> rock(acc, {75, y}) end)
      pile(state, {130, 25}, 2 * AntTrail.limits().pieces)
    end

    defp layout(state, "empty"), do: state

    # A new land: the ants go, the rocks, the food and the scent go, and
    # the ants come out of the nest again.
    defp restart(%{land: land} = state, name) do
      for %{id: id} <- :boids.snapshot(land.space, :local), do: :boids.remove(land.space, id)
      for index <- 0..(length(state.rocks) - 1)//1, do: :boids.remove_obstacle(land.space, {:rock, index})
      :ets.delete_all_objects(land.food)
      :ets.delete_all_objects(land.scent)

      %{state | home: 0, trips: [], rocks: [], started: 0, layout: name}
      |> layout(name)
      |> spawn_ants(min(12, state.options.ants))
    end

    defp spawn_ants(state, count) do
      {{x, y}, radius} = AntTrail.nest()
      count = min(count, state.options.ants - state.started)

      for _ <- 1..count//1 do
        at = :boids_vec.add({x, y}, :boids_vec.scale(:boids_vec.random_unit(2), :rand.uniform() * (radius - 1)))
        ant = %{id: make_ref(), pos: at, land: state.land}
        {:ok, _pid} = :gen_boid.start(state.land.space, AntTrail.Ant, ant)
      end

      %{state | started: state.started + max(count, 0)}
    end

    # --- The readings -------------------------------------------------------------

    defp readings(%{land: land} = state, number) do
      rows = :boids.snapshot(land.space, :local)
      piles = AntTrail.piles(land)
      trip = if state.trips == [], do: "-", else: "#{round(Enum.sum(state.trips) / length(state.trips))} units"

      status = %{
        r: [
          ["Ants", length(rows)],
          ["With food", Enum.count(rows, &(&1.data == :carry))],
          ["Home", state.home],
          ["Food left", Enum.sum(for {_id, _x, _y, pieces} <- piles, do: pieces)],
          ["Trip", trip]
        ],
        h: %{rocks: for({x, y, radius} <- state.rocks, do: [x, y, radius])},
        x: %{piles: for({_id, x, y, pieces} <- piles, v <- [x, y, pieces], do: v), layout: state.layout}
      }

      # The scent is a larger list: it goes four times in a second.
      if rem(number, max(div(250, BoidsExamples.Scene.tick()), 1)) == 0 do
        scent = for {index, value} <- AntTrail.cells(land), v <- [index, level(value)], do: v
        put_in(status.x[:scent], scent)
      else
        status
      end
    end

    # The scent of a cell for the page: 1 to 9.
    defp level(value), do: value |> Kernel./(10.0) |> Kernel.*(9) |> round() |> max(1) |> min(9)
  end

  # --- The scene ---------------------------------------------------------------------

  # The argument is nil for a visitor. A test gives options of the
  # director: the number of ants, the layout, the scale of the time, the
  # half life of the scent, `follow: false` (the ants do not follow the
  # scent), and a seed.
  @impl true
  def start(options) do
    {:ok, world} =
      :boids.start_world(
        bounds: {{0, 0}, {@width, @height}},
        wrap: false,
        cell_size: 10,
        defaults: %{tick: BoidsExamples.Scene.tick()}
      )

    space = :boids.space(world)
    {:ok, director} = Director.start_link(space, options || %{})
    {:ok, %{space: space, director: director}}
  end

  @impl true
  def kinds(_scene) do
    [
      %{name: "ants", shape: "ant", color: "ink", size: 1.1},
      %{name: "ants with food", shape: "ant", color: "leaf", size: 1.1}
    ]
  end

  @impl true
  def header(_scene) do
    {{x, y}, radius} = nest()

    %{
      ground: "sand",
      zones: [[x - radius - 1, y - radius - 1, x + radius + 1, y + radius + 1, "fur", "Nest"]],
      grid: %{cell: @cell, columns: @columns, rows: @rows},
      nest: [x, y, radius]
    }
  end

  @impl true
  def look(_scene, %{data: :carry, vel: vel}), do: {1, BoidsExamples.Scene.angle(vel), 0}
  def look(_scene, %{vel: vel}), do: {0, BoidsExamples.Scene.angle(vel), 0}

  @impl true
  def more(%{director: director}, number), do: Director.status(director, number)

  @impl true
  def input(%{director: director}, message), do: Director.input(director, message)
end
