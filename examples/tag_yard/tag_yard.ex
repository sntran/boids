defmodule BoidsExamples.Games.TagYard do
  @moduledoc """
  Tag Yard: a game of tag in a school yard. One child is "it". The other
  children run from it. When "it" touches a child, that child becomes
  "it". The person is one of the children.

  The example shows these parts of the library:

  - A state that goes from boid to boid by a message: "it" sends `tagged`
    to the process of the child that it touches, and that child becomes
    "it". No process decides who is "it".
  - Rules that change with the state: a runner flees "it", "it" chases
    the nearest runner, and a frozen child stands still.
  - The data that the neighbors see: a child shows its role, if it cannot
    be tagged now ("no tag back"), and if it is a tired "it". The other
    children decide from that data.
  - A boid that a person controls: the force of the person is a rule of
    its own, a function that reads the keys.

  There are two modes. In "Classic", one child is "it", and the child
  that is "it" at the bell loses. In "Freeze", three children are "it", a
  child that they touch is frozen, and a free child that touches a
  frozen child frees it. "It" wins when all the children are frozen, and
  the runners win at the bell.

  The `Director` is the process of a round: the mode, the time, the
  score of the person, and a new "it" when no child is "it".
  """
  @behaviour BoidsExamples.Scene
  use BoidsExamples.Game

  @impl BoidsExamples.Game
  def info do
    %{
      slug: "tag-yard",
      title: "Tag Yard",
      tag: "Keys",
      pitch:
        "Play tag in a school yard. Run from the child that is \"it\". When it touches you, you are it, and you must touch another child.",
      shows:
        "a state that goes from boid to boid by a message, rules that change with the state, and a role that moves through a crowd.",
      icon:
        ~S(<circle class="mark-rock" cx="44" cy="12" r="7"/><circle class="mark-ink" cx="12" cy="16" r="5"/><circle class="mark-ink" cx="24" cy="40" r="5"/><circle class="mark-ink" cx="46" cy="42" r="5"/><circle class="mark-warm" cx="30" cy="24" r="6"/><circle class="mark-cool" cx="12" cy="44" r="5"/>),
      order: 120
    }
  end

  @width 160
  @height 90
  @yard {{4, 4}, {156, 86}}
  @trees [{38, 62, 5}, {80, 22, 6}, {118, 64, 5}, {58, 32, 4}, {132, 26, 4}]
  @names ~w(Ana Ben Cleo Dev Eli Fay Gus Hana Ivo Juno Kit Lea Milo Nia)

  @doc "The distance at which a child touches another child."
  def touch, do: 2.6

  @doc "The steps of a boid in a time in milliseconds."
  def steps(milliseconds), do: max(div(milliseconds, BoidsExamples.Scene.tick()), 1)

  @doc "The trees of the yard: obstacles of the world, as `{X, Y, Radius}`."
  def trees, do: @trees

  @doc "The names of the children that the computer moves."
  def names, do: @names

  @doc """
  The distance at which a runner flees "it". A tired "it" is slow, so the
  runners come nearer to it: they tease it. Then it can tag a runner, and
  the game does not stall.
  """
  def fear(%{tired: true}), do: 7.0
  def fear(_data), do: 16.0

  @doc """
  The force that makes "it" chase: to the nearest runner that it sees and
  that it can tag. A runner that was "it" a moment ago cannot be tagged
  ("no tag back").
  """
  def chase(boid, neighbors, _seen) do
    case Enum.find(neighbors, &target?/1) do
      nil -> {0.0, 0.0}
      runner -> :boids_steer.pursue(boid, runner.pos, runner.vel, 1.0)
    end
  end

  @doc "The force that makes a runner flee the nearest \"it\" that it sees, inside its distance of fear."
  def escape(boid, neighbors, _seen) do
    case Enum.find(neighbors, &(&1.data[:role] == :it and &1.dist <= fear(&1.data))) do
      nil -> {0.0, 0.0}
      it -> :boids_steer.evade(boid, it.pos, it.vel, 1.0)
    end
  end

  @doc """
  The force that brings a runner to a frozen friend (in Freeze), when no
  "it" is near.
  """
  def help(boid, neighbors, _seen) do
    danger = Enum.any?(neighbors, &(&1.data[:role] == :it and &1.dist <= 16))

    case !danger && Enum.find(neighbors, &(&1.data[:role] == :frozen)) do
      %{pos: pos} -> :boids_steer.seek(boid, pos)
      _ -> {0.0, 0.0}
    end
  end

  @doc "True for a neighbor that \"it\" can tag."
  def target?(%{data: %{role: :runner, immune: false}}), do: true
  def target?(_neighbor), do: false

  defmodule Child do
    @moduledoc """
    A child of the yard: a runner, "it", or frozen (in Freeze). Its state
    has its role. Its data shows its role, if it cannot be tagged now
    (`immune`), and if it is a tired "it".

    The person is a child too (`person: true`): its force is a function
    that reads the keys, and Shift makes it run while it has stamina.
    The other children move by the rules of their role.

    A tag is a message: "it" casts `{:tagged, Name}` to the process of the
    child that it touches. In Classic, the child becomes "it", and the
    old "it" becomes a runner that cannot be tagged back for 3 seconds. In
    Freeze, the child becomes frozen. A free runner that touches a frozen
    child casts `:freed` to it.
    """
    @behaviour :gen_boid
    alias BoidsExamples.Games.TagYard, as: Yard

    @walk 8.5
    @sprint 12.5

    @impl true
    def init(%{pos: pos, name: name, role: role, mode: mode, director: director} = options) do
      person = Map.get(options, :person, false)

      state = %{
        name: name,
        person: person,
        mode: mode,
        director: director,
        role: role,
        immune: 0,
        it_steps: 0,
        keys: %{},
        stamina: 100.0,
        stopped: false
      }

      boid = %{
        pos: pos,
        vel: :boids_vec.scale(:boids_vec.random_unit(2), 2.0),
        group: role,
        perception: 22,
        max_force: if(person, do: 70, else: 30),
        state: state,
        data: data(state)
      }

      {:ok, Map.merge(boid, look(state))}
    end

    @doc "The data that the neighbors see. The data of the person also has its stamina, for the page."
    def data(state) do
      data = %{role: state.role, immune: state.immune > 0, tired: tired?(state), name: state.name}
      if state.person, do: Map.put(data, :stamina, round(state.stamina)), else: data
    end

    # A child that the computer moves is tired after 10 seconds as "it",
    # in Classic. In Freeze, "it" stays "it": it does not get tired.
    defp tired?(%{person: false, role: :it, mode: :classic, it_steps: steps}), do: steps > Yard.steps(10_000)
    defp tired?(_state), do: false

    @doc "The rules and the speed of a child for its role."
    def look(%{person: true, role: :frozen}), do: %{max_speed: 0.0, rules: []}

    def look(%{person: true, keys: keys, stamina: stamina}) do
      run = keys[:run] == true and stamina > 0
      %{max_speed: if(run, do: @sprint, else: @walk), rules: [{&Child.legs/3, 1.0}, {:avoid, 2.0, %{lookahead: 0.6}}]}
    end

    def look(%{role: :frozen}), do: %{max_speed: 0.0, rules: []}

    def look(%{role: :it} = state) do
      # In Classic, "it" gets slower while it stays "it": from 11 to 8 in
      # 20 seconds.
      tired = if state.mode == :classic, do: min(state.it_steps / Yard.steps(20_000), 1.0), else: 0.0

      %{
        max_speed: 11.0 - 3.0 * tired,
        rules: [
          {:contain, 2.0, %{bounds: Yard.yard(), margin: 5}},
          {:avoid, 3.0, %{lookahead: 1.0}},
          {&Yard.chase/3, 2.5},
          {:wander, 0.4}
        ]
      }
    end

    def look(%{role: :runner, mode: mode}) do
      help = if mode == :freeze, do: [{&Yard.help/3, 0.8}], else: []

      %{
        max_speed: 9.0,
        rules:
          [
            {:contain, 3.0, %{bounds: Yard.yard(), margin: 6}},
            {:avoid, 3.0, %{lookahead: 1.0}},
            {&Yard.escape/3, 2.0},
            {:separation, 1.2, %{radius: 3}}
          ] ++ help ++ [{:wander, 0.6}, {:cruise, 0.2, %{speed: 3.0}}]
      }
    end

    @doc "The force of the person: to the velocity that the keys ask for."
    def legs(%{vel: vel, max_speed: speed, state: %{keys: keys, stopped: stopped}}, _neighbors, _seen) do
      direction =
        if stopped do
          {0.0, 0.0}
        else
          x = if(keys[:right], do: 1.0, else: 0.0) - if(keys[:left], do: 1.0, else: 0.0)
          y = if(keys[:up], do: 1.0, else: 0.0) - if(keys[:down], do: 1.0, else: 0.0)
          :boids_vec.normalize({x, y})
        end

      :boids_vec.scale(:boids_vec.sub(:boids_vec.scale(direction, speed), vel), 6.0)
    end

    # Decide: "it" tags a runner that it touches, and a runner frees a
    # frozen child that it touches (in Freeze).
    @impl true
    def handle_decide(%{neighbors: neighbors, lookup: lookup}, %{state: state} = boid) do
      touched = Enum.filter(neighbors, &(&1.dist <= Yard.touch()))

      state =
        case state.role do
          :it ->
            case Enum.find(touched, &Yard.target?/1) do
              nil -> state
              runner -> tag(state, runner, lookup)
            end

          :runner when state.mode == :freeze ->
            for friend <- touched, friend.data[:role] == :frozen do
              with {:ok, %{pid: pid}} <- lookup.(friend.id), do: :gen_boid.cast(pid, {:freed, state.name})
            end

            state

          _ ->
            state
        end

      {:ok, change(boid, state)}
    end

    # The tag is a message to the process of the runner. In Classic, the
    # tagger is then a runner that cannot be tagged back for 3 seconds.
    defp tag(state, runner, lookup) do
      with {:ok, %{pid: pid}} <- lookup.(runner.id), do: :gen_boid.cast(pid, {:tagged, state.name})
      GenServer.cast(state.director, {:tag, state.name, runner.data.name, state.person})

      if state.mode == :classic do
        %{state | role: :runner, immune: Yard.steps(3000), it_steps: 0}
      else
        state
      end
    end

    # Act: the clocks of the child, its stamina, and the place of the
    # person, which stays in the yard. Running uses stamina. The stamina
    # comes back only when the person does not run.
    @impl true
    def handle_act(%{state: state} = boid) do
      dt = BoidsExamples.Scene.tick() / 1000
      moving = Enum.any?([:left, :right, :up, :down], &(state.keys[&1] == true))
      running = state.person and moving and state.keys[:run] == true and state.role != :frozen

      stamina =
        if running,
          do: max(state.stamina - 30 * dt, 0.0),
          else: min(state.stamina + 12 * dt, 100.0)

      state = %{
        state
        | immune: max(state.immune - 1, 0),
          it_steps: if(state.role == :it, do: state.it_steps + 1, else: 0),
          stamina: stamina
      }

      boid = if state.person, do: %{boid | pos: inside(boid.pos)}, else: boid
      {:ok, change(boid, state)}
    end

    defp inside({x, y}), do: {min(max(x, 1.0), 159.0), min(max(y, 1.0), 89.0)}

    @impl true
    def handle_cast({:keys, keys}, %{state: state} = boid), do: {:noreply, change(boid, %{state | keys: keys})}

    # A tag: only a runner that can be tagged now.
    def handle_cast({:tagged, _by}, %{state: %{role: :runner, immune: 0} = state} = boid) do
      role = if state.mode == :classic, do: :it, else: :frozen
      {:noreply, change(boid, %{state | role: role, it_steps: 0})}
    end

    def handle_cast({:tagged, _by}, boid), do: {:noreply, boid}

    def handle_cast({:freed, by}, %{state: %{role: :frozen} = state} = boid) do
      GenServer.cast(state.director, {:freed, by, state.name})
      # A child that is free again cannot be frozen for 2 seconds.
      {:noreply, change(boid, %{state | role: :runner, immune: Yard.steps(2000)})}
    end

    def handle_cast({:freed, _by}, boid), do: {:noreply, boid}

    # The director makes a child "it": at the start, or when no child is it.
    def handle_cast(:make_it, %{state: state} = boid), do: {:noreply, change(boid, %{state | role: :it, immune: 0})}

    # At the bell, the person stops.
    def handle_cast(:stop, %{state: state} = boid), do: {:noreply, change(boid, %{state | stopped: true, keys: %{}})}

    # A change of the state changes the rules when the look changes, and
    # the data that the neighbors see.
    defp change(%{state: old} = boid, state) do
      boid =
        if look(old) == look(state) do
          boid
        else
          :boids_boid.update(boid, look(state))
        end

      %{boid | state: state, group: state.role, data: data(state)}
    end
  end

  defmodule Director do
    @moduledoc """
    The process of a round: the mode (`classic` or `freeze`), the phase
    (`playing` or `over`), the time, and the score of the person: its
    seconds free, its tags (Classic) and its rescues (Freeze). At each
    tick it reads the yard. In Classic, when no child is "it" for one
    second (a tag that found no runner), it makes a child "it".
    """
    use GenServer
    alias BoidsExamples.Games.TagYard, as: Yard

    @rounds %{classic: 90_000, freeze: 60_000}

    def start_link(space, options), do: GenServer.start_link(__MODULE__, {space, options})
    def status(director), do: GenServer.call(director, :status)
    def input(director, message), do: GenServer.cast(director, {:input, message})

    @doc "The time of a round of a mode, in milliseconds."
    def duration(mode), do: Map.fetch!(@rounds, mode)

    # --- GenServer -------------------------------------------------------

    @impl true
    def init({space, options}) do
      # The director stops with the world.
      Process.monitor(space.owner)
      send(self(), :check)
      state = %{space: space, options: options, children: %{}, you: nil}
      {:ok, new_round(state, Map.get(options, :mode, :classic))}
    end

    @impl true
    def handle_call(:status, _from, state), do: {:reply, report(state), state}

    @impl true
    def handle_cast({:tag, by, to, person}, %{phase: :playing} = state) do
      tags = if person, do: state.tags + 1, else: state.tags
      {:noreply, %{state | tags: tags, last: "#{by} tagged #{to}.", no_it: 0}}
    end

    def handle_cast({:freed, by, who}, %{phase: :playing} = state) do
      rescues = if by == "You", do: state.rescues + 1, else: state.rescues
      {:noreply, %{state | rescues: rescues, last: "#{by} freed #{who}."}}
    end

    def handle_cast({:input, %{"keys" => names}}, %{phase: :playing, you: you} = state) when is_list(names) do
      keys =
        for name <- names, name in ["left", "right", "up", "down", "run"], into: %{} do
          {String.to_existing_atom(name), true}
        end

      :gen_boid.cast(you, {:keys, keys})
      {:noreply, state}
    end

    def handle_cast({:input, %{"mode" => mode}}, state) when mode in ["classic", "freeze"] do
      {:noreply, new_round(state, String.to_existing_atom(mode))}
    end

    def handle_cast({:input, %{"go" => true}}, state), do: {:noreply, new_round(state, state.mode)}
    def handle_cast(_message, state), do: {:noreply, state}

    @impl true
    def handle_info({:DOWN, _ref, :process, _pid, _reason}, state), do: {:stop, :normal, state}

    def handle_info(:check, state) do
      Process.send_after(self(), :check, BoidsExamples.Scene.tick())
      {:noreply, check(state)}
    end

    # Read the yard: who is "it", the frozen children, and the time of the
    # person as a free child.
    defp check(%{phase: :playing, space: space} = state) do
      now = now()
      rows = :boids.snapshot(space, :local)
      kids = for %{group: group, data: %{name: _}} = row <- rows, group in [:runner, :it, :frozen], do: row
      its = for %{data: %{role: :it}} = row <- kids, do: row.data.name
      frozen = Enum.count(kids, &(&1.data.role == :frozen))
      you = Enum.find(kids, &(&1.data.name == "You"))
      free = you != nil and you.data.role == :runner
      free_ms = state.free_ms + if(free, do: now - state.checked, else: 0)

      state = %{
        state
        | its: its,
          frozen: frozen,
          kids: length(kids),
          free_ms: free_ms,
          checked: now,
          you_role: you && you.data.role,
          marks: marks(kids),
          stamina: (you && you.data[:stamina]) || 100
      }

      cond do
        state.mode == :freeze and frozen > 0 and frozen == length(kids) - length(its) ->
          over(state, "It froze all the children.", false)

        now - state.start >= state.duration ->
          won = if state.mode == :classic, do: you != nil and you.data.role != :it, else: true

          text =
            case {state.mode, won} do
              {:classic, true} -> "The bell rang, and you are not it."
              {:classic, false} -> "The bell rang, and you are it."
              {:freeze, _} -> "The bell rang before it froze all the children."
            end

          over(state, text, won)

        state.mode == :classic and its == [] ->
          repair(state)

        true ->
          %{state | no_it: 0}
      end
    end

    defp check(state), do: state

    # The places of the person and of "it", for the rings on the page.
    defp marks(kids) do
      for %{pos: {x, y}, data: %{name: name, role: role}} <- kids, name == "You" or role == :it do
        [Float.round(x * 1.0, 1), Float.round(y * 1.0, 1), if(name == "You", do: "you", else: "it")]
      end
    end

    # A tag that found no runner leaves no "it". After one second with no
    # "it", a child that the computer moves becomes it.
    defp repair(%{no_it: no_it} = state) do
      if no_it + 1 >= Yard.steps(1000) do
        case Enum.reject(Map.keys(state.children), &(&1 == state.you)) do
          [] -> :ok
          pids -> :gen_boid.cast(Enum.random(pids), :make_it)
        end

        %{state | no_it: 0}
      else
        %{state | no_it: no_it + 1}
      end
    end

    defp over(state, text, won) do
      for pid <- Map.keys(state.children), do: :gen_boid.cast(pid, :stop)
      %{state | phase: :over, text: text, won: won, time: now() - state.start}
    end

    defp report(state) do
      left = max(state.duration - (now() - state.start), 0)
      left = if state.phase == :playing, do: left, else: max(state.duration - state.time, 0)
      it_now = state.its |> Enum.sort() |> Enum.join(" and ")
      # The same readings in the two modes: the page keeps a reading for
      # each label.
      score = if state.mode == :classic, do: count(state.tags, "tag"), else: count(state.rescues, "rescue")

      %{
        r: [
          ["Mode", if(state.mode == :classic, do: "Classic", else: "Freeze")],
          ["It now", if(it_now == "", do: "nobody", else: it_now)],
          ["Your time free", "#{div(state.free_ms, 1000)} s"],
          ["Your score", score],
          [
            "Frozen",
            if(state.mode == :freeze, do: "#{state.frozen} of #{state.kids - length(state.its)}", else: "none")
          ]
        ],
        x: %{
          mode: state.mode,
          phase: state.phase,
          won: state.won == true,
          text: state.text || "",
          last: state.last || "",
          left: div(left, 1000),
          free: div(state.free_ms, 1000),
          tags: state.tags,
          rescues: state.rescues,
          you: state.you_role,
          stamina: state.stamina,
          marks: state.marks,
          its: state.its,
          frozen: state.frozen
        }
      }
    end

    defp count(1, word), do: "1 #{word}"
    defp count(n, word), do: "#{n} #{word}s"

    # Start a round: clear the yard, then the children, then "it".
    defp new_round(%{space: space, options: options} = state, mode) do
      for pid <- Map.keys(state.children), do: Process.exit(pid, :kill)
      for %{id: id} <- :boids.snapshot(space, :local), do: :boids.remove(space, id)

      you_at = Map.get(options, :you, {80.0, 45.0})
      places = positions(Map.get(options, :kids, length(Yard.names())), you_at)
      names = Enum.take(Yard.names(), length(places))
      director = self()

      kids =
        for {pos, name} <- Enum.zip(places, names) do
          options = %{pos: pos, name: name, role: :runner, mode: mode, director: director}
          {:ok, pid} = :gen_boid.start(space, Yard.Child, options)
          {name, pid}
        end

      you_role = if Map.get(options, :you_it, false), do: :it, else: :runner

      {:ok, you} =
        :gen_boid.start(space, Yard.Child, %{
          pos: you_at,
          name: "You",
          role: you_role,
          mode: mode,
          director: director,
          person: true
        })

      # "It" at the start: the children of the option it (their numbers),
      # or children at random. The person starts free, if no option says
      # else.
      count = if mode == :classic, do: 1, else: 3
      its = Map.get(options, :it, Enum.take_random(0..(length(kids) - 1)//1, count))
      its = if you_role == :it and mode == :classic, do: [], else: its
      for n <- its, {_name, pid} <- [Enum.at(kids, n)], do: :gen_boid.cast(pid, :make_it)

      children = Map.new([{you, "You"} | for({name, pid} <- kids, do: {pid, name})])

      %{
        state
        | children: children,
          you: you
      }
      |> Map.merge(%{
        mode: mode,
        phase: :playing,
        duration: Map.get(options, :duration, duration(mode)),
        start: now(),
        checked: now(),
        free_ms: 0,
        tags: 0,
        rescues: 0,
        its: [],
        frozen: 0,
        kids: length(kids) + 1,
        no_it: 0,
        last: nil,
        text: nil,
        won: nil,
        time: 0,
        you_role: you_role,
        stamina: 100,
        marks: []
      })
    end

    # The places of the children: at random in the yard, away from the
    # trees and from the person, or the places that a test gives.
    defp positions(places, _you) when is_list(places), do: places

    defp positions(count, you) do
      for _ <- 1..count//1, do: free_place(you)
    end

    defp free_place(you) do
      pos = {12 + :rand.uniform() * 136, 10 + :rand.uniform() * 70}
      near_tree = Enum.any?(Yard.trees(), fn {x, y, r} -> :boids_vec.dist(pos, {x, y}) < r + 4 end)
      if near_tree or :boids_vec.dist(pos, you) < 14, do: free_place(you), else: pos
    end

    defp now, do: System.monotonic_time(:millisecond)
  end

  @doc "The box of the yard, for the rule contain."
  def yard, do: @yard

  # --- The scene ---------------------------------------------------------

  # The argument is nil for a visitor. A test gives options of the
  # director: the mode, the children (a number, or a list of places), the
  # children that are "it" (their numbers), the place of the person, if
  # the person is "it" (`you_it`), and the time of a round.
  @impl true
  def start(options) do
    {:ok, world} =
      :boids.start_world(
        bounds: {{0, 0}, {@width, @height}},
        wrap: false,
        cell_size: 12,
        defaults: %{tick: BoidsExamples.Scene.tick()}
      )

    for {{x, y, r}, n} <- Enum.with_index(@trees), do: :ok = :boids.set_obstacle(world, {:tree, n}, {x, y}, r)
    space = :boids.space(world)
    {:ok, director} = Director.start_link(space, options || %{})
    {:ok, %{space: space, director: director}}
  end

  @impl true
  def kinds(_scene) do
    [
      %{name: "runners", shape: "child", color: "cool", size: 2.4},
      %{name: "it", shape: "child", color: "warm", size: 2.6},
      %{name: "tired it", shape: "child", color: "plum", size: 2.6},
      %{name: "frozen", shape: "child", color: "rock", size: 2.4},
      %{name: "you", shape: "child", color: "gold", size: 2.8},
      %{name: "you are it", shape: "child", color: "warm", size: 2.8},
      %{name: "you are frozen", shape: "child", color: "rock", size: 2.8}
    ]
  end

  @impl true
  def header(_scene), do: %{ground: "sand"}

  @impl true
  def look(_scene, %{data: %{name: "You", role: role}, vel: vel}) do
    kind = %{runner: 4, it: 5, frozen: 6}[role]
    {kind, BoidsExamples.Scene.angle(vel), 0}
  end

  def look(_scene, %{data: %{role: :it, tired: true}, vel: vel}), do: {2, BoidsExamples.Scene.angle(vel), 0}
  def look(_scene, %{data: %{role: :it}, vel: vel}), do: {1, BoidsExamples.Scene.angle(vel), 0}
  def look(_scene, %{data: %{role: :frozen}, vel: vel}), do: {3, BoidsExamples.Scene.angle(vel), 0}
  def look(_scene, %{vel: vel}), do: {0, BoidsExamples.Scene.angle(vel), 0}

  @impl true
  def more(%{director: director}, _number), do: Director.status(director)

  @impl true
  def input(%{director: director}, message), do: Director.input(director, message)
end
