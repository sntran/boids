defmodule BoidsSite.Scenes.Lab do
  @moduledoc """
  Flock Lab: puzzles that teach programming to young people. In each
  level, the player builds a program from blocks, presses Run, and sees
  if the sheep (or the dog) do what the level asks.

  A block is a rule of the library with a friendly name. Its strength
  (1 to 5) is the weight of the rule, and the order of the blocks is the
  order of the rules. The block "When I see" gives other rules while a
  sheep sees a wolf or a dog: the idea of a condition.

  The program is data, and not code: the server makes the rules from a
  fixed list of blocks. The player sees the same rules as Erlang and
  Elixir code with "Show the code".

  The example shows these parts of the library:

  - A program is a list of rules, and the result emerges from them.
  - With `combine => priority`, the order of the rules is their priority
    (level 5).
  - A boid with other rules while it sees a group (`handle_decide/2` of
    `Sheep`).
  - A relation (level 7): each sheep follows the leader.
  - A rule that is a function (level 8): the dog walks behind the sheep.
  - `boids:flocks/2` measures the goal of level 4.
  """
  @behaviour BoidsSite.Scene

  @width 160
  @height 90

  # The blocks: the name that the page sends, the name for the player, and
  # how the block becomes a rule. A name of the player never becomes an
  # atom: each name is in this list.
  @blocks %{
    "flag" => "Go to the flag",
    "friends" => "Stay with friends",
    "space" => "Do not bump",
    "align" => "Go the same way",
    "rocks" => "Walk around rocks",
    "wolf" => "Run from the wolf",
    "leader" => "Follow the leader",
    "wander" => "Wander",
    "sheep" => "Go to the sheep",
    "behind" => "Walk behind the sheep",
    "pen" => "Go to the pen"
  }

  @sees %{"wolf" => :wolf, "dog" => :dog}

  # The fence of each level: the sheep stay in the field.
  @fence {:contain, 3, %{margin: 4}}

  @doc "The levels of the game."
  def levels do
    [
      %{
        n: 1,
        title: "First steps",
        idea: "A program is a list of steps. Each block is one step for the sheep.",
        hint: "Put the block \"Go to the flag\" in your program. Then press Run.",
        goal: "Bring all the sheep to the pen.",
        palette: ~w(flag wander),
        sheep: 8,
        start: {6, 30, 12, 78},
        pens: [{136, 28, 158, 62}],
        time: 35,
        good: 22,
        blocks: 1,
        need: 8
      },
      %{
        n: 2,
        title: "Strong and weak",
        idea: "A number changes what a program does. The strength of a block is its number.",
        hint: "The wind blows the sheep down. Make \"Go to the flag\" strong.",
        goal: "Bring all the sheep to the pen, against the wind.",
        palette: ~w(flag wander),
        sheep: 8,
        start: {6, 30, 50, 82},
        pens: [{136, 50, 158, 84}],
        wind: 1.5,
        time: 35,
        good: 25,
        blocks: 1,
        need: 8
      },
      %{
        n: 3,
        title: "Two teams",
        idea: "A program can have many blocks. All the blocks work at the same time.",
        hint: "The white sheep go right, and the brown sheep go left. They meet in the middle. Do not let them bump.",
        goal: "Bring each team to its pen, with 3 bumps or fewer.",
        palette: ~w(flag space friends wander),
        sheep: 14,
        teams: true,
        start: {8, 30, 30, 60},
        pens: [{136, 25, 158, 65}, {2, 25, 24, 65}],
        time: 35,
        good: 26,
        blocks: 2,
        need: 14,
        bumps: 3
      },
      %{
        n: 4,
        title: "One flock",
        idea: "Simple blocks can make something big. No block says \"make a flock\".",
        hint: "The sheep are in small groups. Make them one flock.",
        goal: "Make one flock, for 3 seconds.",
        palette: ~w(friends align space wander),
        sheep: 16,
        start: {30, 130, 15, 75},
        pens: [],
        perception: 40,
        time: 40,
        good: 20,
        blocks: 2,
        flock: 3
      },
      %{
        n: 5,
        title: "First things first",
        idea: "The order of the blocks is important. The first block gets its way first.",
        hint: "Rocks are in the way. Put \"Walk around rocks\" first.",
        goal: "Bring 8 of 10 sheep to the pen. A sheep in a rock is stuck.",
        palette: ~w(flag rocks space wander),
        sheep: 10,
        start: {6, 26, 25, 65},
        pens: [{136, 28, 158, 62}],
        rocks: [{60, 45, 9}, {88, 30, 7}, {88, 60, 7}, {112, 45, 7}],
        combine: :priority,
        time: 40,
        good: 26,
        blocks: 2,
        need: 8
      },
      %{
        n: 6,
        title: "When",
        idea: "A program can ask a question: when this happens, do that.",
        hint: "Use the block \"When I see\". When a sheep sees the wolf, it must run.",
        goal: "Bring 7 of 8 sheep to the pen. The wolf catches the sheep that it touches.",
        palette: ~w(flag wolf friends space when),
        sees: ~w(wolf),
        inside: ~w(wolf),
        sheep: 8,
        start: {6, 26, 25, 65},
        pens: [{136, 28, 158, 62}],
        wolf: {80, 45},
        perception: 18,
        time: 40,
        good: 34,
        blocks: 3,
        need: 7
      },
      %{
        n: 7,
        title: "Follow the leader",
        idea: "A boid can know another boid. Here, each sheep knows its leader.",
        hint: "Only the leader knows the way. The other sheep must follow it.",
        goal: "Bring 8 of 10 sheep to the pen, past the rocks.",
        palette: ~w(leader space friends align),
        sheep: 9,
        leader: true,
        start: {6, 24, 35, 55},
        pens: [{136, 28, 158, 62}],
        rocks: [{70, 21, 10}, {70, 71, 10}, {104, 38, 8}],
        path: [{40, 46}, {70, 46}, {88, 50}, {104, 60}, {124, 52}, {147, 45}],
        time: 40,
        good: 28,
        blocks: 2,
        need: 8
      },
      %{
        n: 8,
        title: "The dog",
        idea: "Now you write the program of the dog. The sheep run from the dog.",
        hint: "A good dog walks behind the sheep, on the side away from the pen.",
        goal: "Bring 8 of 10 sheep to the pen, with the dog.",
        palette: ~w(behind sheep pen wander),
        dog: {8, 45},
        perception: 20,
        sheep: 10,
        start: {40, 70, 25, 65},
        pens: [{122, 15, 158, 75}],
        time: 45,
        good: 28,
        blocks: 1,
        need: 8
      }
    ]
  end

  @doc "A level, from its number."
  def level(n), do: Enum.find(levels(), &(&1.n == n))

  @doc "The blocks: their names on the page and for the player."
  def blocks, do: @blocks

  # --- A program ----------------------------------------------------------

  @doc """
  Check a program of a player for a level. The result is `{:ok,
  program}`, where a program is a list of `{name, power}` and `{:when,
  group, [{name, power}]}`, or `{:error, text}` with a text for the player.
  """
  def program(level, blocks) when is_list(blocks) do
    cond do
      length(blocks) > 8 -> {:error, "A program has 8 blocks at most."}
      true -> {:ok, Enum.map(blocks, &block(level, &1, true))} |> unique()
    end
  catch
    {:bad, text} -> {:error, text}
  end

  def program(_level, _blocks), do: {:error, "The program is a list of blocks."}

  defp block(level, %{"when" => what, "do" => inner}, true) when is_list(inner) do
    group = Map.get(@sees, what)
    check("when" in level.palette, "This level has no block \"When I see\".")
    check(group != nil and what in Map.get(level, :sees, []), "In this level, a sheep can not see that.")
    check(length(inner) <= 4, "A \"When I see\" block has 4 blocks at most.")
    {:when, group, Enum.map(inner, &block(level, &1, false))}
  end

  defp block(_level, %{"when" => _}, false), do: throw({:bad, "A \"When I see\" block can not be in another one."})

  defp block(level, %{"block" => name, "power" => power}, top) when is_binary(name) do
    check(Map.has_key?(@blocks, name) and name in level.palette, "This level has no block \"#{name}\".")

    check(
      not top or name not in Map.get(level, :inside, []),
      "Put the block \"#{@blocks[name]}\" inside a \"When I see\" block."
    )

    check(is_integer(power) and power >= 1 and power <= 5, "A strength is from 1 to 5.")
    {name, power}
  end

  defp block(_level, _other, _top), do: throw({:bad, "A block is not right. Take it again from the blocks."})

  defp check(true, _text), do: :ok
  defp check(false, text), do: throw({:bad, text})

  # A block one time in a list: a stronger block, and not two blocks.
  defp unique({:ok, program} = result) do
    lists = [program | for({:when, _group, inner} <- program, do: inner)]

    unique? = fn list ->
      names = for {name, _power} <- list, do: name
      length(Enum.uniq(names)) == length(names)
    end

    if Enum.all?(lists, unique?) do
      result
    else
      {:error, "You have the same block two times. Use one block, and make it stronger."}
    end
  end

  @doc "The number of blocks of a program: a \"When I see\" block counts as one, with its blocks."
  def size(program) do
    Enum.sum(for item <- program, do: if(match?({:when, _, _}, item), do: 1 + length(elem(item, 2)), else: 1))
  end

  @doc """
  The rules of the program for a boid of a level: the rules of the blocks
  in their order, and before them the rules that the level adds (the
  fence, and the wind of level 2). The second element is the rules for
  each "When I see" block.
  """
  def rules(level, program, flag) do
    fixed = fixed(level)
    main = fixed ++ for({name, power} <- program, do: rule(level, name, power, flag))

    others =
      for {:when, group, inner} <- program do
        {group, fixed ++ for({name, power} <- inner, do: rule(level, name, power, flag))}
      end

    {main, others}
  end

  defp fixed(%{wind: wind}), do: [@fence, {:flow, wind, %{field: {0, -1}}}]
  defp fixed(_level), do: [@fence]

  defp rule(_level, "flag", power, flag), do: {:seek, power, %{target: flag}}
  defp rule(_level, "friends", power, _flag), do: {:cohesion, power, %{}}
  defp rule(_level, "space", power, _flag), do: {:separation, power, %{radius: 5}}
  defp rule(_level, "align", power, _flag), do: {:alignment, power, %{}}
  defp rule(_level, "rocks", power, _flag), do: {:avoid, power, %{lookahead: 1.5}}
  defp rule(_level, "wolf", power, _flag), do: {:flee, power, %{target: {:group, :wolf}}}
  defp rule(_level, "leader", power, _flag), do: {:leader, power, %{target: {:related, :follows}, distance: 3}}
  defp rule(_level, "wander", power, _flag), do: {:wander, power, %{}}
  defp rule(_level, "sheep", power, _flag), do: {:pursue, power, %{target: {:group, :sheep}}}
  defp rule(_level, "behind", power, _flag), do: {&__MODULE__.behind/3, power, %{}}
  defp rule(_level, "pen", power, flag), do: {:seek, power, %{target: flag}}

  @doc """
  The rule "Walk behind the sheep" of the dog: go to a point behind the
  sheep that the dog sees, on the side away from the pen.
  """
  def behind(%{state: %{pen: pen}} = dog, neighbors, _seen) do
    case for(%{group: :sheep, pos: pos, data: {_team, false}} <- neighbors, do: pos) do
      [] ->
        {0.0, 0.0}

      points ->
        center = :boids_vec.scale(Enum.reduce(points, &:boids_vec.add/2), 1 / length(points))
        away = :boids_vec.normalize(:boids_vec.sub(center, pen))
        :boids_steer.arrive(dog, :boids_vec.add(center, :boids_vec.scale(away, 5)), 4)
    end
  end

  @doc "The center of a pen."
  def center({x0, y0, x1, y1}), do: {(x0 + x1) / 2, (y0 + y1) / 2}

  @doc "True when a point is in a pen."
  def inside?({x, y}, {x0, y0, x1, y1}), do: x >= x0 and x <= x1 and y >= y0 and y <= y1

  # --- The code of a program -----------------------------------------------

  @doc """
  The program of the player as code: the rules that the server gives to a
  sheep (or to the dog), in Erlang and in Elixir.
  """
  def code(level, program) do
    {main, others} = rules(level, program, flag(level, 0))
    who = if level[:dog], do: "the dog", else: "a sheep"
    added = List.duplicate("the level adds this", length(fixed(level)))
    inner = for {:when, _group, blocks} <- program, do: blocks
    parts = for {{group, rules}, blocks} <- Enum.zip(others, inner), do: {group, rules, added ++ names(blocks)}
    teams = if level[:teams], do: " The brown sheep have the other flag.", else: ""

    erlang =
      "%% The rules of #{who}. The level adds the first #{length(added)}.#{teams}\n" <>
        "Rules = [\n" <>
        lines(main, added ++ names(program), &erlang/1, "%%", "    ") <>
        "\n]." <> others(parts, :erlang)

    elixir =
      "# The rules of #{who}. The level adds the first #{length(added)}.#{teams}\n" <>
        "rules = [\n" <>
        lines(main, added ++ names(program), &elixir/1, "#", "    ") <>
        "\n]" <> others(parts, :elixir)

    %{erlang: erlang, elixir: elixir}
  end

  defp names(program), do: for({name, _power} <- program, do: @blocks[name])

  defp lines(rules, names, format, comment, indent) do
    last = length(rules) - 1

    rules
    |> Enum.zip(names)
    |> Enum.with_index()
    |> Enum.map_join("\n", fn {{rule, name}, index} ->
      indent <> format.(rule) <> if(index < last, do: ",", else: "") <> " " <> comment <> " " <> name
    end)
  end

  defp others([], _language), do: ""

  defp others(parts, :erlang) do
    items =
      Enum.map_join(parts, ",\n", fn {group, rules, names} ->
        "    {#{group}, [\n" <> lines(rules, names, &erlang/1, "%%", "        ") <> "\n    ]}"
      end)

    "\n\n%% While a sheep sees the group, it has these rules.\nWhen = [\n" <> items <> "\n]."
  end

  defp others(parts, :elixir) do
    items =
      Enum.map_join(parts, ",\n", fn {group, rules, names} ->
        "    {:#{group}, [\n" <> lines(rules, names, &elixir/1, "#", "        ") <> "\n    ]}"
      end)

    "\n\n# While a sheep sees the group, it has these rules.\nwhen_i_see = [\n" <> items <> "\n]"
  end

  defp erlang(rule), do: IO.iodata_to_binary(:io_lib.format(~c"~0p", [rule]))
  defp elixir(rule), do: inspect(rule)

  # The flag of a sheep: the center of the pen of its team.
  defp flag(level, team) do
    case level.pens do
      [] -> {@width / 2, @height / 2}
      pens -> center(Enum.at(pens, team))
    end
  end

  # --- The boids -----------------------------------------------------------

  defmodule Sheep do
    @moduledoc """
    A sheep. Its rules are the program of the player (or the rules of the
    level, when the player programs the dog). While it sees a group of a
    "When I see" block, it has the rules of that block. A sheep in its pen
    stays in the pen. A sheep in a rock is stuck, and a sheep that the
    wolf catches stops.
    """
    @behaviour :gen_boid

    @impl true
    def init(options), do: {:ok, options}

    @impl true
    def handle_decide(_seen, %{state: %{penned: true}} = boid), do: {:ok, boid}

    def handle_decide(%{neighbors: neighbors, obstacles: rocks}, %{pos: pos, state: state} = boid) do
      cond do
        Enum.any?(rocks, &(:boids_vec.dist(pos, &1.pos) < &1.radius)) ->
          {:stop, :normal, boid}

        state.pen != nil and BoidsSite.Scenes.Lab.inside?(pos, state.pen) ->
          {x0, y0, x1, y1} = state.pen
          rules = [{:contain, 5, %{bounds: {{x0, y0}, {x1, y1}}, margin: 1.5}}, {:separation, 1, %{radius: 2}}]
          {team, _} = boid.data
          boid = :boids_boid.update(boid, %{rules: rules, max_speed: 3, combine: :sum, data: {team, true}})
          {:ok, %{boid | state: %{state | penned: true}}}

        true ->
          groups = MapSet.new(neighbors, & &1.group)

          case Enum.find_index(state.others, fn {group, _rules} -> group in groups end) do
            mode when mode == state.mode -> {:ok, boid}
            nil -> {:ok, mode(boid, nil, state.rules)}
            index -> {:ok, mode(boid, index, elem(Enum.at(state.others, index), 1))}
          end
      end
    end

    # The wolf caught the sheep.
    @impl true
    def handle_cast(:caught, boid), do: {:stop, :normal, boid}

    defp mode(boid, mode, rules), do: %{:boids_boid.update(boid, %{rules: rules}) | state: %{boid.state | mode: mode}}
  end

  defmodule Wolf do
    @moduledoc "The wolf of level 6: it wanders in the middle of the field, hunts a sheep that it sees, and catches a sheep that it touches."
    @behaviour :gen_boid

    @rest [{:contain, 4, %{bounds: {{50, 12}, {110, 78}}, margin: 6}}, {:wander, 1}, {:cruise, 0.5, %{speed: 4.0}}]
    @hunt [{:contain, 4, %{bounds: {{50, 12}, {110, 78}}, margin: 6}}, {:pursue, 1.5, %{target: {:group, :sheep}}}]

    @impl true
    def init(pos) do
      {:ok,
       %{
         pos: pos,
         group: :wolf,
         perception: 16,
         max_speed: 11,
         rules: @rest,
         combine: :priority,
         state: %{rest: 0, mode: :rests}
       }}
    end

    @impl true
    def handle_decide(%{neighbors: neighbors, lookup: lookup}, %{state: %{rest: rest}} = boid) do
      sheep = for %{group: :sheep, data: {_team, false}} = n <- neighbors, do: n

      cond do
        rest > 0 ->
          {:ok, mode(boid, :rests, @rest, rest - 1)}

        match?([%{dist: dist} | _] when dist <= 2.0, sheep) ->
          # The id of a boid is not its process.
          with {:ok, %{pid: pid}} <- lookup.(hd(sheep).id), do: :gen_boid.cast(pid, :caught)
          {:ok, mode(boid, :rests, @rest, BoidsSite.Scenes.Lab.steps(1000))}

        sheep != [] ->
          {:ok, mode(boid, :hunts, @hunt, 0)}

        true ->
          {:ok, mode(boid, :rests, @rest, 0)}
      end
    end

    # The rules change only when the mode changes.
    defp mode(%{state: %{mode: mode}} = boid, mode, _rules, rest), do: %{boid | state: %{rest: rest, mode: mode}}

    defp mode(boid, mode, rules, rest),
      do: %{:boids_boid.update(boid, %{rules: rules}) | state: %{rest: rest, mode: mode}}
  end

  defmodule Dog do
    @moduledoc "The dog of level 8: its rules are the program of the player."
    @behaviour :gen_boid

    @impl true
    def init(options), do: {:ok, options}
  end

  @doc "The steps of a boid in a time in milliseconds."
  def steps(milliseconds), do: max(div(milliseconds, BoidsSite.Scene.tick()), 1)

  # --- The director --------------------------------------------------------

  defmodule Director do
    @moduledoc """
    The process of a try: the level, the size of the program, the time, and
    what the try did (the bumps, the time in one flock). It tells the
    result: running, won with its stars, or failed with a reason. With the
    result, the time of the world stops.
    """
    use GenServer

    def start(space, level, size, manual), do: GenServer.start(__MODULE__, {space, level, size, manual})
    def status(director), do: GenServer.call(director, :status)

    @doc "For a test with a manual clock: look at the world after `elapsed` seconds."
    def observe(director, elapsed), do: GenServer.call(director, {:observe, elapsed})

    @impl true
    def init({space, level, size, manual}) do
      # The director stops with its world: a new try has a new world.
      Process.monitor(space.owner)
      total = level.sheep + if(level[:leader], do: 1, else: 0)

      state = %{
        space: space,
        level: level,
        size: size,
        manual: manual,
        started: now(),
        elapsed: 0.0,
        total: total,
        close: MapSet.new(),
        bumps: 0,
        together: nil,
        result: if(size == :preview, do: :ready, else: :running),
        stars: 0,
        last: %{penned: 0, lost: 0, flocks: 0}
      }

      {:ok, state}
    end

    @impl true
    def handle_call(:status, _from, state) do
      state = if state.manual, do: state, else: look(state, (now() - state.started) / 1000)
      {:reply, report(state), state}
    end

    def handle_call({:observe, elapsed}, _from, state) do
      state = look(state, elapsed)
      {:reply, report(state), state}
    end

    @impl true
    def handle_info({:DOWN, _ref, :process, _pid, _reason}, state), do: {:stop, :normal, state}

    defp look(%{result: :running} = state, elapsed) do
      level = state.level
      rows = :boids.snapshot(state.space, :local)
      sheep = for %{group: :sheep} = row <- rows, do: row
      penned = Enum.count(sheep, &match?(%{data: {_, true}}, &1))
      lost = state.total - length(sheep)
      state = bumps(state, sheep)

      flocks =
        if level[:flock] do
          length(:boids.flocks(state.space, 14, :local))
        else
          0
        end

      together =
        cond do
          not Map.has_key?(level, :flock) -> nil
          flocks == 1 and state.together == nil -> elapsed
          flocks == 1 -> state.together
          true -> nil
        end

      state = %{state | elapsed: elapsed, together: together, last: %{penned: penned, lost: lost, flocks: flocks}}

      cond do
        level[:flock] && together != nil && elapsed - together >= level.flock ->
          won(state, elapsed)

        level[:need] && penned >= level.need && state.bumps <= Map.get(level, :bumps, :infinity) ->
          won(state, elapsed)

        level[:bumps] && state.bumps > level.bumps ->
          failed(state, "Too many bumps. Try a block that keeps the sheep apart.")

        level[:need] && state.total - lost < level.need ->
          failed(state, "Too many sheep are lost. Look at your blocks again.")

        elapsed >= level.time ->
          failed(state, late(state))

        true ->
          state
      end
    end

    defp look(state, _elapsed), do: state

    defp late(%{level: %{flock: _}}), do: "Time is up. The sheep are not one flock yet."
    defp late(%{level: level, last: last}), do: "Time is up. #{last.penned} of #{level.need} sheep are in the pen."

    # A bump: two sheep that come nearer than 1 unit. A pair that stays near
    # is one bump. The sheep in a pen do not bump.
    defp bumps(%{level: %{bumps: _}} = state, sheep) do
      points = for %{id: id, pos: pos, data: {_, false}} <- sheep, do: {id, pos}

      close =
        MapSet.new(for {a, pa} <- points, {b, pb} <- points, a < b, :boids_vec.dist(pa, pb) < 1.0, do: {a, b})

      %{state | bumps: state.bumps + MapSet.size(MapSet.difference(close, state.close)), close: close}
    end

    defp bumps(state, _sheep), do: state

    defp won(state, elapsed) do
      level = state.level
      stars = 1 + if(elapsed <= level.good, do: 1, else: 0) + if(state.size <= level.blocks, do: 1, else: 0)
      freeze(%{state | result: :won, stars: stars, elapsed: elapsed})
    end

    defp failed(state, reason), do: freeze(%{state | result: {:failed, reason}})

    defp freeze(%{space: space} = state) do
      :ok = :boids.set_time_scale(space, 0)
      state
    end

    defp report(%{level: level, last: last} = state) do
      readings =
        [["Time", "#{trunc(state.elapsed)} s"]] ++
          if(level[:need], do: [["In the pen", "#{last.penned} of #{state.total}"], ["Lost", last.lost]], else: []) ++
          if(level[:bumps], do: [["Bumps", state.bumps]], else: []) ++
          if(level[:flock], do: [["Flocks", last.flocks]], else: [])

      {result, text} =
        case state.result do
          :ready -> {"ready", "Build your program, then press Run."}
          :running -> {"running", "Your program runs."}
          :won -> {"won", praise(state)}
          {:failed, reason} -> {"failed", reason}
        end

      %{r: readings, x: %{level: level.n, state: result, stars: state.stars, text: text, time: trunc(state.elapsed)}}
    end

    defp praise(%{stars: 3}), do: "3 of 3 stars. Great program!"

    defp praise(%{stars: stars, level: level, size: size, elapsed: elapsed}) do
      tips =
        [
          elapsed > level.good && "Try to be faster: finish in #{level.good} seconds.",
          size > level.blocks &&
            "Try with #{level.blocks} #{if level.blocks == 1, do: "block", else: "blocks"} or fewer."
        ]
        |> Enum.filter(& &1)

      "#{stars} of 3 stars. " <> Enum.join(tips, " ")
    end

    defp now, do: System.monotonic_time(:millisecond)
  end

  # --- The scene -----------------------------------------------------------

  @impl true
  def waits, do: true

  # The page sends {"level": N, "blocks": [...]}, and "preview": true to
  # show the field before a try. A test also gives `manual: true`: then
  # the boids move only with boids:step/2.
  @impl true
  def start(%{"level" => n} = definition) when is_integer(n) do
    with level when level != nil <- level(n),
         {:ok, program} <- program(level, Map.get(definition, "blocks", [])) do
      preview = Map.get(definition, "preview") == true
      manual = Map.get(definition, :manual, false)
      {:ok, world(level, program, preview, manual)}
    else
      nil -> {:error, "There is no such level."}
      {:error, text} -> {:error, text}
    end
  end

  def start(_definition), do: {:error, "Choose a level."}

  defp world(level, program, preview, manual) do
    tick = if manual, do: :manual, else: BoidsSite.Scene.tick()

    {:ok, world} =
      :boids.start_world(bounds: {{0, 0}, {@width, @height}}, wrap: false, defaults: %{tick: tick})

    space = :boids.space(world)
    if preview, do: :ok = :boids.set_time_scale(space, 0)

    for {{x, y, radius}, id} <- Enum.with_index(Map.get(level, :rocks, [])) do
      :ok = :boids.set_obstacle(space, id, {x, y}, radius)
    end

    {x0, x1, y0, y1} = level.start
    combine = Map.get(level, :combine, :sum)
    perception = Map.get(level, :perception, 10)

    # The program of the player is for the sheep, or for the dog. In
    # level 8, the sheep have the rules of a herd.
    sheep =
      for n <- 1..level.sheep do
        team = if level[:teams], do: rem(n, 2), else: 0
        pos = place(team, x0, x1, y0, y1)

        {rules, others} =
          if level[:dog], do: {herd(level), []}, else: rules(level, program, flag(level, team))

        pen = if level.pens == [], do: nil, else: Enum.at(level.pens, team)
        state = %{rules: rules, others: others, mode: nil, pen: pen, penned: false}

        options = %{
          pos: pos,
          group: :sheep,
          data: {team, false},
          max_speed: 8,
          perception: perception,
          combine: combine,
          rules: rules,
          state: state
        }

        {:ok, pid} = :gen_boid.start(space, Sheep, options)
        pid
      end

    if level[:leader], do: leader(space, level, sheep)
    if level[:wolf], do: {:ok, _} = :gen_boid.start(space, Wolf, level.wolf)

    if level[:dog] do
      pen = hd(level.pens)
      {rules, _others} = rules(level, program, center(pen))
      options = %{pos: level.dog, group: :dog, max_speed: 12, perception: 90, rules: rules, state: %{pen: center(pen)}}
      {:ok, _} = :gen_boid.start(space, Dog, options)
    end

    size = if preview, do: :preview, else: size(program)
    {:ok, director} = Director.start(space, level, size, manual)
    %{space: space, world: world, director: director, level: level, program: program}
  end

  # The two teams of level 3 start at the two sides of the field.
  defp place(1, x0, x1, y0, y1), do: {@width - x1 + :rand.uniform() * (x1 - x0), y0 + :rand.uniform() * (y1 - y0)}
  defp place(_team, x0, x1, y0, y1), do: {x0 + :rand.uniform() * (x1 - x0), y0 + :rand.uniform() * (y1 - y0)}

  # In level 8, the sheep run from the dog, and stay together.
  defp herd(level) do
    [{:flee, 4, %{target: {:group, :dog}, radius: 20}}] ++
      fixed(level) ++ [{:separation, 2, %{radius: 3}}, {:cohesion, 3, %{}}, {:alignment, 1, %{}}]
  end

  # Level 7: the leader follows the way past the rocks, and each other
  # sheep has the relation follows to the leader.
  defp leader(space, level, sheep) do
    pen = hd(level.pens)
    rules = [@fence, {:avoid, 4, %{lookahead: 1.5}}, {:follow, 2, %{path: level.path}}]
    state = %{rules: rules, others: [], mode: nil, pen: pen, penned: false}
    options = %{pos: {14, 45}, group: :sheep, data: {:leader, false}, max_speed: 6, rules: rules, state: state}
    {:ok, leader} = :gen_boid.start(space, Sheep, options)
    leader_id = boid_id(space, leader)
    for pid <- sheep, do: :ok = :boids.relate(space, boid_id(space, pid), :follows, leader_id)
  end

  defp boid_id(space, pid) do
    %{id: id} = Enum.find(:boids.snapshot(space, :local), &(&1.pid == pid))
    id
  end

  @impl true
  def kinds(_scene) do
    [
      %{name: "sheep", shape: "dot", color: "ink", size: 1.6},
      %{name: "sheep in the pen", shape: "dot", color: "cool", size: 1.6},
      %{name: "brown sheep", shape: "dot", color: "warm", size: 1.6},
      %{name: "leader", shape: "hex", color: "cool", size: 1.7},
      %{name: "wolf", shape: "dart", color: "warm", size: 2.4},
      %{name: "dog", shape: "dart", color: "cool", size: 2.0}
    ]
  end

  # The pens, the level, the list of the levels and the code of the
  # program, for the page.
  @impl true
  def header(%{level: level, program: program}) do
    colors = ["cool", "warm"]
    pens = for {{x0, y0, x1, y1}, color} <- Enum.zip(level.pens, colors), do: [x0, y0, x1, y1, color]

    info = %{
      n: level.n,
      title: level.title,
      idea: level.idea,
      hint: level.hint,
      goal: level.goal,
      time: level.time,
      good: level.good,
      blocks: level.blocks,
      palette: for(name <- level.palette, do: %{name: name, label: Map.get(@blocks, name, "When I see")}),
      sees: Map.get(level, :sees, []),
      inside: Map.get(level, :inside, []),
      dog: Map.has_key?(level, :dog)
    }

    # The pens are two times in the list, so that they are darker on the page.
    %{
      zones: pens ++ pens,
      code: code(level, program),
      level: info,
      levels: for(%{n: n, title: title} <- levels(), do: %{n: n, title: title})
    }
  end

  @impl true
  def look(_scene, %{group: :wolf, vel: vel}), do: {4, BoidsSite.Scene.angle(vel), 0}
  def look(_scene, %{group: :dog, vel: vel}), do: {5, BoidsSite.Scene.angle(vel), 0}
  def look(_scene, %{data: {:leader, _}, vel: vel}), do: {3, BoidsSite.Scene.angle(vel), 0}
  def look(_scene, %{data: {_team, true}, vel: vel}), do: {1, BoidsSite.Scene.angle(vel), 0}
  def look(_scene, %{data: {1, false}, vel: vel}), do: {2, BoidsSite.Scene.angle(vel), 0}
  def look(_scene, %{vel: vel}), do: {0, BoidsSite.Scene.angle(vel), 0}

  @impl true
  def more(%{director: director}, _number), do: Director.status(director)
end
