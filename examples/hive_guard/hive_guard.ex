defmodule BoidsExamples.Games.HiveGuard do
  @moduledoc """
  Hive Guard: waves of beetles walk along a path to a hive. The person
  places guard bees with nectar, and the bees defend the hive.

  - A beetle follows the path (the rule `follow`), and stays with its
    swarm (separation, alignment, a little cohesion). A beetle that
    reaches the hive takes one life of the hive. Some beetles are large:
    more health, and slower.
  - A guard bee stays near its post (the rule `arrive`). When it sees a
    beetle, it pursues it (the rule `pursue` with the group of the
    beetles), and stings a beetle that it touches: a message to the
    process of the beetle, which loses health and stops at 0. Then the
    bee rests for a short time. A bee does not go far from its post.
  - A scout is fast and sees near. A soldier is slow, sees far, and
    stings harder. Each costs nectar, and each killed beetle gives
    nectar.
  - The waves get larger. The game ends when the hive has no life, and
    the score is the number of waves that the hive stopped.

  The example shows these parts of the library:

  - the rule `follow` along a path;
  - the rule `pursue` of a group;
  - messages that change the state of another boid (a sting);
  - boids that the person starts while the world runs (the bees).

  The `Director` is the process of the game: the waves, the lives of the
  hive, the nectar, and the bees.
  """
  @behaviour BoidsExamples.Scene
  use BoidsExamples.Game

  alias BoidsExamples.Scene

  @impl BoidsExamples.Game
  def info do
    %{
      slug: "hive-guard",
      title: "Hive Guard",
      tag: "Strategy",
      pitch:
        "Waves of beetles walk along a path to your hive. Place guard bees with your nectar. Each bee guards its post, chases the beetles that it sees, and stings them.",
      shows:
        "the rule follow along a path, pursue of a group, messages that change the state of another boid, and boids that the person starts while the world runs.",
      icon:
        ~S(<rect class="mark-warm" x="44" y="22" width="10" height="12" opacity="0.5"/><path class="mark-rock" d="M4 12 H20 V44 H36 V28 H44" fill="none" stroke-width="4" opacity="0.6"/><path class="mark-ink" d="M14 14 L6 17 L8 14 L6 11 Z"/><path class="mark-ink" d="M22 32 L14 35 L16 32 L14 29 Z"/><path class="mark-cool" d="M34 18 L24 22 L27 18 L24 14 Z"/><path class="mark-warm" d="M30 52 L18 56 L22 52 L18 48 Z"/>),
      order: 80
    }
  end

  @width 160
  @height 90

  # The path of the beetles: from the left side to the hive.
  @path [{0, 72}, {40, 72}, {40, 22}, {85, 22}, {85, 70}, {125, 70}, {125, 40}, {150, 40}]
  @hive {152, 40}

  @doc "The size of the field."
  def box, do: {@width, @height}

  @doc "The path of the beetles."
  def path, do: @path

  @doc "The center of the hive."
  def hive, do: @hive

  @doc """
  The kinds of guard bees: the cost in nectar, the distance that a bee
  sees (its range), its maximum speed, the health that a sting takes, the
  seconds of rest after a sting, and the distance from its post that it
  goes at most.
  """
  def guards do
    %{
      scout: %{cost: 25, range: 12, speed: 16, damage: 1, rest: 0.5, leash: 16},
      soldier: %{cost: 50, range: 20, speed: 9, damage: 3, rest: 1.4, leash: 24}
    }
  end

  @doc """
  The beetles of a wave: a list of `{kind, health}`, in the order that
  they come. The waves get larger, and from the wave 2 they have large
  beetles at the end.
  """
  def wave(n) when n >= 1 do
    small = min(4 + 2 * n, 24)
    large = if n >= 2, do: min(div(n, 2), 8), else: 0
    List.duplicate({:small, 2 + div(n - 1, 3)}, small) ++ List.duplicate({:large, 8 + 2 * n}, large)
  end

  @doc "The nectar that a killed beetle gives."
  def bounty(:small), do: 4
  def bounty(:large), do: 12

  @doc "The nectar at the end of a wave."
  def bonus(n), do: 15 + 5 * n

  # --- A beetle -----------------------------------------------------------------

  defmodule Beetle do
    @moduledoc """
    A beetle follows the path to the hive with its swarm. A sting of a bee
    takes its health. A beetle with no health, or at the hive, tells the
    director and stops.
    """
    @behaviour :gen_boid
    alias BoidsExamples.Games.HiveGuard

    @impl true
    def init(%{id: id, pos: pos, kind: kind, health: health, director: director}) do
      speed = if kind == :large, do: 5.0, else: 8.5

      {:ok,
       %{
         id: id,
         pos: pos,
         vel: {speed, 0.0},
         group: :beetles,
         perception: 6,
         max_speed: speed,
         min_speed: 1.0,
         max_force: 20,
         rules: [
           {:follow, 2.0, %{path: HiveGuard.path(), ahead: 4, predict: 0.5}},
           {:separation, 1.2, %{radius: 2, groups: [:beetles]}},
           {:alignment, 0.4, %{groups: [:beetles]}},
           {:cohesion, 0.2, %{groups: [:beetles]}}
         ],
         # The bees and the page see the kind and the health of a beetle.
         data: {kind, health},
         state: %{kind: kind, health: health, director: director}
       }}
    end

    # Act: a beetle at the hive takes one life of the hive, and stops.
    @impl true
    def handle_act(%{id: id, pos: pos, state: %{director: director}} = boid) do
      if :boids_vec.dist(pos, HiveGuard.hive()) <= 5 do
        GenServer.cast(director, {:hive, id})
        {:stop, :normal, boid}
      else
        {:ok, boid}
      end
    end

    # A sting of a bee: the beetle loses health, and stops at 0.
    @impl true
    def handle_cast(
          {:sting, damage},
          %{id: id, state: %{kind: kind, health: health, director: director} = state} = boid
        )
        when is_integer(damage) and damage > 0 do
      case health - damage do
        left when left <= 0 ->
          GenServer.cast(director, {:killed, id, kind})
          {:stop, :normal, boid}

        left ->
          {:noreply, %{boid | data: {kind, left}, state: %{state | health: left}}}
      end
    end
  end

  # --- A guard bee -------------------------------------------------------------------

  defmodule Guard do
    @moduledoc """
    A guard bee stays near its post. When it sees a beetle, and it does
    not rest, it pursues the beetle, and stings a beetle that it touches.
    After a sting, it rests, and goes back to its post. A bee does not go
    farther from its post than its leash.
    """
    @behaviour :gen_boid
    alias BoidsExamples.Games.HiveGuard

    @impl true
    def init(%{post: post, kind: kind}) do
      guard = HiveGuard.guards()[kind]

      {:ok,
       %{
         pos: post,
         group: :guards,
         perception: guard.range,
         max_speed: guard.speed,
         max_force: 40,
         rules: rules(:home, post),
         data: kind,
         state: %{kind: kind, post: post, rest: 0.0, mode: :home, stings: 0}
       }}
    end

    @doc "The rules of a bee at its post, and of a bee that hunts."
    def rules(:home, post) do
      # A bee at its post hovers: it wanders a little around the post.
      [
        {:arrive, 2.0, %{target: post, slow_radius: 6}},
        {:wander, 0.6, %{jitter: 3.0}},
        {:separation, 1.0, %{radius: 3, groups: [:guards]}}
      ]
    end

    def rules(:hunt, _post) do
      [
        {:pursue, 3.0, %{target: {:group, :beetles}, max_time: 0.5}},
        {:separation, 0.8, %{radius: 2.5, groups: [:guards]}}
      ]
    end

    # Decide: sting a beetle that the bee touches, then choose to hunt
    # or to go home.
    @impl true
    def handle_decide(%{neighbors: neighbors, lookup: lookup, dt: dt}, %{pos: pos, state: state} = boid) do
      guard = HiveGuard.guards()[state.kind]
      beetles = Enum.filter(neighbors, &(&1.group == :beetles))
      state = %{state | rest: max(state.rest - dt, 0.0)}

      state =
        case beetles do
          [%{id: id, dist: dist, data: {kind, _health}} | _] when state.rest == 0.0 ->
            if dist <= reach(kind), do: sting(lookup, id, guard, state), else: state

          _ ->
            state
        end

      far = :boids_vec.dist(pos, state.post) > guard.leash
      mode = if state.rest > 0 or far or beetles == [], do: :home, else: :hunt

      if mode == state.mode do
        {:ok, %{boid | state: state}}
      else
        {:ok, %{:boids_boid.update(boid, %{rules: rules(mode, state.post)}) | state: %{state | mode: mode}}}
      end
    end

    # The distance at which a bee touches a beetle.
    defp reach(:large), do: 2.6
    defp reach(_small), do: 1.8

    # The id of a boid is not its process: the bee finds the process of
    # the beetle with the function lookup of what it perceives, and sends
    # it a sting.
    defp sting(lookup, id, guard, state) do
      case lookup.(id) do
        {:ok, %{pid: pid}} when is_pid(pid) ->
          :gen_boid.cast(pid, {:sting, guard.damage})
          %{state | rest: guard.rest, stings: state.stings + 1}

        _ ->
          state
      end
    end
  end

  # --- The director ----------------------------------------------------------------------

  defmodule Director do
    @moduledoc """
    The process of the game: the waves and their beetles, the lives of
    the hive, the nectar, and the bees. A phase is `:building` (the next
    wave comes after the countdown), `:wave` (the beetles come), or
    `:over` (the hive has no life).
    """
    use GenServer
    alias BoidsExamples.Games.HiveGuard

    @max_guards 12

    def start_link(space, options), do: GenServer.start_link(__MODULE__, {space, options})
    def status(director), do: GenServer.call(director, :status)
    def input(director, message), do: GenServer.cast(director, {:input, message})

    @doc "The state of the game, for the tests."
    def state(director), do: GenServer.call(director, :state)

    @impl true
    def init({space, options}) do
      options =
        Map.merge(
          # The hive has one free scout at the start, near the first bend
          # of the path.
          %{lives: 10, nectar: 80, build: 8.0, every: 0.7, scale: 1.0, seed: nil, bees: [{:scout, {44.0, 66.0}}]},
          options
        )

      if options.seed, do: :rand.seed(:exsss, options.seed)
      # A test makes the game faster: the boids and the director use the
      # same scale of the time.
      :boids.set_time_scale(space, options.scale)
      :timer.send_interval(Scene.tick(), :step)
      {:ok, fresh(space, options) |> first_bees()}
    end

    defp fresh(space, options) do
      %{
        space: space,
        options: options,
        phase: :building,
        countdown: options.build,
        wave: 0,
        done: 0,
        lives: options.lives,
        nectar: options.nectar,
        queue: [],
        since: 0.0,
        alive: %{},
        guards: [],
        kills: 0,
        leaked: 0,
        last: now()
      }
    end

    @impl true
    def handle_call(:status, _from, state), do: {:reply, status_of(state), state}
    def handle_call(:state, _from, state), do: {:reply, state, state}

    @impl true
    def handle_cast({:killed, _id, kind}, state) do
      {:noreply, %{state | nectar: state.nectar + HiveGuard.bounty(kind), kills: state.kills + 1}}
    end

    def handle_cast({:hive, _id}, %{phase: :over} = state), do: {:noreply, state}

    def handle_cast({:hive, _id}, state) do
      state = %{state | lives: state.lives - 1, leaked: state.leaked + 1}
      {:noreply, if(state.lives <= 0, do: over(state), else: state)}
    end

    def handle_cast({:input, message}, state), do: {:noreply, change(message, state)}

    @impl true
    def handle_info(:step, state) do
      now = now()
      dt = (now - state.last) / 1000 * state.options.scale
      {:noreply, step(%{state | last: now}, dt)}
    end

    def handle_info({:DOWN, ref, :process, _pid, _reason}, state) do
      {:noreply, %{state | alive: Map.delete(state.alive, ref)}}
    end

    # --- The time of the game -------------------------------------------------------

    defp step(%{phase: :building} = state, dt) do
      countdown = state.countdown - dt
      if countdown <= 0, do: start_wave(state), else: %{state | countdown: countdown}
    end

    defp step(%{phase: :wave} = state, dt) do
      state = spawn_due(%{state | since: state.since + dt})

      if state.queue == [] and map_size(state.alive) == 0 do
        # The hive stopped the wave.
        %{
          state
          | phase: :building,
            countdown: state.options.build,
            done: state.wave,
            nectar: state.nectar + HiveGuard.bonus(state.wave)
        }
      else
        state
      end
    end

    defp step(state, _dt), do: state

    defp start_wave(state) do
      n = state.wave + 1
      %{state | phase: :wave, wave: n, queue: HiveGuard.wave(n), since: state.options.every, countdown: 0.0}
    end

    # The beetles of the queue come one at a time.
    defp spawn_due(%{queue: [{kind, health} | rest], since: since} = state) do
      if since >= state.options.every do
        spawn_due(%{state | queue: rest, since: since - state.options.every} |> beetle(kind, health))
      else
        state
      end
    end

    defp spawn_due(state), do: state

    defp beetle(state, kind, health) do
      {x0, y0} = hd(HiveGuard.path())
      id = make_ref()
      pos = {x0 + 1 + :rand.uniform() * 2, y0 + :rand.uniform() * 6 - 3}
      options = %{id: id, pos: pos, kind: kind, health: health, director: self()}
      {:ok, pid} = :gen_boid.start(state.space, HiveGuard.Beetle, options)
      %{state | alive: Map.put(state.alive, Process.monitor(pid), id)}
    end

    # The hive has no life: no more beetles. The beetles of the field go.
    defp over(state) do
      for %{id: id, group: :beetles} <- :boids.snapshot(state.space, :local), do: :boids.remove(state.space, id)
      %{state | phase: :over, queue: []}
    end

    # --- The person -----------------------------------------------------------------

    defp change(%{"place" => [x, y], "kind" => kind}, state)
         when is_number(x) and is_number(y) and kind in ["scout", "soldier"] do
      kind = String.to_existing_atom(kind)
      cost = HiveGuard.guards()[kind].cost
      {hx, hy} = HiveGuard.hive()

      cond do
        state.phase == :over -> state
        length(state.guards) >= @max_guards -> state
        state.nectar < cost -> state
        not inside?(x, y) -> state
        abs(x - hx) < 7 and abs(y - hy) < 9 -> state
        true -> place(state, kind, {x * 1.0, y * 1.0}, cost)
      end
    end

    defp change(%{"go" => true}, %{phase: :building} = state), do: start_wave(state)

    defp change(%{"go" => true}, %{phase: :over} = state) do
      for %{id: id} <- :boids.snapshot(state.space, :local), do: :boids.remove(state.space, id)
      for ref <- Map.keys(state.alive), do: Process.demonitor(ref, [:flush])
      fresh(state.space, state.options) |> first_bees()
    end

    defp change(_message, state), do: state

    # The free bees of the start of a game.
    defp first_bees(state) do
      Enum.reduce(state.options.bees, state, fn {kind, post}, acc -> place(acc, kind, post, 0) end)
    end

    defp inside?(x, y) do
      {width, height} = HiveGuard.box()
      x >= 0 and x <= width and y >= 0 and y <= height
    end

    defp place(state, kind, post, cost) do
      {:ok, _pid} = :gen_boid.start(state.space, HiveGuard.Guard, %{post: post, kind: kind})
      %{state | nectar: state.nectar - cost, guards: state.guards ++ [{kind, post}]}
    end

    # --- The readings ----------------------------------------------------------------

    defp status_of(state) do
      %{
        r: [
          ["Wave", state.wave],
          ["Hive", state.lives],
          ["Nectar", state.nectar],
          ["Beetles", map_size(state.alive) + length(state.queue)],
          ["Waves survived", state.done]
        ],
        h: %{zones: HiveGuard.zones(state.guards)},
        x: %{
          phase: state.phase,
          wave: state.wave,
          done: state.done,
          countdown: Float.round(state.countdown * 1.0, 1),
          nectar: state.nectar,
          guards: length(state.guards),
          max_guards: @max_guards,
          kills: state.kills
        }
      }
    end

    defp now, do: System.monotonic_time(:millisecond)
  end

  # --- The field ---------------------------------------------------------------------

  @doc """
  The zones of the field: the path (a band along each segment), the hive,
  and a small mark at the post of each bee.
  """
  def zones(guards \\ []) do
    path =
      @path
      |> Enum.zip(tl(@path))
      |> Enum.map(fn {{x1, y1}, {x2, y2}} ->
        [min(x1, x2) - 3, min(y1, y2) - 3, max(x1, x2) + 3, max(y1, y2) + 3, "fur"]
      end)

    {hx, hy} = @hive
    hive = [hx - 6, hy - 8, min(hx + 6, @width), hy + 8, "gold", "Hive"]
    posts = for {kind, {x, y}} <- guards, do: [x - 1.5, y - 1.5, x + 1.5, y + 1.5, color(kind)]
    path ++ [hive] ++ posts
  end

  defp color(:scout), do: "cool"
  defp color(:soldier), do: "warm"

  # --- The scene ---------------------------------------------------------------------

  # The argument is nil for a visitor. A test gives options of the
  # director: the lives, the nectar, the seconds before a wave, the
  # seconds between two beetles, the scale of the time, a seed, and the
  # free bees of the start.
  @impl BoidsExamples.Scene
  def start(options) do
    {:ok, world} =
      :boids.start_world(
        bounds: {{0, 0}, {@width, @height}},
        wrap: false,
        cell_size: 12,
        defaults: %{tick: Scene.tick()}
      )

    space = :boids.space(world)
    {:ok, director} = Director.start_link(space, options || %{})
    {:ok, %{space: space, director: director}}
  end

  @impl BoidsExamples.Scene
  def header(_scene), do: %{ground: "grass", zones: zones()}

  @impl BoidsExamples.Scene
  def kinds(_scene) do
    [
      %{name: "beetles", shape: "beetle", color: "ink", size: 1.3},
      %{name: "large beetles", shape: "beetle", color: "plum", size: 2.1, badge: true},
      %{name: "scouts", shape: "bee", color: "gold", size: 1.4},
      %{name: "soldiers", shape: "bee", color: "warm", size: 1.9}
    ]
  end

  @impl BoidsExamples.Scene
  def look(_scene, %{group: :beetles, vel: vel, data: {:large, health}}), do: {1, Scene.angle(vel), health}
  def look(_scene, %{group: :beetles, vel: vel}), do: {0, Scene.angle(vel), 0}
  def look(_scene, %{group: :guards, vel: vel, data: :soldier}), do: {3, Scene.angle(vel), 0}
  def look(_scene, %{vel: vel}), do: {2, Scene.angle(vel), 0}

  @impl BoidsExamples.Scene
  def more(%{director: director}, _number), do: Director.status(director)

  @impl BoidsExamples.Scene
  def input(%{director: director}, message) when is_map(message), do: Director.input(director, message)
  def input(_scene, _message), do: :ok
end
