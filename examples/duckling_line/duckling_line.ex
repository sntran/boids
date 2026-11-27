defmodule BoidsExamples.Games.DucklingLine do
  @moduledoc """
  Duckling Line: a calm game for all ages. The person is a mother duck on
  a pond. Lost ducklings paddle alone. A lost duckling that sees the
  mother, or a duckling of her line, joins the end of the line. The
  person leads the line to the nest. A duckling that comes into the nest
  in a line is safe.

  The line is a chain of relations of the library:

  - A duckling of the line has the relation `follows` to the boid before
    it (`boids:relate/4`), and the rule `leader` with the target
    `{related, follows}`. It does not know the line: it only follows its
    leader.
  - A duckling that is too far from its leader for 2 seconds leaves the
    line (`boids:unrelate/4`): the mother swam too fast, or a pike scared
    it. The ducklings behind it still follow it: they are a short line
    that waits for the mother.
  - A duckling knows if it is in the line of the mother: it goes up its
    chain of leaders, with the reads of the world, and asks no process.

  The `Director` is the process of a try: the pond, the time, the counts,
  and the joins. A join goes through the director, so that two ducklings
  that join at the same moment get two places in the line.
  """
  @behaviour BoidsExamples.Scene
  use BoidsExamples.Game

  @impl BoidsExamples.Game
  def info do
    %{
      slug: "duckling-line",
      title: "Duckling Line",
      tag: "Keys",
      pitch:
        "Swim as a mother duck, and collect the lost ducklings into a line behind you. Lead the line around the rocks and the pikes to the nest. Do not go too fast, or the line breaks.",
      shows:
        "relations that the boids make and remove while the game runs, a chain of leaders, and the rule leader with the target {related, follows}.",
      icon:
        ~S(<circle class="mark-rock" cx="12" cy="44" r="5"/><path class="mark-warm" d="M48 18 L38 23 L40 18 L38 13 Z"/><circle class="mark-ink" cx="32" cy="22" r="3.5"/><circle class="mark-ink" cx="24" cy="28" r="3.5"/><circle class="mark-ink" cx="17" cy="35" r="3.5"/><path d="M45 18 L32 22 L24 28 L17 35" stroke="currentColor" stroke-width="1" fill="none" opacity="0.4"/>),
      order: 100
    }
  end

  @width 160
  @height 90

  # The id of the mother: each try has a world of its own.
  @mother :mother

  # A duckling joins the line when it sees a boid of the line this near.
  @join 4.5
  # A duckling of the line that is this far from its leader for 2
  # seconds leaves the line.
  @far 12.0
  # A duckling flees from a pike that is this near.
  @scare 9.0

  @doc "The id of the mother duck."
  def mother, do: @mother

  @doc "The distance at which a duckling joins the line."
  def join_distance, do: @join

  @doc "The distance from its leader at which a duckling of the line begins to lose it."
  def far_distance, do: @far

  @doc "The steps of a boid in a time in milliseconds."
  def steps(milliseconds), do: max(div(milliseconds, BoidsExamples.Scene.tick()), 1)

  @doc "True when the point is in the box `{X0, Y0, X1, Y1}`."
  def inside?({x, y}, {x0, y0, x1, y1}), do: x >= x0 and x <= x1 and y >= y0 and y <= y1

  @doc """
  True when a chain of leaders goes from `leader` to the mother, or to a
  duckling that is safe in the nest. The reads are those of the world:
  `lookup` and `related` of what a boid perceives.
  """
  def in_line?(leader, lookup, related), do: in_line?(leader, lookup, related, 30)

  defp in_line?(nil, _lookup, _related, _depth), do: false
  defp in_line?(@mother, _lookup, _related, _depth), do: true
  defp in_line?(_id, _lookup, _related, 0), do: false

  defp in_line?(id, lookup, related, depth) do
    case lookup.(id) do
      {:ok, %{data: %{safe: true}}} ->
        true

      {:ok, _row} ->
        case related.(id, :follows) do
          [next | _] -> in_line?(next, lookup, related, depth - 1)
          [] -> false
        end

      :error ->
        false
    end
  end

  defmodule Mother do
    @moduledoc """
    The mother duck. The person moves her with the keys: `left`, `right`,
    `up`, `down`, and `hurry` (fast, but the ducklings cannot follow).
    Her force is a rule of her own: a function that reads the keys.
    """
    @behaviour :gen_boid

    @swim 6.0
    @hurry 12.0

    @impl true
    def init(pos) do
      {:ok,
       %{
         id: BoidsExamples.Games.DucklingLine.mother(),
         pos: pos,
         group: :mother,
         perception: 8,
         max_speed: @hurry,
         max_force: 60,
         rules: [{:avoid, 2.0, %{lookahead: 0.6}}, {&Mother.paddle/3, 1.0}],
         state: %{keys: %{}}
       }}
    end

    @doc "The force of the mother: to the velocity that the keys ask for. With no key, she stops."
    def paddle(%{vel: vel, state: %{keys: keys}}, _neighbors, _seen) do
      x = if(keys[:right], do: 1.0, else: 0.0) - if(keys[:left], do: 1.0, else: 0.0)
      y = if(keys[:up], do: 1.0, else: 0.0) - if(keys[:down], do: 1.0, else: 0.0)
      speed = if keys[:hurry], do: @hurry, else: @swim
      :boids_vec.scale(:boids_vec.sub(:boids_vec.scale(:boids_vec.normalize({x, y}), speed), vel), 4.0)
    end

    # The mother stays on the pond.
    @impl true
    def handle_act(%{pos: {x, y}} = boid), do: {:ok, %{boid | pos: {min(max(x, 1.0), 159.0), min(max(y, 1.0), 89.0)}}}

    @impl true
    def handle_cast({:keys, keys}, %{state: state} = boid), do: {:noreply, %{boid | state: %{state | keys: keys}}}
  end

  defmodule Duckling do
    @moduledoc """
    A duckling. Its look is one of:

    - `lost`: it paddles alone and slowly, and waits;
    - `line`: it has a leader (the relation `follows`), and follows it;
    - `safe`: it came into the nest in a line, and stays there.

    At each step it decides from what it perceives:

    - With no leader, it asks the director to join the line when it sees
      the mother, or a duckling of her line, near it.
    - With a leader, it counts the steps that it is too far from the
      leader. After 2 seconds, it leaves the line: `boids:unrelate/4`.
    - A pike near it scares it: it flees fast for a short time.
    - A duckling with a leader that comes into the nest is safe. It leaves
      its leader, and the ducklings behind it follow it into the nest.

    Its data shows its neighbors if it is in the line of the mother, and
    if it is safe.
    """
    @behaviour :gen_boid
    alias BoidsExamples.Games.DucklingLine, as: Line

    @pond {{2, 2}, {158, 88}}

    @impl true
    def init(%{id: id, pos: pos, space: space, director: director, nest: nest}) do
      state = %{space: space, director: director, nest: nest, look: {:lost, false}, far: 0, scared: 0, asked: 0}

      {:ok,
       %{id: id, pos: pos, vel: :boids_vec.scale(:boids_vec.random_unit(2), 1.0), group: :ducklings, perception: 12}
       |> Map.merge(%{data: %{line: false, safe: false}, state: state})
       |> Map.merge(rules({:lost, false}, nest))}
    end

    @doc "The rules and the speed of a duckling for a look, and if a pike scares it."
    def rules({:safe, _scared}, {x0, y0, x1, y1}) do
      %{
        max_speed: 1.5,
        rules: [
          {:contain, 3.0, %{bounds: {{x0, y0}, {x1, y1}}, margin: 1.5}},
          {:separation, 1.2, %{radius: 2}},
          {:wander, 0.4}
        ]
      }
    end

    def rules({:lost, scared}, _nest) do
      %{
        max_speed: if(scared, do: 9, else: 2.5),
        rules: [
          {:avoid, 3.0, %{lookahead: 1.0}},
          {:contain, 2.0, %{bounds: @pond, margin: 5}},
          {:flee, if(scared, do: 4.0, else: 0.0), %{target: {:group, :pikes}, radius: 12}},
          {:separation, 1.2, %{radius: 2}},
          {:wander, 0.6}
        ]
      }
    end

    def rules({:line, scared}, _nest) do
      %{
        max_speed: if(scared, do: 10, else: 8),
        rules: [
          {:avoid, 3.0, %{lookahead: 0.8}},
          {:contain, 2.0, %{bounds: @pond, margin: 4}},
          {:flee, if(scared, do: 4.0, else: 0.0), %{target: {:group, :pikes}, radius: 12}},
          {:leader, 2.0, %{target: {:related, :follows}, distance: 2.8, slow_radius: 5}},
          {:separation, 1.0, %{radius: 2.0}}
        ]
      }
    end

    @impl true
    def handle_decide(_seen, %{state: %{look: {:safe, _}}} = boid), do: {:ok, boid}

    def handle_decide(%{neighbors: neighbors, lookup: lookup, related: related}, %{id: id, state: state} = boid) do
      leader =
        case related.(id, :follows) do
          [leader | _] -> leader
          [] -> nil
        end

      pike = Enum.any?(neighbors, &(&1.group == :pikes and &1.dist <= Line.scare_distance()))
      scared = if pike, do: Line.steps(1500), else: max(state.scared - 1, 0)
      state = %{state | scared: scared, asked: max(state.asked - 1, 0)}

      cond do
        # Into the nest in a line: safe.
        leader != nil and Line.inside?(boid.pos, state.nest) ->
          :boids.unrelate(state.space, id, :follows, leader)
          GenServer.cast(state.director, {:safe, id})
          {:ok, look(%{boid | state: state}, {:safe, false}, false, true)}

        leader != nil ->
          {:ok, follow(boid, state, leader, lookup, related)}

        true ->
          {:ok, wait(boid, state, neighbors)}
      end
    end

    # A duckling with a leader: it follows it, and leaves it when it is
    # too far for 2 seconds.
    defp follow(%{id: id} = boid, state, leader, lookup, related) do
      line = Line.in_line?(leader, lookup, related)

      far =
        case lookup.(leader) do
          {:ok, %{pos: at}} -> if :boids_vec.dist(boid.pos, at) > Line.far_distance(), do: state.far + 1, else: 0
          :error -> Line.steps(2000)
        end

      if far >= Line.steps(2000) do
        :boids.unrelate(state.space, id, :follows, leader)
        GenServer.cast(state.director, {:break, id, line})
        look(%{boid | state: %{state | far: 0}}, {:lost, state.scared > 0}, false, false)
      else
        look(%{boid | state: %{state | far: far}}, {:line, state.scared > 0}, line, false)
      end
    end

    # A duckling with no leader: it waits, and asks the director to join
    # the line when it sees the mother, or a duckling of her line, near.
    defp wait(%{id: id} = boid, state, neighbors) do
      sees =
        Enum.any?(neighbors, fn n ->
          n.dist <= Line.join_distance() and (n.group == :mother or match?(%{line: true, safe: false}, n.data))
        end)

      state =
        if sees and state.asked == 0 do
          GenServer.cast(state.director, {:join, id})
          %{state | asked: Line.steps(500)}
        else
          state
        end

      look(%{boid | state: state}, {:lost, state.scared > 0}, false, false)
    end

    # A change of the look changes the rules. The data shows the line.
    defp look(%{state: %{look: look} = state} = boid, look, line, safe) do
      %{boid | state: state, data: %{line: line, safe: safe}}
    end

    defp look(%{state: state} = boid, look, line, safe) do
      boid = :boids_boid.update(boid, rules(look, state.nest))
      %{boid | state: %{state | look: look}, data: %{line: line, safe: safe}}
    end
  end

  @doc "The distance at which a pike scares a duckling."
  def scare_distance, do: @scare

  defmodule Pike do
    @moduledoc "A pike swims slowly under the water. It does not eat a duckling, but it scares it."
    @behaviour :gen_boid

    @impl true
    def init(%{id: id, pos: pos}) do
      {:ok,
       %{
         id: id,
         pos: pos,
         vel: :boids_vec.scale(:boids_vec.random_unit(2), 2.0),
         group: :pikes,
         perception: 10,
         max_speed: 3.0,
         min_speed: 1.0,
         rules: [
           {:avoid, 3.0, %{lookahead: 1.5}},
           {:contain, 2.0, %{bounds: {{24, 8}, {136, 82}}, margin: 8}},
           {:separation, 1.0, %{radius: 12}},
           {:wander, 1.0}
         ]
       }}
    end
  end

  defmodule Director do
    @moduledoc """
    The process of a try: the pond, the state (`swimming` or `done`), the
    time, the counts, and the joins of the ducklings.

    A duckling asks to join; the director gives it the relation `follows`
    to the last boid of the line of the mother. The joins come one at a
    time to this process, so two ducklings never get the same place.
    """
    use GenServer
    alias BoidsExamples.Games.DucklingLine, as: Line

    # The names of the keys from the page. A name that is not here is
    # not a key: the director makes no atom from the input.
    @keys %{"left" => :left, "right" => :right, "up" => :up, "down" => :down, "hurry" => :hurry}

    @doc """
    The ponds of the game. A rock and a bed of reeds are `{X, Y, Radius}`:
    obstacles of the world. The nest is `{X0, Y0, X1, Y1}`. A try in
    `par` seconds or less gets a star.
    """
    def ponds do
      [
        %{
          name: "Quiet corner",
          ducklings: 5,
          pikes: 0,
          mother: {12.0, 45.0},
          nest: {138, 32, 156, 58},
          rocks: [{62, 62, 5}, {96, 24, 6}],
          reeds: [{40, 20, 6}, {112, 70, 7}],
          par: 60
        },
        %{
          name: "Reed maze",
          ducklings: 7,
          pikes: 1,
          mother: {12.0, 20.0},
          nest: {138, 62, 156, 86},
          rocks: [{54, 40, 6}, {88, 66, 5}, {118, 30, 5}],
          reeds: [{36, 66, 7}, {72, 18, 7}, {100, 46, 6}, {130, 50, 5}],
          par: 80
        },
        %{
          name: "Pike water",
          ducklings: 9,
          pikes: 2,
          mother: {80.0, 8.0},
          nest: {70, 72, 90, 88},
          rocks: [{40, 30, 6}, {120, 30, 6}, {80, 46, 5}],
          reeds: [{24, 62, 7}, {136, 62, 7}, {60, 70, 5}, {100, 70, 5}],
          par: 100
        },
        %{
          name: "Long way home",
          ducklings: 11,
          pikes: 3,
          mother: {148.0, 45.0},
          nest: {4, 34, 22, 56},
          rocks: [{120, 20, 6}, {112, 68, 6}, {72, 45, 7}, {38, 22, 5}, {38, 70, 5}],
          reeds: [{92, 30, 6}, {92, 62, 6}, {56, 12, 6}, {56, 80, 6}],
          par: 120
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
        number: 0,
        pond: nil,
        state: :swimming,
        mother: nil,
        total: 0,
        safe: 0,
        breaks: 0,
        joins: 0,
        start: now(),
        time: 0
      }

      # The director stops with the world.
      Process.monitor(space.owner)
      {:ok, pond(state, Map.get(options, :pond, 1))}
    end

    @impl true
    def handle_call(:status, _from, state) do
      time = if state.state == :swimming, do: now() - state.start, else: state.time
      seconds = div(time, 1000)
      rows = :boids.snapshot(state.space, :local)
      line = Enum.count(rows, &match?(%{group: :ducklings, data: %{line: true, safe: false}}, &1))
      lost = max(state.total - state.safe - line, 0)
      stars = stars(state)

      status = %{
        r: [
          ["Pond", state.number],
          ["In the line", line],
          ["Safe", "#{state.safe} of #{state.total}"],
          ["Lost", lost],
          ["Breaks", state.breaks],
          ["Time", "#{seconds} s"]
        ],
        h: header(state.pond),
        x: %{
          state: state.state,
          pond: state.number,
          ponds: length(ponds()),
          name: state.pond.name,
          time: seconds,
          par: state.pond.par,
          safe: state.safe,
          total: state.total,
          line: line,
          lost: lost,
          breaks: state.breaks,
          stars: stars,
          reeds: for({x, y, r} <- state.pond.reeds, do: [x, y, r])
        }
      }

      {:reply, status, state}
    end

    @impl true
    def handle_cast({:join, id}, %{state: :swimming} = state), do: {:noreply, join(state, id)}

    def handle_cast({:break, _id, line}, %{state: :swimming} = state) do
      {:noreply, %{state | breaks: state.breaks + if(line, do: 1, else: 0)}}
    end

    def handle_cast({:safe, _id}, %{state: :swimming} = state) do
      state = %{state | safe: state.safe + 1}

      if state.safe >= state.total do
        {:noreply, %{state | state: :done, time: now() - state.start}}
      else
        {:noreply, state}
      end
    end

    def handle_cast({:input, %{"keys" => names}}, %{state: :swimming, mother: mother} = state) when is_list(names) do
      keys = for name <- names, Map.has_key?(@keys, name), into: %{}, do: {Map.fetch!(@keys, name), true}

      :gen_boid.cast(mother, {:keys, keys})
      {:noreply, state}
    end

    # The next pond after the nest, or the same pond again.
    def handle_cast({:input, %{"go" => true}}, %{state: :done} = state) do
      next = if state.number >= length(ponds()), do: 1, else: state.number + 1
      {:noreply, pond(state, next)}
    end

    def handle_cast({:input, %{"again" => true}}, state), do: {:noreply, pond(state, state.number)}
    def handle_cast(_message, state), do: {:noreply, state}

    @impl true
    def handle_info({:DOWN, _ref, :process, _pid, _reason}, state), do: {:stop, :normal, state}

    # A duckling with no leader joins the end of the line of the mother:
    # the last boid of the chain of followers from the mother. The world
    # refuses a relation that makes a cycle.
    defp join(%{space: space} = state, id) do
      with [] <- :boids.related(space, id, :follows),
           {:ok, %{data: %{safe: false}}} <- :boids.lookup(space, id),
           tail when tail != id <- tail(space, Line.mother(), 30),
           :ok <- :boids.relate(space, id, :follows, tail) do
        %{state | joins: state.joins + 1}
      else
        _ -> state
      end
    end

    defp tail(_space, id, 0), do: id

    defp tail(space, id, depth) do
      case :boids.related_to(space, id, :follows) do
        [next | _] -> tail(space, next, depth - 1)
        [] -> id
      end
    end

    defp stars(%{state: :done} = state) do
      1 + if(div(state.time, 1000) <= state.pond.par, do: 1, else: 0) + if(state.breaks == 0, do: 1, else: 0)
    end

    defp stars(_state), do: 0

    # Start a pond: clear the world, then the obstacles, the mother, the
    # ducklings and the pikes.
    defp pond(%{space: space, options: options} = state, number) do
      for %{id: id} <- :boids.snapshot(space, :local), do: :boids.remove(space, id)
      for %{id: id} <- :boids.obstacles(space), do: :boids.remove_obstacle(space, id)

      setting =
        Map.merge(Enum.at(ponds(), number - 1), Map.take(options, [:ducklings, :pikes, :mother, :nest, :rocks, :reeds]))

      for {{x, y, r}, n} <- Enum.with_index(setting.rocks), do: :ok = :boids.set_obstacle(space, {:rock, n}, {x, y}, r)
      for {{x, y, r}, n} <- Enum.with_index(setting.reeds), do: :ok = :boids.set_obstacle(space, {:reeds, n}, {x, y}, r)

      {:ok, mother} = :gen_boid.start(space, Mother, setting.mother)
      places = places(setting)

      for {pos, n} <- Enum.with_index(places) do
        options = %{id: {:duckling, n}, pos: pos, space: space, director: self(), nest: setting.nest}
        {:ok, _} = :gen_boid.start(space, Duckling, options)
      end

      for {pos, n} <- Enum.with_index(pikes(setting)) do
        {:ok, _} = :gen_boid.start(space, Pike, %{id: {:pike, n}, pos: pos})
      end

      %{
        state
        | number: number,
          pond: setting,
          state: :swimming,
          mother: mother,
          total: length(places),
          safe: 0,
          breaks: 0,
          joins: 0,
          start: now(),
          time: 0
      }
    end

    # The places of the ducklings: a list from a test, or random places on
    # the water, not in an obstacle, not in the nest, and not near the
    # mother.
    defp places(%{ducklings: places}) when is_list(places), do: places
    defp places(setting), do: free(setting, setting.ducklings, 14)

    defp pikes(%{pikes: places}) when is_list(places), do: places
    defp pikes(setting), do: free(setting, setting.pikes, 30)

    defp free(_setting, 0, _away), do: []

    defp free(setting, count, away) do
      obstacles = setting.rocks ++ setting.reeds

      Stream.repeatedly(fn -> {28 + :rand.uniform() * 104, 8 + :rand.uniform() * 74} end)
      |> Stream.filter(fn pos ->
        :boids_vec.dist(pos, setting.mother) > away and not Line.inside?(pos, grow(setting.nest, 6)) and
          Enum.all?(obstacles, fn {x, y, r} -> :boids_vec.dist(pos, {x, y}) > r + 3 end)
      end)
      |> Enum.take(count)
    end

    defp grow({x0, y0, x1, y1}, d), do: {x0 - d, y0 - d, x1 + d, y1 + d}

    # The header for the page: the ground, the nest, the rocks (the
    # reeds are drawn by the page), and the reeds.
    defp header(setting) do
      {x0, y0, x1, y1} = setting.nest

      %{
        ground: "water",
        zones: [[x0, y0, x1, y1, "gold", "Nest"]],
        rocks: for({x, y, r} <- setting.rocks, do: [x, y, r]),
        reeds: for({x, y, r} <- setting.reeds, do: [x, y, r])
      }
    end

    defp now, do: System.monotonic_time(:millisecond)
  end

  # --- The scene ---------------------------------------------------------

  # The argument is nil for a visitor. A test gives options of the
  # director: the pond, the ducklings (a number, or a list of places),
  # the pikes (a number, or a list of places), the mother, the nest, the
  # rocks and the reeds.
  @impl true
  def start(options) do
    {:ok, world} =
      :boids.start_world(
        bounds: {{0, 0}, {@width, @height}},
        wrap: false,
        cell_size: 12,
        relations: :acyclic,
        defaults: %{tick: BoidsExamples.Scene.tick()}
      )

    space = :boids.space(world)
    {:ok, director} = Director.start_link(space, options || %{})
    {:ok, %{space: space, director: director}}
  end

  @impl true
  def kinds(_scene) do
    [
      %{name: "mother", shape: "duck", color: "fur", size: 2.6},
      %{name: "lost ducklings", shape: "duckling", color: "wool", size: 1.5},
      %{name: "ducklings in the line", shape: "duckling", color: "gold", size: 1.5},
      %{name: "safe ducklings", shape: "duckling", color: "gold", size: 1.5},
      %{name: "pikes", shape: "shark", color: "rock", size: 2.6}
    ]
  end

  @impl true
  def header(%{director: director}), do: Director.status(director).h

  @impl true
  def look(_scene, %{group: :mother, vel: vel}), do: {0, BoidsExamples.Scene.angle(vel), 0}
  def look(_scene, %{group: :pikes, vel: vel}), do: {4, BoidsExamples.Scene.angle(vel), 0}
  def look(_scene, %{data: %{safe: true}, vel: vel}), do: {3, BoidsExamples.Scene.angle(vel), 0}
  def look(_scene, %{data: %{line: true}, vel: vel}), do: {2, BoidsExamples.Scene.angle(vel), 0}
  def look(_scene, %{vel: vel}), do: {1, BoidsExamples.Scene.angle(vel), 0}

  @impl true
  def more(%{director: director}, _number), do: Director.status(director)

  @impl true
  def input(%{director: director}, message), do: Director.input(director, message)
end
