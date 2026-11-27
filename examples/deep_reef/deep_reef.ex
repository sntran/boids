defmodule BoidsExamples.Games.DeepReef do
  @moduledoc """
  Deep Reef: the person is a predator fish in a reef with rocks, and
  schools of small fish swim around it. The predator catches a fish that
  it touches, but a fish in a school is hard to catch: the predator is
  confused by the fish near its target. A fish that is alone is easy to
  catch. So the good way is to split a school, and to catch the fish that
  stay alone.

  The example shows these parts of the library:

  - A behavior of the school that protects each fish, with no fish that
    knows it: the confusion of the predator comes only from the
    neighbors of its target. A fish only stays near its neighbors.
  - The rule `evade`: a fish that sees the predator moves away from
    where the predator will be.
  - `boids:flocks/2`: the director finds the schools of the reef each
    second. A school that lost many fish goes to another school.
  - A boid that a person controls: the force of the predator is a rule of
    its own, a function that reads the keys.

  The `Director` is the process of a hunt: the time, the fish that the
  predator caught, the misses, and the new schools that come.
  """
  @behaviour BoidsExamples.Scene
  use BoidsExamples.Game

  @impl BoidsExamples.Game
  def info do
    %{
      slug: "deep-reef",
      title: "Deep Reef",
      tag: "Keys",
      pitch:
        "Be the predator of a reef, and catch small fish for 90 seconds. A fish in a school is hard to catch, because its neighbors confuse you. Split a school, and catch the fish that stay alone.",
      shows:
        "a school that protects each fish with no fish that knows it: the confusion comes from the neighbors of the target. Also the rule evade, and the schools from flocks/2.",
      icon:
        ~S(<circle class="mark-rock" cx="44" cy="42" r="9"/><path class="mark-ink" d="M14 12 L6 15 L8 12 L6 9 Z"/><path class="mark-ink" d="M22 16 L14 19 L16 16 L14 13 Z"/><path class="mark-ink" d="M16 22 L8 25 L10 22 L8 19 Z"/><path class="mark-ink" d="M24 26 L16 29 L18 26 L16 23 Z"/><path class="mark-warm" d="M30 44 L12 52 L17 44 L12 36 Z"/>),
      order: 90
    }
  end

  @width 160
  @height 90

  # The rocks of the reef: {Id, {X, Y}, Radius}.
  @rocks [
    {:north, {48, 66}, 7},
    {:middle, {82, 42}, 6},
    {:east, {118, 64}, 8},
    {:south, {104, 18}, 6},
    {:west, {34, 24}, 5}
  ]

  # The distance at which the predator touches a fish, and the distance
  # of the fish near the target that confuse the predator.
  @touch 2.0
  @confuse 6.0

  @doc "The steps of a boid in a time in milliseconds."
  def steps(milliseconds), do: max(div(milliseconds, BoidsExamples.Scene.tick()), 1)

  @doc "The seconds of one step."
  def dt, do: BoidsExamples.Scene.tick() / 1000

  @doc "The rocks of the reef, as `{Id, {X, Y}, Radius}`."
  def rocks, do: @rocks

  @doc """
  The chance that the predator catches a fish that it touches, from the
  number of the other fish near that fish: sure with 0 or 1 fish near
  it, and 1 in 10 with 8 fish near it or more.
  """
  @spec chance(non_neg_integer()) :: float()
  def chance(near) when near <= 1, do: 1.0
  def chance(near) when near >= 8, do: 0.1
  def chance(near), do: 1.0 - 0.9 * (near - 1) / 7

  @doc """
  The fish that a predator at the place of its own touches, and the
  number of the other fish near that fish. `Neighbors` are the neighbors
  of the predator (with their offsets from it). The result is
  `{Fish, Near}`, or nil when the predator touches no fish.
  """
  def target(neighbors) do
    fish = for n <- neighbors, n.group == :fish, do: n

    case Enum.filter(fish, &(&1.dist <= @touch)) do
      [] ->
        nil

      touched ->
        target = Enum.min_by(touched, & &1.dist)

        near =
          Enum.count(fish, fn other ->
            other.id != target.id and :boids_vec.dist(other.offset, target.offset) <= @confuse
          end)

        {target, near}
    end
  end

  defmodule Fish do
    @moduledoc """
    A small fish. It stays with its school (separation, alignment and
    cohesion), moves around the rocks, stays in the reef, and evades the
    predator that it sees. A fish that the predator catches stops. The
    director can send a fish of a small school to another school.
    """
    @behaviour :gen_boid
    alias BoidsExamples.Games.DeepReef, as: Reef

    @doc "The rules of a fish."
    def rules do
      [
        {:avoid, 4.0, %{lookahead: 1.2}},
        {:contain, 3.0, %{margin: 6}},
        {:evade, 3.2, %{target: {:group, :predator}, radius: 12}},
        {:separation, 1.6, %{radius: 2.6}},
        {:alignment, 1.0},
        {:cohesion, 1.5},
        {:wander, 0.25}
      ]
    end

    @impl true
    def init(%{pos: pos, vel: vel}) do
      {:ok,
       %{
         pos: pos,
         vel: vel,
         group: :fish,
         perception: 10,
         min_speed: 3,
         max_speed: 10.5,
         max_force: 30,
         rules: rules(),
         state: %{join: 0}
       }}
    end

    # The time to go to another school ends.
    @impl true
    def handle_decide(_seen, %{state: %{join: 1}} = boid) do
      {:ok, %{:boids_boid.update(boid, %{rules: rules()}) | state: %{join: 0}}}
    end

    def handle_decide(_seen, %{state: %{join: join}} = boid) when join > 1 do
      {:ok, %{boid | state: %{join: join - 1}}}
    end

    def handle_decide(_seen, boid), do: {:ok, boid}

    # The predator caught the fish.
    @impl true
    def handle_cast(:eaten, boid), do: {:stop, :normal, boid}

    # The director sends the fish of a small school to another school.
    def handle_cast({:join, {x, y}}, boid) when is_number(x) and is_number(y) do
      rules = [{:seek, 1.6, %{target: {x * 1.0, y * 1.0}}} | rules()]
      {:noreply, %{:boids_boid.update(boid, %{rules: rules}) | state: %{join: Reef.steps(3000)}}}
    end
  end

  defmodule Predator do
    @moduledoc """
    The predator. The person moves it with the keys: `left`, `right`,
    `up`, `down`, and `burst` (fast, while it has stamina). It catches a
    fish that it touches, with the chance of `BoidsExamples.Games.DeepReef.chance/1`.
    After a try, it waits 0.6 second before the next try. Its data shows
    its direction, its stamina and if it bursts.
    """
    @behaviour :gen_boid
    alias BoidsExamples.Games.DeepReef, as: Reef

    @swim 7.5
    @burst 14.0

    @impl true
    def init(%{pos: pos, director: director} = options) do
      state = %{
        keys: %{},
        director: director,
        stopped: false,
        stamina: 100.0,
        wait: 0,
        heading: 0.0,
        # A test can give the roll of the dice: a number from 0 to 1.
        roll: Map.get(options, :roll)
      }

      {:ok,
       %{
         pos: pos,
         group: :predator,
         perception: 8,
         max_speed: @burst,
         max_force: 80,
         rules: [{&Predator.fins/3, 1.0}],
         data: %{heading: 0.0, stamina: 100.0, burst: false},
         state: state
       }}
    end

    @doc """
    The force of the predator: to the velocity that the keys ask for. With
    no key, the predator slows down. After the end of the hunt, it stops.
    """
    def fins(%{vel: vel, state: state}, _neighbors, _seen) do
      direction =
        if state.stopped do
          {0.0, 0.0}
        else
          keys = state.keys
          x = if(keys[:right], do: 1.0, else: 0.0) - if(keys[:left], do: 1.0, else: 0.0)
          y = if(keys[:up], do: 1.0, else: 0.0) - if(keys[:down], do: 1.0, else: 0.0)
          :boids_vec.normalize({x, y})
        end

      :boids_vec.scale(:boids_vec.sub(:boids_vec.scale(direction, speed(state)), vel), 4.0)
    end

    @doc "The speed that the predator wants: fast while it bursts."
    def speed(%{keys: keys, stamina: stamina}) do
      if keys[:burst] && stamina > 0, do: @burst, else: @swim
    end

    # Decide: a try to catch the fish that the predator touches.
    @impl true
    def handle_decide(_seen, %{state: %{stopped: true}} = boid), do: {:ok, boid}

    def handle_decide(_seen, %{state: %{wait: wait} = state} = boid) when wait > 0 do
      {:ok, %{boid | state: %{state | wait: wait - 1}}}
    end

    def handle_decide(%{neighbors: neighbors, lookup: lookup}, %{state: state} = boid) do
      case Reef.target(neighbors) do
        nil ->
          {:ok, boid}

        {fish, near} ->
          roll = state.roll || :rand.uniform()

          if roll <= Reef.chance(near) do
            with {:ok, %{pid: pid}} <- lookup.(fish.id), do: :gen_boid.cast(pid, :eaten)
            GenServer.cast(state.director, :caught)
          else
            GenServer.cast(state.director, :missed)
          end

          {:ok, %{boid | state: %{state | wait: Reef.steps(600)}}}
      end
    end

    # Act: the predator stays in the reef and out of the rocks, uses or
    # gets stamina, and shows its direction and its stamina.
    @impl true
    def handle_act(%{pos: pos, vel: vel, state: state} = boid) do
      pos = out_of_rocks(in_reef(pos))
      bursts = state.keys[:burst] == true and state.stamina > 0 and not state.stopped and :boids_vec.norm(vel) > 1.0

      stamina =
        if bursts, do: max(state.stamina - 45 * Reef.dt(), 0.0), else: min(state.stamina + 15 * Reef.dt(), 100.0)

      heading = if :boids_vec.norm(vel) > 0.5, do: :math.atan2(elem(vel, 1), elem(vel, 0)), else: state.heading
      state = %{state | stamina: stamina, heading: heading}
      {:ok, %{boid | pos: pos, state: state, data: %{heading: heading, stamina: stamina, burst: bursts}}}
    end

    @impl true
    def handle_cast({:keys, keys}, %{state: state} = boid), do: {:noreply, %{boid | state: %{state | keys: keys}}}
    def handle_cast(:stop, %{state: state} = boid), do: {:noreply, %{boid | state: %{state | stopped: true, keys: %{}}}}

    defp in_reef({x, y}), do: {min(max(x, 1.0), 159.0), min(max(y, 1.0), 89.0)}

    # A predator in a rock goes to the edge of the rock.
    defp out_of_rocks(pos) do
      Enum.reduce(Reef.rocks(), pos, fn {_id, center, radius}, at ->
        offset = :boids_vec.sub(at, center)
        dist = :boids_vec.norm(offset)

        cond do
          dist >= radius + 1.0 -> at
          dist == 0 -> :boids_vec.add(center, {radius + 1.0, 0.0})
          true -> :boids_vec.add(center, :boids_vec.scale(offset, (radius + 1.0) / dist))
        end
      end)
    end
  end

  defmodule Director do
    @moduledoc """
    The process of a hunt: the state (`hunting` or `over`), the time, the
    fish that the predator caught, and its misses. Each second it finds
    the schools with `boids:flocks/2`: a school of 3 fish or fewer goes to
    the nearest larger school. Each 8 seconds, a new school of 5 fish
    comes in at a side of the reef, while the reef has fewer than 40
    fish.
    """
    use GenServer
    alias BoidsExamples.Games.DeepReef, as: Reef
    alias BoidsExamples.Games.DeepReef.{Fish, Predator}

    @seconds 90

    def start_link(space, options), do: GenServer.start_link(__MODULE__, {space, options})
    def status(director), do: GenServer.call(director, :status)
    def input(director, message), do: GenServer.cast(director, {:input, message})

    @doc "The schools of the reef: lists of the ids of the fish that see each other."
    def schools(space) do
      fish = MapSet.new(for %{id: id, group: :fish} <- :boids.snapshot(space, :local), do: id)

      for flock <- :boids.flocks(space, 10, :local),
          school = Enum.filter(flock, &MapSet.member?(fish, &1)),
          school != [],
          do: school
    end

    # --- GenServer -------------------------------------------------------

    @impl true
    def init({space, options}) do
      state = %{
        space: space,
        options: options,
        state: :hunting,
        predator: nil,
        caught: 0,
        misses: 0,
        best: 0,
        start: now(),
        time: 0,
        schools: 0,
        alone: 0,
        seconds: 0,
        stamina: 100.0,
        burst: false
      }

      # The director stops with the world.
      Process.monitor(space.owner)
      send(self(), :check)
      send(self(), :second)
      {:ok, hunt(state)}
    end

    @impl true
    def handle_call(:status, _from, state), do: {:reply, report(state), state}

    @impl true
    def handle_cast(:caught, %{state: :hunting} = state), do: {:noreply, %{state | caught: state.caught + 1}}
    def handle_cast(:missed, %{state: :hunting} = state), do: {:noreply, %{state | misses: state.misses + 1}}

    def handle_cast({:input, %{"keys" => names}}, %{state: :hunting, predator: predator} = state)
        when is_list(names) do
      keys =
        for name <- names, name in ["left", "right", "up", "down", "burst"], into: %{} do
          {String.to_existing_atom(name), true}
        end

      :gen_boid.cast(predator, {:keys, keys})
      {:noreply, state}
    end

    # A new hunt after the end of a hunt.
    def handle_cast({:input, %{"go" => true}}, %{state: :over} = state), do: {:noreply, hunt(state)}
    def handle_cast(_message, state), do: {:noreply, state}

    @impl true
    def handle_info({:DOWN, _ref, :process, _pid, _reason}, state), do: {:stop, :normal, state}

    def handle_info(:check, state) do
      Process.send_after(self(), :check, BoidsExamples.Scene.tick())
      {:noreply, check(state)}
    end

    def handle_info(:second, state) do
      Process.send_after(self(), :second, 1000)
      {:noreply, second(state)}
    end

    # At each tick: the stamina of the predator, and the end of the time.
    defp check(%{state: :hunting, space: space} = state) do
      state =
        case Enum.find(:boids.snapshot(space, :local), &(&1.group == :predator)) do
          %{data: %{stamina: stamina, burst: burst}} -> %{state | stamina: stamina, burst: burst}
          _ -> state
        end

      if now() - state.start >= duration(state) do
        :gen_boid.cast(state.predator, :stop)
        %{state | state: :over, time: duration(state), best: max(state.best, state.caught), burst: false}
      else
        state
      end
    end

    defp check(state), do: state

    # Each second: the schools, the small schools that join a larger
    # school, and a new school.
    defp second(%{state: :hunting, space: space, options: options} = state) do
      state = %{state | seconds: state.seconds + 1}
      schools = schools(space)
      rows = Map.new(:boids.snapshot(space, :local), &{&1.id, &1})
      {small, large} = Enum.split_with(schools, &(length(&1) <= 3))

      if large != [] do
        centers = for school <- large, do: center(school, rows)

        for school <- small, center = center(school, rows), center != nil do
          target = Enum.min_by(centers, &:boids_vec.dist(&1, center))

          for id <- school,
              do: with(pid when is_pid(pid) <- :boids.whereis(space, id), do: :gen_boid.cast(pid, {:join, target}))
        end
      end

      every = Map.get(options, :every, 8)
      fish = Enum.sum(Enum.map(schools, &length/1))

      if every > 0 and rem(state.seconds, every) == 0 and fish < 40 do
        side = Enum.random([:west, :east])
        school(space, edge(side), 5)
      end

      %{state | schools: Enum.count(schools, &(length(&1) >= 2)), alone: Enum.count(schools, &(length(&1) == 1))}
    end

    defp second(state), do: state

    defp center(ids, rows) do
      points = for id <- ids, %{pos: pos} <- [rows[id]], do: pos

      case points do
        [] -> nil
        _ -> :boids_vec.scale(Enum.reduce(points, {0.0, 0.0}, &:boids_vec.add/2), 1 / length(points))
      end
    end

    defp duration(%{options: options}), do: Map.get(options, :seconds, @seconds) * 1000

    defp report(state) do
      left = if state.state == :hunting, do: max(duration(state) - (now() - state.start), 0), else: 0
      seconds = div(left + 999, 1000)

      %{
        r: [
          ["Time", "#{seconds} s"],
          ["Caught", state.caught],
          ["Misses", state.misses],
          ["Schools", state.schools],
          ["Alone", state.alone],
          ["Stamina", "#{round(state.stamina)} %"]
        ],
        x: %{
          state: state.state,
          time: seconds,
          caught: state.caught,
          misses: state.misses,
          best: state.best,
          stamina: round(state.stamina),
          thrust: state.burst,
          safe: false
        }
      }
    end

    # Start a hunt: clear the world, then the schools and the predator.
    defp hunt(%{space: space, options: options} = state) do
      for %{id: id} <- :boids.snapshot(space, :local), do: :boids.remove(space, id)

      for {center, count} <-
            Map.get(options, :schools, [{{20, 45}, 10}, {{64, 14}, 10}, {{132, 34}, 10}, {{80, 78}, 10}]) do
        school(space, center, count)
      end

      at = Map.get(options, :predator, {150.0, 82.0})
      predator_options = Map.merge(%{pos: at, director: self()}, Map.take(options, [:roll]))
      {:ok, predator} = :gen_boid.start(space, Predator, predator_options)

      %{state | state: :hunting, predator: predator, caught: 0, misses: 0, start: now(), time: 0, seconds: 0}
      |> Map.merge(%{stamina: 100.0, burst: false})
    end

    # A school of fish around a point, which swim in one direction.
    defp school(space, {x, y}, count) do
      direction = :boids_vec.random_unit(2)

      for i <- 1..count//1 do
        # The fish of a school start in a small circle.
        angle = i * 2.4
        radius = 0.8 * :math.sqrt(i)
        pos = {x + radius * :math.cos(angle), y + radius * :math.sin(angle)}
        vel = :boids_vec.scale(direction, 5.0)
        {:ok, _} = :gen_boid.start(space, Fish, %{pos: pos, vel: vel})
      end
    end

    defp edge(:west), do: {6.0, 15 + :rand.uniform() * 60}
    defp edge(:east), do: {154.0, 15 + :rand.uniform() * 60}

    defp now, do: System.monotonic_time(:millisecond)
  end

  # --- The scene ---------------------------------------------------------

  # The argument is nil for a visitor. A test gives options of the
  # director: the schools (a list of {Center, Count}), the place of the
  # predator, the seconds of a hunt, the seconds between new schools
  # (`every`, 0 for none), and the roll of the dice of the predator.
  @impl true
  def start(options) do
    {:ok, world} =
      :boids.start_world(
        bounds: {{0, 0}, {@width, @height}},
        wrap: false,
        cell_size: 10,
        defaults: %{tick: BoidsExamples.Scene.tick()}
      )

    for {id, pos, radius} <- @rocks, do: :ok = :boids.set_obstacle(world, id, pos, radius)
    space = :boids.space(world)
    {:ok, director} = Director.start_link(space, options || %{})
    {:ok, %{space: space, director: director}}
  end

  @impl true
  def kinds(_scene) do
    [
      %{name: "fish", shape: "fish", color: "gold", size: 1.0},
      %{name: "predator", shape: "shark", color: "rock", size: 2.8}
    ]
  end

  @impl true
  def header(_scene), do: %{ground: "water"}

  @impl true
  def look(_scene, %{group: :predator, data: %{heading: heading}}), do: {1, heading, 0}
  def look(_scene, %{vel: vel}), do: {0, BoidsExamples.Scene.angle(vel), 0}

  @impl true
  def more(%{director: director}, _number), do: Director.status(director)

  @impl true
  def input(%{director: director}, message), do: Director.input(director, message)
end
