defmodule BoidsExamples.Games.NightFold do
  @moduledoc """
  Night Fold: the person is a sheepdog. Sheep graze, scattered in a
  field. The person must bring them into the fold, through its opening,
  before the night. At night, wolves come from the edges and take the
  sheep that are outside the fold.

  The example shows these parts of the library:

  - One boid that a person controls moves a whole flock. The dog does not
    push a sheep: each sheep flees from the dog that it sees (the rule
    `flee` with the target `{group, dog}`), and stays near the other
    sheep (`cohesion`, `alignment`).
  - A flock is something that no sheep is: `boids:flocks/2` counts the
    groups of sheep that see each other. A scattered flock is harder to
    move.
  - A boid changes its group: a sheep that comes into the fold has the
    group `penned` and other rules. A wolf hunts only the group `sheep`,
    so a sheep in the fold is safe.
  - Messages between boids: a wolf that touches a sheep sends `taken` to
    the process of the sheep, which stops.

  The `Director` is the process of a field: the day, the night, the count
  of the sheep in the fold and of the lost sheep, and the wolves.
  """
  @behaviour BoidsExamples.Scene
  use BoidsExamples.Game

  @impl BoidsExamples.Game
  def info do
    %{
      slug: "night-fold",
      title: "Night Fold",
      tag: "Keys",
      pitch:
        "You are a sheepdog. Bring the scattered sheep into the fold before the night: they run from you, so come from the right side. At night, wolves take the sheep that are outside.",
      shows:
        "one boid that a person controls moves a whole flock, because each sheep flees from it, and the flock is something that no sheep is (flocks/2).",
      icon:
        ~S(<rect class="mark-cool" x="34" y="14" width="18" height="28" opacity="0.4"/><circle class="mark-ink" cx="14" cy="20" r="3.5"/><circle class="mark-ink" cx="22" cy="26" r="3.5"/><circle class="mark-ink" cx="16" cy="32" r="3.5"/><circle class="mark-cool" cx="44" cy="28" r="3.5"/><path class="mark-warm" d="M10 46 L2 50 L4 46 L2 42 Z"/>),
      order: 60
    }
  end

  @width 160
  @height 90

  # The fold: a pen at the right of the field. Its front wall, at x = 128,
  # has an opening at its middle.
  @fold {128, 30, 152, 60}

  @doc "The steps of a boid in a time in milliseconds."
  def steps(milliseconds), do: max(div(milliseconds, BoidsExamples.Scene.tick()), 1)

  @doc "The walls of the fold: `{X0, Y0, X1, Y1}`. Its opening is in the wall at the left."
  def fold, do: @fold

  @doc "True when a point is inside the walls of the fold."
  def in_fold?({x, y}) do
    {x0, y0, x1, y1} = @fold
    x > x0 + 1.5 and x < x1 - 1.5 and y > y0 + 1.5 and y < y1 - 1.5
  end

  @doc """
  True when a boid that moves from `from` to `to` goes into the fold
  through its opening, of this width, in the wall at the left.
  """
  def through_opening?({x1, y1} = from, {x2, y2} = to, opening) do
    {x0, y0, _x1, y_1} = @fold
    line = x0 + 1.5

    if not in_fold?(from) and in_fold?(to) and x1 <= line and x2 > line do
      # The height where the boid crosses the line of the wall.
      y = y1 + (y2 - y1) * (line - x1) / (x2 - x1)
      abs(y - (y0 + y_1) / 2) < opening / 2
    else
      false
    end
  end

  @doc """
  The fence posts of the fold, as `{X, Y}`, for an opening of this width
  in the middle of the wall at the left.
  """
  def posts(opening) do
    {x0, y0, x1, y1} = @fold
    middle = (y0 + y1) / 2
    top = for x <- x0..x1//2, do: {x * 1.0, y1 * 1.0}
    bottom = for x <- x0..x1//2, do: {x * 1.0, y0 * 1.0}
    back = for y <- (y0 + 2)..(y1 - 2)//2, do: {x1 * 1.0, y * 1.0}
    front = for y <- (y0 + 2)..(y1 - 2)//2, abs(y - middle) >= opening / 2, do: {x0 * 1.0, y * 1.0}
    top ++ bottom ++ back ++ front
  end

  defmodule Dog do
    @moduledoc """
    The sheepdog. The person moves it with the keys `left`, `right`, `up`,
    `down`, and `run`. Its force is a rule of its own: a function that
    reads the keys. Its data shows if it runs.
    """
    @behaviour :gen_boid

    @walk 7.0
    @run 14.0

    @impl true
    def init(pos) do
      {:ok,
       %{
         pos: pos,
         group: :dog,
         perception: 6,
         max_speed: @run,
         max_force: 80,
         rules: [{&Dog.legs/3, 1.0}],
         data: %{running: false},
         state: %{keys: %{}}
       }}
    end

    @doc "The force of the dog: to the velocity that the keys ask for. With no key, the dog stops."
    def legs(%{vel: vel, state: %{keys: keys}}, _neighbors, _seen) do
      x = if(keys[:right], do: 1.0, else: 0.0) - if(keys[:left], do: 1.0, else: 0.0)
      y = if(keys[:up], do: 1.0, else: 0.0) - if(keys[:down], do: 1.0, else: 0.0)
      speed = if keys[:run], do: @run, else: @walk
      :boids_vec.scale(:boids_vec.sub(:boids_vec.scale(:boids_vec.normalize({x, y}), speed), vel), 5.0)
    end

    # Act: the dog stays in the field.
    @impl true
    def handle_act(%{pos: {x, y}, vel: vel} = boid) do
      pos = {min(max(x, 1.0), 159.0), min(max(y, 1.0), 89.0)}
      {:ok, %{boid | pos: pos, data: %{running: :boids_vec.norm(vel) > 9.0}}}
    end

    @impl true
    def handle_cast({:keys, keys}, %{state: state} = boid), do: {:noreply, %{boid | state: %{state | keys: keys}}}
  end

  defmodule Sheep do
    @moduledoc """
    A sheep. It grazes slowly, and stays near the other sheep. It flees
    from the dog and from the wolves that it sees near it, fast. The fence
    stops it: a sheep comes into the fold only through the opening. A
    sheep that comes inside the walls of the fold has the group `penned`:
    it stays in the fold, and the wolves do not hunt it. A wolf that
    touches a sheep sends `taken`: the sheep tells the director, and
    stops.
    """
    @behaviour :gen_boid
    alias BoidsExamples.Games.NightFold, as: Fold

    @field {{2, 2}, {158, 88}}
    @graze 2.2
    @flee 8.0

    @impl true
    def init(%{pos: pos, director: director, opening: opening}) do
      {:ok,
       %{
         pos: pos,
         vel: :boids_vec.scale(:boids_vec.random_unit(2), 1.0),
         group: :sheep,
         perception: 20,
         max_speed: @graze,
         rules: rules(),
         state: %{director: director, opening: opening, last: pos}
       }}
    end

    @doc "The rules of a sheep outside the fold."
    def rules do
      [
        {:avoid, 4.0, %{lookahead: 1.2}},
        {:contain, 3.0, %{bounds: @field, margin: 5}},
        {{:flee, :dog}, 4.0, %{target: {:group, :dog}, radius: 14}},
        {{:flee, :wolves}, 4.0, %{target: {:group, :wolves}, radius: 12}},
        {:separation, 1.5, %{radius: 2.5}},
        {:cohesion, 1.0},
        {:alignment, 0.6},
        {:wander, 0.5}
      ]
    end

    @doc "The rules of a sheep in the fold: it stays inside the walls."
    def penned do
      {x0, y0, x1, y1} = Fold.fold()

      [
        {:contain, 4.0, %{bounds: {{x0 + 3, y0 + 3}, {x1 - 3, y1 - 3}}, margin: 3}},
        {:separation, 1.5, %{radius: 2.5}},
        {:wander, 0.3}
      ]
    end

    # Decide: a sheep that sees the dog or a wolf near it runs. Else it
    # grazes slowly.
    @impl true
    def handle_decide(_seen, %{group: :penned} = boid), do: {:ok, boid}

    def handle_decide(%{neighbors: neighbors}, %{max_speed: speed} = boid) do
      afraid =
        Enum.any?(neighbors, fn n ->
          (n.group == :dog and n.dist <= 14) or (n.group == :wolves and n.dist <= 12)
        end)

      case {afraid, speed} do
        {true, @flee} -> {:ok, boid}
        {true, _} -> {:ok, :boids_boid.update(boid, %{max_speed: @flee})}
        {false, @graze} -> {:ok, boid}
        {false, _} -> {:ok, :boids_boid.update(boid, %{max_speed: @graze})}
      end
    end

    # Act: the fence stops a sheep that comes into the fold not through
    # the opening. A sheep that came inside the walls stays there.
    @impl true
    def handle_act(%{group: :sheep, pos: pos, vel: vel, state: %{last: last, opening: opening} = state} = boid) do
      cond do
        not Fold.in_fold?(pos) ->
          {:ok, %{boid | state: %{state | last: pos}}}

        Fold.in_fold?(last) or Fold.through_opening?(last, pos, opening) ->
          {:ok,
           :boids_boid.update(%{boid | state: %{state | last: pos}}, %{group: :penned, rules: penned(), max_speed: 2.0})}

        true ->
          {:ok, %{boid | pos: last, vel: :boids_vec.scale(vel, -0.3)}}
      end
    end

    def handle_act(boid), do: {:ok, boid}

    @impl true
    def handle_cast(:taken, %{group: :sheep, state: %{director: director}} = boid) do
      GenServer.cast(director, :lost)
      {:stop, :normal, boid}
    end

    def handle_cast(:taken, boid), do: {:noreply, boid}
  end

  defmodule Wolf do
    @moduledoc """
    A wolf comes at night. It hunts the nearest sheep that is outside the
    fold (the rule `pursue` with the target `{group, sheep}`), and flees
    from the dog. A wolf that touches a sheep sends `taken` to the
    process of the sheep, then rests for 2 seconds.
    """
    @behaviour :gen_boid
    alias BoidsExamples.Games.NightFold, as: Fold

    @impl true
    def init(pos) do
      {:ok,
       %{
         pos: pos,
         group: :wolves,
         perception: 30,
         max_speed: 9.5,
         max_force: 40,
         rules: hunt(),
         state: %{rest: 0}
       }}
    end

    defp hunt do
      [
        {:avoid, 4.0, %{lookahead: 1.0}},
        {:contain, 3.0, %{bounds: {{1, 1}, {159, 89}}, margin: 3}},
        {:flee, 5.0, %{target: {:group, :dog}, radius: 10}},
        {:pursue, 1.5, %{target: {:group, :sheep}}},
        {:wander, 0.6}
      ]
    end

    defp rest do
      [
        {:avoid, 4.0, %{lookahead: 1.0}},
        {:contain, 3.0, %{bounds: {{1, 1}, {159, 89}}, margin: 3}},
        {:flee, 5.0, %{target: {:group, :dog}, radius: 10}},
        {:wander, 1.0}
      ]
    end

    @impl true
    def handle_decide(_seen, %{state: %{rest: rest} = state} = boid) when rest > 1 do
      {:ok, %{boid | state: %{state | rest: rest - 1}}}
    end

    def handle_decide(_seen, %{state: %{rest: 1} = state} = boid) do
      {:ok, %{:boids_boid.update(boid, %{rules: hunt()}) | state: %{state | rest: 0}}}
    end

    def handle_decide(%{neighbors: neighbors, lookup: lookup}, %{state: state} = boid) do
      case Enum.find(neighbors, &(&1.group == :sheep and &1.dist <= 1.6)) do
        nil ->
          {:ok, boid}

        sheep ->
          with {:ok, %{pid: pid}} when is_pid(pid) <- lookup.(sheep.id), do: :gen_boid.cast(pid, :taken)
          {:ok, %{:boids_boid.update(boid, %{rules: rest()}) | state: %{state | rest: Fold.steps(2000)}}}
      end
    end
  end

  defmodule Director do
    @moduledoc """
    The process of a field: the phase (`day`, `night` or `done`), the
    time, the sheep in the fold, the lost sheep, and the flocks. At the
    night, it starts the wolves at the edges. At the dawn, or when no
    sheep is outside the fold, the field is done. With half of the sheep
    or more in the fold, the person goes to the next field.
    """
    use GenServer
    alias BoidsExamples.Games.NightFold, as: Fold

    @doc """
    The fields of the game. Each next field has more sheep in more
    groups, a smaller opening of the fold, a shorter day and more wolves.
    The times are in seconds.
    """
    def fields do
      [
        %{sheep: 14, groups: 2, opening: 20, day: 75, night: 25, wolves: 2},
        %{sheep: 18, groups: 3, opening: 14, day: 65, night: 25, wolves: 3},
        %{sheep: 22, groups: 4, opening: 10, day: 55, night: 25, wolves: 4}
      ]
    end

    def start_link(world, options), do: GenServer.start_link(__MODULE__, {world, options})
    def status(director), do: GenServer.call(director, :status)
    def input(director, message), do: GenServer.cast(director, {:input, message})

    # --- GenServer -------------------------------------------------------

    @impl true
    def init({world, options}) do
      # The director stops with the world.
      Process.monitor(world)
      send(self(), :check)

      state = %{
        world: world,
        space: :boids.space(world),
        options: options,
        field: 1,
        setting: nil,
        phase: :day,
        dog: nil,
        total: 0,
        penned: 0,
        lost: 0,
        flocks: 0,
        flocked: -1000,
        start: now(),
        time: 0,
        running: false
      }

      {:ok, field(state, Map.get(options, :field, 1))}
    end

    @impl true
    def handle_call(:status, _from, state), do: {:reply, report(state), state}

    @impl true
    def handle_cast(:lost, state), do: {:noreply, %{state | lost: state.lost + 1}}

    def handle_cast({:input, %{"keys" => names}}, %{phase: phase, dog: dog} = state)
        when is_list(names) and phase != :done do
      keys =
        for name <- names, name in ["left", "right", "up", "down", "run"], into: %{} do
          {String.to_existing_atom(name), true}
        end

      :gen_boid.cast(dog, {:keys, keys})
      {:noreply, state}
    end

    # The next field after a good field, or the same field again.
    def handle_cast({:input, %{"go" => true}}, %{phase: :done} = state) do
      next =
        cond do
          not pass?(state) -> state.field
          state.field >= length(fields()) -> 1
          true -> state.field + 1
        end

      {:noreply, field(state, next)}
    end

    def handle_cast(_message, state), do: {:noreply, state}

    @impl true
    def handle_info({:DOWN, _ref, :process, _pid, _reason}, state), do: {:stop, :normal, state}

    def handle_info(:check, state) do
      Process.send_after(self(), :check, BoidsExamples.Scene.tick())
      {:noreply, check(state)}
    end

    # At each tick: the sheep in the fold, the night, the dawn, and the
    # end of the field. The flocks, each second.
    defp check(%{phase: :done} = state), do: state

    defp check(%{space: space, setting: setting} = state) do
      rows = :boids.snapshot(space, :local)
      penned = Enum.count(rows, &(&1.group == :penned))
      outside = Enum.count(rows, &(&1.group == :sheep))
      dog = Enum.find(rows, &(&1.group == :dog))
      time = now() - state.start
      state = %{state | penned: penned, time: time, running: dog != nil and dog.data.running}

      state = if time - state.flocked >= 1000, do: flocks(%{state | flocked: time}, rows), else: state

      cond do
        outside == 0 and penned + state.lost >= state.total -> finish(state)
        state.phase == :day and time >= setting.day * 1000 -> night(state)
        state.phase == :night and time >= (setting.day + setting.night) * 1000 -> finish(state)
        true -> state
      end
    end

    # The groups of sheep that are outside the fold, from the flocks of
    # the world.
    defp flocks(%{space: space} = state, rows) do
      outside = MapSet.new(for %{group: :sheep, id: id} <- rows, do: id)
      groups = for flock <- :boids.flocks(space, 8, :local), Enum.any?(flock, &MapSet.member?(outside, &1)), do: flock
      %{state | flocks: length(groups)}
    end

    # The night: the wolves come from the edges at the left, at the top
    # and at the bottom.
    defp night(%{space: space, setting: setting} = state) do
      places =
        case setting.wolves do
          places when is_list(places) -> places
          count -> for i <- 1..count//1, do: edge(i)
        end

      for pos <- places, do: {:ok, _} = :gen_boid.start(space, Wolf, pos)
      %{state | phase: :night}
    end

    defp edge(i) do
      case rem(i, 3) do
        1 -> {2.0, 10 + :rand.uniform() * 70}
        2 -> {10 + :rand.uniform() * 100, 88.0}
        0 -> {10 + :rand.uniform() * 100, 2.0}
      end
    end

    # The end of a field: the dog and the sheep stop, and the wolves go.
    defp finish(%{space: space} = state) do
      for %{id: id, group: group} <- :boids.snapshot(space, :local), group == :wolves do
        :boids.remove(space, id)
      end

      :gen_boid.cast(state.dog, {:keys, %{}})
      %{state | phase: :done}
    end

    defp pass?(state), do: state.penned * 2 >= state.total

    # Start a field: clear the world, then the fold, the sheep and the dog.
    defp field(%{space: space, options: options} = state, number) do
      for %{id: id} <- :boids.snapshot(space, :local), do: :boids.remove(space, id)
      for %{id: id} <- :boids.obstacles(space), do: :boids.remove_obstacle(space, id)

      setting =
        Map.merge(Enum.at(fields(), number - 1), Map.take(options, [:sheep, :groups, :opening, :day, :night, :wolves]))

      posts = Fold.posts(setting.opening)
      for {pos, i} <- Enum.with_index(posts), do: :ok = :boids.set_obstacle(space, {:post, i}, pos, 1.1)

      places = positions(setting.sheep, setting.groups)

      for pos <- places do
        {:ok, _} = :gen_boid.start(space, Sheep, %{pos: pos, director: self(), opening: setting.opening})
      end

      {:ok, dog} = :gen_boid.start(space, Dog, Map.get(options, :dog, {10.0, 45.0}))

      %{
        state
        | field: number,
          setting: setting,
          phase: :day,
          dog: dog,
          total: length(places),
          penned: 0,
          lost: 0,
          flocks: 0,
          flocked: -1000,
          start: now(),
          time: 0,
          running: false
      }
    end

    # Sheep in groups that graze at random places of the field, away from
    # the fold and the dog, or the places that a test gives.
    defp positions(places, _groups) when is_list(places), do: places

    defp positions(count, groups) do
      centers = for _ <- 1..groups, do: {35 + :rand.uniform() * 70, 15 + :rand.uniform() * 60}

      for i <- 1..count//1 do
        {x, y} = Enum.at(centers, rem(i, groups))
        {x + :rand.uniform() * 12 - 6, y + :rand.uniform() * 12 - 6}
      end
    end

    defp report(state) do
      setting = state.setting
      seconds = div(state.time, 1000)

      # The clock has one label, so the page keeps one reading for it.
      {clock, left} =
        case state.phase do
          :day ->
            {"#{max(setting.day - seconds, 0)} s to night", max(setting.day - seconds, 0)}

          :night ->
            {"#{max(setting.day + setting.night - seconds, 0)} s to dawn",
             max(setting.day + setting.night - seconds, 0)}

          :done ->
            {"Done", 0}
        end

      %{
        r: [
          ["Field", state.field],
          ["In the fold", "#{state.penned} of #{state.total}"],
          ["Lost", state.lost],
          ["Clock", clock],
          ["Flocks", state.flocks]
        ],
        h: %{ground: "grass", zones: zones(state)},
        x: %{
          phase: state.phase,
          field: state.field,
          fields: length(fields()),
          penned: state.penned,
          total: state.total,
          lost: state.lost,
          left: left,
          flocks: state.flocks,
          pass: pass?(state),
          thrust: state.running,
          safe: false
        }
      }
    end

    # The fold, and a dark field at night.
    defp zones(state) do
      {x0, y0, x1, y1} = Fold.fold()
      fold = [x0, y0, x1, y1, "cool", "Fold"]
      if state.phase == :night, do: [[0, 0, 160, 90, "rock"], fold], else: [fold]
    end

    defp now, do: System.monotonic_time(:millisecond)
  end

  # --- The scene ---------------------------------------------------------

  # The argument is nil for a visitor. A test gives options of the
  # director: the field, the sheep (a number, or a list of places), the
  # opening, the day and the night in seconds, the wolves (a number, or a
  # list of places), and the place of the dog.
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
      %{name: "sheep", shape: "sheep", color: "wool", size: 1.4},
      %{name: "sheep in the fold", shape: "sheep", color: "gold", size: 1.4},
      %{name: "dog", shape: "dog", color: "fur", size: 2.2},
      %{name: "wolves", shape: "wolf", color: "rock", size: 2.5}
    ]
  end

  @impl true
  def header(%{director: director}), do: Director.status(director).h

  @impl true
  def look(_scene, %{group: :sheep, vel: vel}), do: {0, BoidsExamples.Scene.angle(vel), 0}
  def look(_scene, %{group: :penned, vel: vel}), do: {1, BoidsExamples.Scene.angle(vel), 0}
  def look(_scene, %{group: :dog, vel: vel}), do: {2, BoidsExamples.Scene.angle(vel), 0}
  def look(_scene, %{vel: vel}), do: {3, BoidsExamples.Scene.angle(vel), 0}

  @impl true
  def more(%{director: director}, _number), do: Director.status(director)

  @impl true
  def input(%{director: director}, message), do: Director.input(director, message)
end
