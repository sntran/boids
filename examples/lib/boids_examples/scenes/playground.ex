defmodule BoidsExamples.Scenes.Playground do
  @moduledoc """
  The scene of the playground: a world with the boids of the
  definition of a visitor.

  A definition is data (JSON), and not code: the site runs no code of a
  visitor. It has the box, the rocks, and the kinds of boids. Each kind
  has its number of boids, its options, and its rules. A kind can have
  other rules when its boids see a boid of a group (`when`), and its
  boids can follow each other in a chain (`follows`).

      {"box": [160, 90], "wrap": true, "rocks": [[40, 60, 7]],
       "kinds": [
         {"name": "birds", "count": 60, "speed": [6, 12],
          "rules": [["separation", 1.5, {"radius": 3}], ["alignment", 1], ["cohesion", 1]],
          "when": [{"sees": "hawks", "rules": [["evade", 3, {"target": "hawks"}]]}]}
       ]}

  The names of the rules and of their options are those of `boids_boid`.
  A target is a point `[X, Y]`, the name of a group, or `"leader"` (the
  boid that this boid follows).
  """
  @behaviour BoidsExamples.Scene

  @impl true
  def waits, do: true

  defmodule Kind do
    @moduledoc "A boid of a kind of the playground: it changes its rules when it sees a boid of a group."
    @behaviour :gen_boid

    @impl true
    def init(options), do: {:ok, options}

    @impl true
    def handle_decide(_seen, %{state: %{others: []}} = boid), do: {:ok, boid}

    def handle_decide(%{neighbors: neighbors}, %{state: %{rules: rules, others: others, mode: mode} = state} = boid) do
      groups = MapSet.new(neighbors, & &1.group)

      case Enum.find_index(others, fn {group, _rules} -> group in groups end) do
        ^mode ->
          {:ok, boid}

        new ->
          now = if new, do: elem(Enum.at(others, new), 1), else: rules
          {:ok, %{:boids_boid.update(boid, %{rules: now}) | state: %{state | mode: new}}}
      end
    end
  end

  # The names that a definition can have. A name of a visitor never
  # becomes an atom.
  @rules ~w(separation alignment cohesion seek flee arrive pursue evade wander avoid contain follow cruise leader dodge flow)
  @options ~w(radius groups target lookahead clearance margin speed distance slow_radius max_time horizon jitter path loop ahead predict field)
  @shapes ~w(dart dot hex rock)
  @colors ~w(ink warm cool rock)

  @impl true
  def start(definition) do
    {:ok, build(definition)}
  catch
    {:bad, text} -> {:error, text}
  end

  defp build(%{"kinds" => kinds} = definition) when is_list(kinds) and kinds != [] do
    limit = String.to_integer(System.get_env("BOIDS_MAX", "120"))
    {width, height} = box(Map.get(definition, "box", [160, 90]))
    kinds = kinds |> check(length(kinds) <= 6, "A scene has 6 kinds at most.") |> Enum.with_index() |> Enum.map(&kind/1)
    total = Enum.sum(for kind <- kinds, do: kind.count)
    check(nil, total <= limit, "A scene has #{limit} boids at most, and this one has #{total}.")
    rocks = for rock <- Map.get(definition, "rocks", []), do: rock(rock)
    check(nil, length(rocks) <= 8, "A scene has 8 rocks at most.")

    # The library checks the options and the rules of each kind.
    for kind <- kinds, rules <- [kind.rules | for({_group, rules} <- kind.others, do: rules)] do
      try do
        # The options of the process (search) are not options of a boid.
        {_process, options} = :gen_boid.options(kind.options)
        :boids_boid.new(Map.merge(options, %{pos: {0, 0}, rules: rules}))
      catch
        :error, {:bad_option, {key, value}} ->
          throw({:bad, "The kind #{kind.name} has a bad #{key}: #{inspect(value)}"})
      end
    end

    {:ok, world} =
      :boids.start_world(
        bounds: {{0, 0}, {width, height}},
        wrap: Map.get(definition, "wrap", true) == true,
        defaults: %{tick: BoidsExamples.Scene.tick()}
      )

    space = :boids.space(world)
    for {{x, y, radius}, number} <- Enum.with_index(rocks), do: :ok = :boids.set_obstacle(space, number, {x, y}, radius)

    for kind <- kinds do
      ids =
        for _ <- 1..kind.count//1 do
          pos = {:rand.uniform() * width, :rand.uniform() * height}
          state = %{rules: kind.rules, others: kind.others, mode: nil}
          # A relation needs the id of a boid, which is not its process.
          id = make_ref()
          options = Map.merge(kind.options, %{id: id, pos: pos, vel: velocity(kind), rules: kind.rules, state: state})
          {:ok, _} = :gen_boid.start(space, Kind, options)
          id
        end

      # A chain: each boid follows the boid before it.
      if kind.chain do
        for {from, to} <- Enum.zip(tl(ids), ids), do: :ok = :boids.relate(space, from, :follows, to)
      end
    end

    %{space: space, kinds: kinds}
  end

  defp build(_definition), do: throw({:bad, "A scene needs a list of kinds."})

  defp velocity(%{options: %{min_speed: slow, max_speed: fast}}) do
    :boids_vec.scale(:boids_vec.random_unit(2), slow + :rand.uniform() * (fast - slow))
  end

  # --- The definition of a visitor ----------------------------------------

  defp box([width, height]) when is_number(width) and is_number(height) do
    check(
      {width, height},
      width >= 40 and width <= 400 and height >= 40 and height <= 400,
      "The sides of the box are from 40 to 400."
    )
  end

  defp box(_other), do: throw({:bad, "The box is [WIDTH, HEIGHT]."})

  defp rock([x, y, radius]) when is_number(x) and is_number(y) and is_number(radius) and radius > 0, do: {x, y, radius}
  defp rock(_other), do: throw({:bad, "A rock is [X, Y, RADIUS]."})

  defp kind({%{"name" => name} = kind, number}) when is_binary(name) do
    count = Map.get(kind, "count", 1)
    check(nil, is_integer(count) and count >= 1, "The count of the kind #{name} is a number of 1 or more.")

    [slow, fast] =
      case Map.get(kind, "speed", [0, 10]) do
        [slow, fast] when is_number(slow) and is_number(fast) -> [slow, fast]
        fast when is_number(fast) -> [0, fast]
        _ -> throw({:bad, "The speed of the kind #{name} is [MINIMUM, MAXIMUM]."})
      end

    options =
      %{group: name, data: number, min_speed: slow, max_speed: fast}
      |> put(kind, "perception", :perception)
      |> put(kind, "max_force", :max_force)
      |> put(kind, "mass", :mass)
      |> put(kind, "fov", :fov)
      |> put(kind, "search", :search)
      |> Map.merge(if Map.get(kind, "combine") == "priority", do: %{combine: :priority}, else: %{})

    %{
      name: name,
      count: count,
      options: options,
      rules: rules(name, Map.get(kind, "rules", [])),
      others: for(other <- Map.get(kind, "when", []), do: other(name, other)),
      chain: Map.get(kind, "follows") == "chain",
      shape: one_of(Map.get(kind, "shape", "dart"), @shapes, "shape"),
      color: one_of(Map.get(kind, "color", Enum.at(@colors, rem(number, 3))), @colors, "color"),
      size: Map.get(kind, "size", 1.3)
    }
  end

  defp kind(_other), do: throw({:bad, "Each kind needs a name."})

  defp put(options, kind, key, option) do
    case kind do
      %{^key => value} -> Map.put(options, option, value)
      _ -> options
    end
  end

  defp other(_name, %{"sees" => group, "rules" => rules}) when is_binary(group), do: {group, rules(group, rules)}

  defp other(name, _other),
    do: throw({:bad, "A part of \"when\" of the kind #{name} is {\"sees\": GROUP, \"rules\": RULES}."})

  defp rules(name, rules) when is_list(rules), do: Enum.map(rules, &rule(name, &1))
  defp rules(name, _other), do: throw({:bad, "The rules of the kind #{name} are a list."})

  defp rule(name, [rule, weight]), do: rule(name, [rule, weight, %{}])

  defp rule(name, [rule, weight, options]) when is_binary(rule) and is_number(weight) and is_map(options) do
    check(nil, rule in @rules, "The kind #{name} has the rule #{rule}, which is not a rule of the library.")
    {String.to_existing_atom(rule), weight, Map.new(options, &option(name, rule, &1))}
  end

  defp rule(name, _other), do: throw({:bad, "A rule of the kind #{name} is [NAME, WEIGHT] or [NAME, WEIGHT, OPTIONS]."})

  defp option(name, rule, {key, value}) do
    check(
      nil,
      key in @options,
      "The rule #{rule} of the kind #{name} has the option #{key}, which is not an option of the library."
    )

    {String.to_existing_atom(key), value(key, value)}
  end

  defp value("target", "leader"), do: {:related, :follows}
  defp value("target", group) when is_binary(group), do: {:group, group}
  defp value(key, [x, y]) when key in ["target", "field"] and is_number(x) and is_number(y), do: {x, y}
  defp value("path", points) when is_list(points), do: for([x, y] <- points, do: {x, y})
  defp value("groups", "all"), do: :all
  defp value("groups", "same"), do: :same
  defp value(_key, value), do: value

  defp one_of(value, values, what),
    do: check(value, value in values, "A #{what} is one of: #{Enum.join(values, ", ")}.")

  defp check(value, true, _text), do: value
  defp check(_value, false, text), do: throw({:bad, text})

  # --- The scene ---------------------------------------------------------

  @impl true
  def kinds(%{kinds: kinds}), do: for(kind <- kinds, do: Map.take(kind, [:name, :shape, :color, :size]))

  @impl true
  def look(_scene, %{data: number, vel: vel}), do: {number, BoidsExamples.Scene.angle(vel), 1}

  # Each second: the number of boids, and of flocks (the groups of boids
  # that see each other).
  @impl true
  def more(%{space: space}, number) do
    if rem(number * BoidsExamples.Scene.tick(), 1000) < BoidsExamples.Scene.tick() do
      %{r: [["Boids", :boids.count(space)], ["Flocks", length(:boids.flocks(space, 8))]]}
    else
      %{}
    end
  end
end
