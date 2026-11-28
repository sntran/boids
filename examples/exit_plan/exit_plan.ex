defmodule BoidsExamples.Games.ExitPlan do
  @moduledoc """
  Exit Plan: a puzzle about a crowd. A hall full of people has two or
  three doors. Before the alarm, the person places pillars and signs.
  Then the alarm sounds, and all the people go out. Too many people in a
  small place make a crush, and people get hurt.

  The example shows these parts of the library:

  - A crowd is boids. Each person goes to a door, walks around the
    pillars, keeps a distance, and stays in the hall. No person knows the
    plan of the crowd.
  - A rule that is a function: `walls/3`, `sign/3` and `to_door/3` read
    the hall, the doors and the signs from the state of the person (the
    key `state` of the boid).
  - Obstacles that a person places while the world runs: each pillar is
    an obstacle of the world (`boids:set_obstacle/4`), and the rule
    `avoid` sees it at once.
  - An effect of the crowd that no person makes alone: the crush at a
    door. A pillar a little in front of a door divides the crowd, and
    fewer people get hurt.

  The `Director` is the process of a level: the hall, the pillars and the
  signs of the person, the phase, and the counts.
  """
  @behaviour BoidsExamples.Scene
  use BoidsExamples.Game

  @impl BoidsExamples.Game
  def info do
    %{
      slug: "exit-plan",
      title: "Exit Plan",
      tag: "Puzzle",
      pitch:
        "Place pillars and signs in a full hall, then sound the alarm. Bring all the people out fast, with no one hurt in the crush at the doors.",
      shows:
        "a crowd as boids, rules that are functions, obstacles that a person places while the world runs, and a crush that no person makes alone.",
      icon:
        ~S(<rect class="mark-rock" x="4" y="6" width="48" height="44" rx="2" opacity="0.35"/><rect class="mark-cool" x="48" y="20" width="6" height="14"/><circle class="mark-rock" cx="38" cy="27" r="4"/><circle class="mark-ink" cx="14" cy="18" r="3"/><circle class="mark-ink" cx="20" cy="30" r="3"/><circle class="mark-ink" cx="12" cy="40" r="3"/><circle class="mark-ink" cx="26" cy="22" r="3"/><circle class="mark-warm" cx="28" cy="38" r="3"/>),
      order: 70
    }
  end

  # The hall of each level, the half side of a sign, and the distance
  # from a wall where the walls push a person.
  @hall {110, 66}
  @sign 7
  @margin 2.0

  @doc "The levels of the game."
  def levels do
    [
      %{
        name: "One door",
        hall: @hall,
        doors: [{:right, 32, 34.5}],
        people: 36,
        area: {55, 10, 98, 56},
        pillars: 2,
        signs: 0,
        good: 18.0,
        limit: 45.0,
        hint:
          "All the people go to one door. A pillar about 10 units in front of the door divides the crowd. Find the best place."
      },
      %{
        name: "The far door",
        hall: @hall,
        doors: [{:right, 31.5, 34.5}, {:left, 31.5, 34.5}],
        people: 40,
        area: {60, 8, 102, 58},
        pillars: 1,
        signs: 2,
        good: 22.0,
        limit: 60.0,
        hint:
          "The people are near one door, and the other door is empty. A sign sends people to the doors in its direction."
      },
      %{
        name: "Three doors",
        hall: @hall,
        doors: [{:right, 31.5, 34.5}, {:top, 15, 18}, {:bottom, 85, 88}],
        people: 44,
        area: {50, 10, 100, 56},
        pillars: 2,
        signs: 3,
        good: 20.0,
        limit: 60.0,
        hint:
          "Three doors, and most people are near one of them. Use the signs to share the crowd, and a pillar where the crowd is thick."
      },
      %{
        name: "The narrow door",
        hall: @hall,
        doors: [{:right, 32, 34.5}, {:left, 10, 18}],
        people: 46,
        area: {58, 8, 104, 58},
        pillars: 2,
        signs: 2,
        good: 22.0,
        limit: 60.0,
        hint: "The narrow door is near, and the wide door is far. Where do two signs help most?"
      },
      %{
        name: "Full hall",
        hall: @hall,
        doors: [{:right, 31, 35}, {:top, 54, 58}, {:left, 31, 35}],
        people: 46,
        area: {60, 4, 106, 50},
        pillars: 3,
        signs: 3,
        good: 22.0,
        limit: 60.0,
        hint: "Three doors, and the crowd is near one of them. Share the crowd between all the doors."
      }
    ]
  end

  @doc "A level, from its number (1 is the first)."
  def level(number), do: Enum.at(levels(), number - 1)

  @doc "The direction of an arrow."
  def arrow("left"), do: {-1.0, 0.0}
  def arrow("right"), do: {1.0, 0.0}
  def arrow("up"), do: {0.0, 1.0}
  def arrow("down"), do: {0.0, -1.0}

  @doc "The point of a door at the wall: the middle of the gap."
  def door_point({:right, a, b}, {w, _h}), do: {w * 1.0, (a + b) / 2}
  def door_point({:left, a, b}, _hall), do: {0.0, (a + b) / 2}
  def door_point({:top, a, b}, {_w, h}), do: {(a + b) / 2, h * 1.0}
  def door_point({:bottom, a, b}, _hall), do: {(a + b) / 2, 0.0}

  # The point that a person walks to: 3 units out of the hall, so that
  # the person goes through the door and does not stop at it.
  defp out_point({wall, _a, _b} = door, hall) do
    {x, y} = door_point(door, hall)

    case wall do
      :right -> {x + 3, y}
      :left -> {x - 3, y}
      :top -> {x, y + 3}
      :bottom -> {x, y - 3}
    end
  end

  @doc "True when a position is at a door, out of the hall."
  def at_door?({x, y}, doors, {w, h}) do
    Enum.any?(doors, fn
      {:right, a, b} -> x >= w - 0.3 and y >= a and y <= b
      {:left, a, b} -> x <= 0.3 and y >= a and y <= b
      {:top, a, b} -> y >= h - 0.3 and x >= a and x <= b
      {:bottom, a, b} -> y <= 0.3 and x >= a and x <= b
    end)
  end

  # --- The rules that are functions ----------------------------------------

  @doc """
  The rule of the walls: a person near a wall goes away from it, except
  in front of a door. The hall and the doors are in the state of the
  person.
  """
  def walls(%{pos: {x, y}, vel: {vx, vy}, max_speed: speed, state: %{hall: {w, h}, doors: doors}}, _ns, _seen) do
    open = fn wall, along ->
      Enum.any?(doors, fn {side, a, b} -> side == wall and along >= a - 0.5 and along <= b + 0.5 end)
    end

    fx = push(x, 0, :left, y, open, speed, vx) + push(x, w, :right, y, open, speed, vx)
    fy = push(y, 0, :bottom, x, open, speed, vy) + push(y, h, :top, x, open, speed, vy)
    {fx, fy}
  end

  # The force of one wall on one axis: toward the inside of the hall, more
  # when the person is nearer the wall.
  defp push(p, wall, side, along, open, speed, v) do
    inside = if side in [:left, :bottom], do: p - wall, else: wall - p
    direction = if side in [:left, :bottom], do: 1.0, else: -1.0

    cond do
      open.(side, along) -> 0.0
      inside >= @margin -> 0.0
      true -> direction * speed * (1 + (@margin - inside) / @margin) - v * 0.5
    end
  end

  @doc """
  The rule of the signs: in the zone of a sign, a person gets a push in
  the direction of its arrow.
  """
  def sign(%{pos: pos, vel: vel, max_speed: speed, state: %{signs: signs}}, _ns, _seen) do
    case Enum.find(signs, &in_sign?(pos, &1)) do
      nil -> {0.0, 0.0}
      %{dir: dir} -> :boids_vec.sub(:boids_vec.scale(arrow(dir), speed), vel)
    end
  end

  @doc "True when a position is in the zone of a sign."
  def in_sign?({x, y}, %{x: sx, y: sy}), do: abs(x - sx) <= @sign and abs(y - sy) <= @sign

  @doc """
  The rule of the doors: a person goes to the nearest door. A person that
  passed a sign goes to the nearest door in the direction of the arrow of
  that sign.
  """
  def to_door(%{pos: pos, state: %{doors: doors, hall: hall, hint: hint}} = boid, _ns, _seen) do
    door = door_of(pos, doors, hall, hint)
    :boids_steer.seek(boid, out_point(door, hall))
  end

  @doc "The door that a person at a position goes to."
  def door_of(pos, doors, hall, hint) do
    ahead =
      case hint do
        nil -> doors
        dir -> Enum.filter(doors, &(:boids_vec.dot(:boids_vec.sub(door_point(&1, hall), pos), arrow(dir)) > 0))
      end

    Enum.min_by(if(ahead == [], do: doors, else: ahead), &:boids_vec.dist(pos, door_point(&1, hall)))
  end

  defmodule Person do
    @moduledoc """
    A person in the hall. Before the alarm, the person walks slowly. After
    the alarm, the person goes out by a door. A person in a crush for 1.5
    seconds is hurt: the person stops and stays on the floor. A person
    at a door is safe, and stops. The person tells the director when it
    is safe or hurt.
    """
    @behaviour :gen_boid
    alias BoidsExamples.Games.ExitPlan

    # A crush: this number of people, or more, at this distance or less.
    @crowd 5
    @near 1.5
    @hurt 1.0

    # The speed of a person: the fastest with no person near, less for
    # each person at the distance @dense or less.
    @fastest 6.0
    @slowest 1.0
    @step 0.8
    @dense 2.0

    @doc "The rules of a person before the alarm."
    def waiting do
      [
        {&ExitPlan.walls/3, 3.0},
        {:avoid, 3.0, %{lookahead: 1.0}},
        {:separation, 1.0, %{radius: 2.0}},
        {:wander, 0.6}
      ]
    end

    @doc "The rules of a person after the alarm."
    def leaving do
      [
        {&ExitPlan.walls/3, 3.0},
        {:avoid, 3.0, %{lookahead: 0.8}},
        {&ExitPlan.sign/3, 2.0},
        {&ExitPlan.to_door/3, 2.0},
        {:separation, 0.6, %{radius: 1.2}}
      ]
    end

    @impl true
    def init(%{id: id, pos: pos, director: director, hall: hall, doors: doors}) do
      {:ok,
       %{
         id: id,
         pos: pos,
         group: :people,
         data: :waiting,
         perception: 6,
         max_speed: 1.2,
         max_force: 30,
         rules: waiting(),
         state: %{director: director, hall: hall, doors: doors, signs: [], hint: nil, crush: 0.0, mode: :waiting}
       }}
    end

    # The alarm: the person goes out, with the signs of the person.
    @impl true
    def handle_cast({:alarm, signs}, %{state: %{mode: :waiting} = state} = boid) do
      boid = :boids_boid.update(boid, %{rules: leaving(), max_speed: @fastest, data: :leaving})
      {:noreply, %{boid | state: %{state | signs: signs, mode: :leaving}}}
    end

    def handle_cast(_message, boid), do: {:noreply, boid}

    # Decide: a person that passes a sign keeps its arrow. A person in a
    # crush for some time is hurt.
    @impl true
    def handle_decide(%{neighbors: neighbors, dt: dt}, %{pos: pos, state: %{mode: :leaving} = state} = boid) do
      hint =
        case Enum.find(state.signs, &ExitPlan.in_sign?(pos, &1)) do
          nil -> state.hint
          %{dir: dir} -> dir
        end

      crowded = Enum.count(neighbors, &(&1.group == :people and &1.dist <= @near)) >= @crowd
      crush = if crowded, do: state.crush + dt, else: max(state.crush - dt, 0.0)

      # A person in a dense crowd walks slowly: the more people near, the
      # lower the speed. This makes the jam at a door.
      dense = Enum.count(neighbors, &(&1.dist <= @dense))
      boid = %{boid | max_speed: max(@slowest, @fastest - @step * dense)}

      if crush >= @hurt do
        GenServer.cast(state.director, {:hurt, boid.id})
        hurt = :boids_boid.update(boid, %{rules: [], max_speed: 0.0, vel: {0.0, 0.0}, group: :hurt, data: :hurt})
        {:ok, %{hurt | state: %{state | mode: :hurt, hint: hint, crush: crush}}}
      else
        {:ok, %{boid | state: %{state | hint: hint, crush: crush}}}
      end
    end

    def handle_decide(_seen, boid), do: {:ok, boid}

    # Act: a person at a door is safe.
    @impl true
    def handle_act(%{pos: pos, state: %{mode: :leaving, doors: doors, hall: hall} = state} = boid) do
      if ExitPlan.at_door?(pos, doors, hall) do
        GenServer.cast(state.director, {:safe, boid.id})
        {:stop, :normal, boid}
      else
        {:ok, boid}
      end
    end

    def handle_act(boid), do: {:ok, boid}
  end

  defmodule Director do
    @moduledoc """
    The process of a level: the hall, the pillars and the signs of the
    person, the phase (`planning`, `leaving` or `done`), the counts of the
    people, and the result.

    With the option `manual`, the boids move only with `advance/2`, and
    the time of the level is the sum of the steps. The tests use it, and
    the options `people` and `limit` for small levels.
    """
    use GenServer
    alias BoidsExamples.Games.ExitPlan
    alias BoidsExamples.Games.ExitPlan.Person

    # The radius of a pillar.
    @pillar 2.5

    def start_link(space, options), do: GenServer.start_link(__MODULE__, {space, options})
    def status(director), do: GenServer.call(director, :status)
    def input(director, message), do: GenServer.cast(director, {:input, message})

    @doc "Make steps of the world for `seconds` (only with the option `manual`). The result is the status."
    def advance(director, seconds), do: GenServer.call(director, {:advance, seconds}, 60_000)

    # --- GenServer -------------------------------------------------------

    @impl true
    def init({space, options}) do
      state = %{
        space: space,
        manual: Map.get(options, :manual, false),
        # A test can give the number of people and the time limit of each
        # level.
        overrides: Map.take(options, [:people, :limit]),
        level: 0,
        plan: nil,
        phase: :planning,
        pillars: [],
        signs: [],
        people: %{},
        safe: 0,
        hurt: 0,
        started: 0,
        elapsed: 0.0,
        result: nil
      }

      {:ok, start_level(state, Map.get(options, :level, 1), [], [])}
    end

    @impl true
    def handle_call(:status, _from, state) do
      state = check(state)
      {:reply, report(state), state}
    end

    def handle_call({:advance, seconds}, _from, %{manual: true} = state) do
      steps = max(round(seconds / 0.05), 1)

      state =
        Enum.reduce_while(1..steps, state, fn _step, state ->
          :ok = :boids.step(state.space, 0.05)
          state = if state.phase == :leaving, do: %{state | elapsed: state.elapsed + 0.05}, else: state
          state = receive_reports(state)
          state = check(state)
          if state.phase == :done, do: {:halt, state}, else: {:cont, state}
        end)

      {:reply, report(state), state}
    end

    @impl true
    def handle_cast({how, id}, state) when how in [:safe, :hurt] do
      {:noreply, check(count(state, how, id))}
    end

    def handle_cast({:input, message}, state), do: {:noreply, check(apply_input(message, state))}

    # The inputs of the person. Before the alarm: pillars, signs, remove,
    # clear and the alarm. After a level: again, the next level, or a
    # level of the list.
    defp apply_input(%{"pillar" => [x, y]}, %{phase: :planning} = state) when is_number(x) and is_number(y) do
      if length(state.pillars) < state.plan.pillars and inside?({x, y}, state.plan.hall, @pillar + 0.5) do
        put_pillars(state, state.pillars ++ [{x * 1.0, y * 1.0}])
      else
        state
      end
    end

    defp apply_input(%{"sign" => [x, y, dir]}, %{phase: :planning} = state)
         when is_number(x) and is_number(y) and dir in ["left", "right", "up", "down"] do
      if length(state.signs) < state.plan.signs and inside?({x, y}, state.plan.hall, 0) do
        %{state | signs: state.signs ++ [%{x: x * 1.0, y: y * 1.0, dir: dir}]}
      else
        state
      end
    end

    defp apply_input(%{"remove" => [x, y]}, %{phase: :planning} = state) when is_number(x) and is_number(y) do
      pillars = Enum.reject(state.pillars, &(:boids_vec.dist(&1, {x, y}) <= @pillar + 1))

      if pillars != state.pillars do
        put_pillars(state, pillars)
      else
        %{state | signs: Enum.reject(state.signs, &ExitPlan.in_sign?({x, y}, &1))}
      end
    end

    defp apply_input(%{"clear" => true}, %{phase: :planning} = state), do: put_pillars(%{state | signs: []}, [])

    defp apply_input(%{"alarm" => true}, %{phase: :planning} = state) do
      for {_id, %{pid: pid}} <- state.people, do: :gen_boid.cast(pid, {:alarm, state.signs})
      %{state | phase: :leaving, started: now(), elapsed: 0.0}
    end

    defp apply_input(%{"again" => true}, %{phase: phase} = state) when phase in [:leaving, :done] do
      start_level(state, state.level, state.pillars, state.signs)
    end

    defp apply_input(%{"next" => true}, %{phase: :done} = state) do
      start_level(state, min(state.level + 1, length(ExitPlan.levels())), [], [])
    end

    defp apply_input(%{"level" => number}, state) when is_integer(number) do
      if number >= 1 and number <= length(ExitPlan.levels()), do: start_level(state, number, [], []), else: state
    end

    defp apply_input(_message, state), do: state

    # --- A level ---------------------------------------------------------

    defp start_level(%{space: space} = state, number, pillars, signs) do
      plan = Map.merge(ExitPlan.level(number), state.overrides)
      for %{id: id} <- :boids.snapshot(space, :local), do: :boids.remove(space, id)
      state = put_pillars(%{state | plan: plan}, pillars)
      {x0, y0, x1, y1} = plan.area

      people =
        Map.new(1..plan.people, fn _n ->
          id = make_ref()
          pos = {x0 + :rand.uniform() * (x1 - x0), y0 + :rand.uniform() * (y1 - y0)}
          options = %{id: id, pos: pos, director: self(), hall: plan.hall, doors: plan.doors}
          {:ok, pid} = :gen_boid.start(space, Person, options)
          {id, %{pid: pid, status: :inside}}
        end)

      %{
        state
        | level: number,
          phase: :planning,
          signs: signs,
          people: people,
          safe: 0,
          hurt: 0,
          started: 0,
          elapsed: 0.0,
          result: nil
      }
    end

    # The pillars are obstacles of the world: the rule avoid sees them.
    defp put_pillars(%{space: space} = state, pillars) do
      for %{id: id} <- :boids.obstacles(space), do: :boids.remove_obstacle(space, id)
      for {{x, y}, n} <- Enum.with_index(pillars), do: :ok = :boids.set_obstacle(space, {:pillar, n}, {x, y}, @pillar)
      %{state | pillars: pillars}
    end

    defp inside?({x, y}, {w, h}, margin), do: x >= margin and x <= w - margin and y >= margin and y <= h - margin

    # A person tells one time that it is safe or hurt.
    defp count(state, how, id) do
      case state.people do
        %{^id => %{status: :inside} = person} ->
          people = %{state.people | id => %{person | status: how}}
          state = %{state | people: people}

          case how do
            :safe -> %{state | safe: state.safe + 1}
            :hurt -> %{state | hurt: state.hurt + 1}
          end

        _ ->
          state
      end
    end

    # In the manual mode, the reports of the people come in the mailbox
    # of the director during a step.
    defp receive_reports(state) do
      receive do
        {:"$gen_cast", {how, id}} when how in [:safe, :hurt] -> receive_reports(count(state, how, id))
      after
        0 -> state
      end
    end

    defp inside(state), do: Enum.count(state.people, fn {_id, person} -> person.status == :inside end)

    defp time(%{manual: true} = state), do: state.elapsed
    defp time(%{phase: :leaving} = state), do: (now() - state.started) / 1000
    defp time(state), do: state.elapsed

    # The end of a level: the hall is empty, or the time is over.
    defp check(%{phase: :leaving} = state) do
      time = time(state)

      cond do
        inside(state) == 0 -> finish(%{state | elapsed: time}, :empty)
        time > state.plan.limit -> finish(%{state | elapsed: time}, :late)
        true -> state
      end
    end

    defp check(state), do: state

    defp finish(%{space: space} = state, how) do
      for {id, %{status: :inside}} <- state.people, do: :boids.remove(space, id)
      %{state | phase: :done, result: result(state, how)}
    end

    defp result(state, :late) do
      %{stars: 0, text: "The time is over: #{inside(state)} people are still in the hall. Try again."}
    end

    defp result(%{plan: plan, hurt: hurt, elapsed: time}, :empty) do
      fast = time <= plan.good
      stars = 1 + if(fast, do: 1, else: 0) + if(hurt == 0, do: 1, else: 0)

      text =
        cond do
          stars == 3 ->
            "3 of 3 stars. A safe and fast plan!"

          hurt > 0 and fast ->
            "#{stars} of 3 stars. #{hurt} people were hurt in the crush. Try a pillar in front of a door."

          hurt > 0 ->
            "#{stars} of 3 stars. #{hurt} people were hurt, and the time is long. Share the crowd between the doors."

          true ->
            "#{stars} of 3 stars. All are safe. Can you be out in #{round(plan.good)} seconds?"
        end

      %{stars: stars, text: text}
    end

    defp report(state) do
      %{plan: plan} = state

      %{
        r: [
          ["Level", state.level],
          ["In the hall", inside(state)],
          ["Safe", state.safe],
          ["Hurt", state.hurt],
          ["Time", "#{:erlang.float_to_binary(time(state) * 1.0, decimals: 1)} s"]
        ],
        h: %{rocks: for({x, y} <- state.pillars, do: [x, y, @pillar]), zones: ExitPlan.zones(plan, state.signs)},
        x: %{
          phase: state.phase,
          level: state.level,
          levels: length(ExitPlan.levels()),
          name: plan.name,
          hint: plan.hint,
          good: plan.good,
          limit: plan.limit,
          pillars: length(state.pillars),
          pillars_most: plan.pillars,
          signs: for(%{x: x, y: y, dir: dir} <- state.signs, do: [x, y, dir]),
          doors: for({wall, a, b} <- plan.doors, do: [wall, a, b]),
          signs_most: plan.signs,
          safe: state.safe,
          hurt: state.hurt,
          time: Float.round(time(state) * 1.0, 1),
          result: state.result
        }
      }
    end

    defp now, do: System.monotonic_time(:millisecond)
  end

  @doc "The zones of a level for the page: the doors, and the signs."
  def zones(%{doors: doors, hall: {w, h}}, signs) do
    doors =
      for door <- doors do
        case door do
          {:right, a, b} -> [w - 2.5, a, w, b, "cool"]
          {:left, a, b} -> [0, a, 2.5, b, "cool"]
          {:top, a, b} -> [a, h - 2.5, b, h, "cool"]
          {:bottom, a, b} -> [a, 0, b, 2.5, "cool"]
        end
      end

    doors ++ for(%{x: x, y: y} <- signs, do: [x - @sign, y - @sign, x + @sign, y + @sign, "warm"])
  end

  # --- The scene -------------------------------------------------------------

  # The argument is nil for a visitor. A test gives options of the
  # director: the level, and `manual`.
  @impl true
  def start(options) do
    options = options || %{}
    tick = if Map.get(options, :manual, false), do: :manual, else: BoidsExamples.Scene.tick()

    # The box of the world is the hall. Each level has a hall of this size.
    {:ok, world} = :boids.start_world(bounds: {{0, 0}, @hall}, wrap: false, defaults: %{tick: tick})
    space = :boids.space(world)
    {:ok, director} = Director.start_link(space, options)
    {:ok, %{space: space, director: director}}
  end

  @impl true
  def kinds(_scene) do
    [
      %{name: "people", shape: "person", color: "cool", size: 1.1},
      %{name: "hurt", shape: "person", color: "warm", size: 1.1}
    ]
  end

  @impl true
  def header(%{director: director}) do
    %{h: %{zones: zones}} = Director.status(director)
    %{ground: "floor", zones: zones}
  end

  @impl true
  def look(_scene, %{group: :hurt}), do: {1, 0, 0}
  def look(_scene, %{vel: vel}), do: {0, BoidsExamples.Scene.angle(vel), 0}

  @impl true
  def more(%{director: director}, _number), do: Director.status(director)

  @impl true
  def input(%{director: director}, message), do: Director.input(director, message)
end
