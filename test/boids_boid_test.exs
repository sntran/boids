defmodule BoidsBoidTest do
  use ExUnit.Case, async: true
  use ExUnitProperties
  import Boids.Helpers

  @tau 2 * :math.pi()

  alias Boids.TestRules.{Mind, Push, Turn}

  defp boid(opts \\ %{}), do: :boids_boid.new(Map.merge(%{pos: {0, 0}, rules: []}, Map.new(opts)))

  # The state of a rule of a boid.
  defp state(boid, name) do
    {^name, _, _, state} = List.keyfind(boid.rules, name, 0)
    state
  end

  defp force!(boid, neighbors \\ [], env \\ %{dt: 0.1}), do: :boids_boid.force(boid, neighbors, env)

  # The force of one rule with the weight 1 and a large maximum.
  defp force(rule, opts, neighbors \\ [], env \\ %{}) do
    boid = boid(Map.merge(%{rules: [rule], max_force: 1.0e9}, Map.new(opts)))
    {force, _} = :boids_boid.force(boid, neighbors, env)
    force
  end

  describe "new/1" do
    test "gives the defaults" do
      boid = :boids_boid.new(%{pos: {1, 2}})

      assert %{
               pos: {1, 2},
               vel: {+0.0, +0.0},
               group: :default,
               data: :undefined,
               max_speed: 10.0,
               min_speed: min_speed,
               max_force: 20.0,
               mass: 1.0,
               perception: 10.0,
               fov: @tau,
               max_neighbors: :infinity,
               rules: [
                 {:separation, 1.5, %{}, :undefined},
                 {:alignment, 1.0, %{}, :undefined},
                 {:cohesion, 1.0, %{}, :undefined}
               ],
               combine: :sum
             } = boid

      refute is_map_key(boid, :stop)

      assert min_speed == 0
      assert is_reference(boid.id)
      assert :boids_boid.new(%{pos: {1, 2, 3}}).vel == {0.0, 0.0, 0.0}
    end

    test "accepts a list of options" do
      assert %{id: :a, pos: {1, 2}, max_speed: 3} = :boids_boid.new(id: :a, pos: {1, 2}, max_speed: 3)
    end

    test "keeps each option" do
      opts = %{
        id: {:bird, 1},
        pos: {1, 2, 3},
        vel: {0, 1, 0},
        group: :birds,
        data: %{color: :red},
        max_speed: 5,
        min_speed: 1,
        max_force: 2,
        mass: 3,
        perception: 20,
        fov: 3.0,
        max_neighbors: 7,
        combine: :priority,
        rules: []
      }

      assert :boids_boid.new(opts) == opts
    end

    test "refuses a bad option" do
      for {key, value} <- [
            pos: :here,
            pos: {1},
            pos: {1, :a},
            pos: {1, 2, :a},
            vel: {1, 2, 3},
            vel: 5,
            max_speed: -1,
            max_speed: :fast,
            min_speed: -1,
            min_speed: 11,
            max_force: -1,
            mass: 0,
            perception: -1,
            fov: -1,
            pos: {1.0e200, 0},
            vel: {0, -1.0e200},
            max_speed: 1.0e200,
            max_force: 1.0e200,
            perception: 1.0e200,
            mass: 1.0e200,
            max_neighbors: 0,
            max_neighbors: 1.5,
            combine: :mean,
            rules: :none,
            speed: 5
          ] do
        assert catch_error(:boids_boid.new(%{:pos => {0, 0}, key => value})) == {:bad_option, {key, value}}
      end
    end

    test "needs a position" do
      assert catch_error(:boids_boid.new(%{})) == {:bad_option, {:pos, :undefined}}
    end

    test "refuses options that are not a map or a list of pairs" do
      assert catch_error(:boids_boid.new(:fast)) == {:bad_option, :fast}
      assert catch_error(:boids_boid.new([:fast])) == {:bad_option, [:fast]}
    end
  end

  describe "the check of the rules" do
    test "a rule gets its options as a map" do
      rules = [{:seek, 2, target: {1, 2}}, {:wander, 0.5}, {:flee, 1, %{target: {:boid, :a}, radius: 5}}]

      assert boid(rules: rules).rules == [
               {:seek, 2, %{target: {1, 2}}, :undefined},
               {:wander, 0.5, %{}, :undefined},
               {:flee, 1, %{target: {:boid, :a}, radius: 5}, :undefined}
             ]
    end

    test "a rule that is a module starts with its arguments, and has its state" do
      rules = [{Push, 2}, {Push, 1, %{force: {3, 0}}}, {{Push, :up}, 1, {0, 5}}, {Turn, 1, :anything}]

      assert boid(rules: rules).rules == [
               {Push, 2, %{}, {0, 1}},
               {Push, 1, %{force: {3, 0}}, {3, 0}},
               {{Push, :up}, 1, {0, 5}, {0, 5}},
               {Turn, 1, :anything, {1, 0}}
             ]
    end

    test "accepts each rule with each of its options" do
      rules = [
        {:separation, 1, radius: 3, groups: :all},
        {:alignment, 1, radius: :infinity, groups: :same},
        {:cohesion, 1, radius: 3, groups: [:a, :b]},
        {:seek, 1, target: {1, 2}},
        {:flee, 1, target: {:group, :cats}, radius: :infinity},
        {:arrive, 1, target: {1, 2}, slow_radius: 4},
        {:pursue, 1, target: {:boid, 1}, max_time: 2},
        {:evade, 1, target: {:boid, 1}, max_time: :infinity, radius: 9},
        {:wander, 1, distance: 3, radius: 2, jitter: 1},
        {:avoid, 1, lookahead: 2, clearance: 1},
        {:contain, 1, bounds: {{0, 0}, {10, 10}}, margin: 2},
        {:follow, 1, path: [{0, 0}, {1, 1}], ahead: 2, predict: 0.1, loop: true},
        {fn _, _, _ -> {0, 0} end, 1},
        {:cruise, 1, speed: 3},
        {:leader, 1, target: {:boid, 1}, distance: 2, slow_radius: 3},
        {:dodge, 1, radius: 1, horizon: 3, groups: :all},
        {:flow, 1, field: {1, 0}},
        {:flow, 1, field: fn pos -> pos end, predict: 1},
        {{:seek, :home}, 1, target: {0, 0}},
        {{:flow, 2}, 1, field: {1, 0}},
        {Push, 1},
        {{Push, 2}, 1, {2, 2}},
        {Turn, 1, anything: :goes}
      ]

      assert length(boid(rules: rules).rules) == length(rules)
    end

    test "refuses a bad rule" do
      for rule <- [
            :separation,
            {:separation},
            {:separation, :strong},
            {:fly, 1},
            {:separation, 1, :near},
            {:separation, 1, [:near]},
            {:separation, 1, radius: -1},
            {:separation, 1, radius: :far},
            {:separation, 1, groups: :none},
            {:separation, 1, target: {1, 2}},
            {:seek, 1},
            {:seek, 1, target: :home},
            {:seek, 1, target: {1, :a}},
            {:seek, 1, target: {1, 2}, radius: 2},
            {:arrive, 1, target: {1, 2}, slow_radius: :infinity},
            {:pursue, 1, target: {:boid, 1}, max_time: -1},
            {:wander, 1, radius: :infinity},
            {:wander, 1, jitter: -1},
            {:avoid, 1, lookahead: :far},
            {:contain, 1, bounds: {{0, 0}, {1, 1, 1}}},
            {:contain, 1, bounds: :box},
            {:contain, 1, bounds: {{0, 0}, {:a, 1}}},
            {:follow, 1},
            {:follow, 1, path: []},
            {:follow, 1, path: [{0, 0}, :end]},
            {:follow, 1, path: {0, 0}},
            {:follow, 1, path: [{0, 0}], loop: :yes},
            {:follow, 1, path: [{0, 0}, {1, 1, 1}]},
            {:follow, 1, path: [{0, 0, 0}]},
            {:seek, 1, target: {1, 2, 3}},
            {:seek, 1, target: {1.0e200, 0}},
            {:contain, 1, bounds: {{0, 0, 0}, {1, 1, 1}}},
            {:contain, 1, bounds: {{0, 0}, {0, 1}}},
            {:arrive, 1, target: {1, 2}, slow_radius: 1.0e200},
            {fn _, _ -> {0, 0} end, 1},
            {fn _, _, _ -> {0, 0} end, 1, radius: 1},
            {{:boids_vec, :zero, []}, 1},
            {:lists, 1},
            {:no_such_module_of_rules, 1},
            {Push, 1, %{force: :up}},
            {Mind, 1, :refuse},
            {Mind, 1, :crash},
            {Mind, 1, :nonsense},
            {{:seek, :home}, 1},
            {{"seek", 1}, 1},
            {{:seek, :home, :again}, 1, target: {0, 0}},
            {:seek, 1, :home},
            {:seek, 1, [:home]},
            {:cruise, 1, speed: -1},
            {:leader, 1},
            {:leader, 1, target: {:boid, 1}, distance: :far},
            {:dodge, 1, radius: :infinity},
            {:dodge, 1, horizon: -1},
            {:flow, 1},
            {:flow, 1, field: fn a, b -> {a, b} end},
            {:flow, 1, field: {1, 0, 0}},
            {:flow, 1, field: :wind},
            {{:boids_vec, "zero", []}, 1},
            {"separation", 1}
          ] do
        assert {:bad_option, {:rules, _}} = catch_error(boid(rules: [rule])), "#{inspect(rule)} is accepted"
      end
    end
  end

  describe "options/1" do
    test "checks each option alone" do
      assert :boids_boid.options(vel: {0, 0, 1}, min_speed: 12, rules: [wander: 1]) ==
               %{vel: {0, 0, 1}, min_speed: 12, rules: [{:wander, 1, %{}}]}

      # No rule starts.
      assert :boids_boid.options(rules: [{Mind, 1, :crash}, {Push, 1}]) == %{
               rules: [{Mind, 1, :crash}, {Push, 1, %{}}]
             }

      assert :boids_boid.options(%{}) == %{}
      assert catch_error(:boids_boid.options(%{max_speed: -1})) == {:bad_option, {:max_speed, -1}}
      assert catch_error(:boids_boid.options(%{wings: 2})) == {:bad_option, {:wings, 2}}
      assert catch_error(:boids_boid.options(:fast)) == {:bad_option, :fast}
    end
  end

  describe "update/2" do
    test "changes options, and keeps the others" do
      boid = boid(id: :a, max_speed: 5)
      changed = :boids_boid.update(boid, %{pos: {5, 5}, group: :b, rules: [wander: 1]})
      assert %{id: :a, pos: {5, 5}, group: :b, max_speed: 5, rules: [{:wander, 1, %{}, :undefined}]} = changed
      assert :boids_boid.update(boid, max_speed: 6).max_speed == 6
    end

    test "keeps the rules with their states" do
      {_, moved} = force!(boid(rules: [{:wander, 1}, {Turn, 1}]))
      assert {_, _} = state(moved, :wander)
      assert state(moved, Turn) == {0, 1}
      assert :boids_boid.update(moved, %{max_speed: 2}).rules == moved.rules
    end

    test "the option rules gives all the rules again: a rule that is not in the new list stops" do
      boid = boid(rules: [{Mind, 1, %{owner: self()}}, {Turn, 1}, {:wander, 1}])
      {_, moved} = force!(boid)
      turn = List.keyfind(moved.rules, Turn, 0)
      # The rule Turn stays as it is in the boid, with its state.
      changed = :boids_boid.update(moved, %{rules: [turn, {Push, 1}, {:wander, 2}]})
      assert_received {:step, 1, _, _, _}
      assert_received {:terminated, :replaced, 1}
      assert [^turn, {Push, 1, %{}, {0, 1}}, {:wander, 2, %{}, :undefined}] = changed.rules
    end

    test "a rule that does not start stops the rules that started before it" do
      boid = boid(rules: [{Turn, 1}])
      rules = [{Mind, 1, %{owner: self()}}, {Mind, 1, :refuse}]

      assert catch_error(:boids_boid.update(boid, %{rules: rules})) ==
               {:bad_option, {:rules, {Mind, 1, :refuse}}}

      assert_received {:terminated, :replaced, 0}
      assert catch_error(boid(rules: rules)) == {:bad_option, {:rules, {Mind, 1, :refuse}}}
      assert_received {:terminated, :replaced, 0}
    end

    test "refuses a rule with a vector of another size" do
      boid = boid(pos: {0, 0, 0})
      rules = [{:seek, 1, target: {1, 2}}]

      assert catch_error(:boids_boid.update(boid, %{rules: rules})) ==
               {:bad_option, {:rules, {:seek, 1, %{target: {1, 2}}}}}

      assert %{rules: [_]} = :boids_boid.update(boid, %{rules: [{:seek, 1, target: {1, 2, 3}}]})
    end

    test "refuses a bad option, the id and the key stop" do
      boid = boid()
      assert catch_error(:boids_boid.update(boid, %{max_speed: -1})) == {:bad_option, {:max_speed, -1}}
      assert catch_error(:boids_boid.update(boid, %{vel: {1, 2, 3}})) == {:bad_option, {:vel, {1, 2, 3}}}
      assert catch_error(:boids_boid.update(boid, %{id: :b})) == {:bad_option, {:id, :b}}
      assert catch_error(:boids_boid.update(boid, %{stop: :now})) == {:bad_option, {:stop, :now}}
      assert catch_error(:boids_boid.update(boid, :faster)) == {:bad_option, :faster}
    end
  end

  test "entry/1 is the part that the other boids see" do
    boid = boid(id: :a, pos: {1, 2}, vel: {3, 4}, group: :g, data: 5)
    assert :boids_boid.entry(boid) == %{id: :a, pos: {1, 2}, vel: {3, 4}, group: :g, data: 5}
  end

  describe "perceive/2" do
    setup do
      pos = {0, 0}

      near = [
        neighbor(pos, {0, 0}, nil, %{id: :me}),
        neighbor(pos, {1, 0}, nil, %{id: :ahead}),
        neighbor(pos, {0, 2}, nil, %{id: :left}),
        neighbor(pos, {-3, 0}, nil, %{id: :behind}),
        neighbor(pos, {4, 4}, nil, %{id: :far})
      ]

      %{near: near}
    end

    test "a boid does not see itself", %{near: near} do
      seen = :boids_boid.perceive(boid(id: :me, vel: {1, 0}), near)
      assert Enum.map(seen, & &1.id) == [:ahead, :left, :behind, :far]
    end

    test "a boid sees only in its angle", %{near: near} do
      seen = :boids_boid.perceive(boid(id: :me, vel: {1, 0}, fov: 3.2), near)
      assert Enum.map(seen, & &1.id) == [:ahead, :left, :far]
      seen = :boids_boid.perceive(boid(id: :me, vel: {1, 0}, fov: 3.1), near)
      assert Enum.map(seen, & &1.id) == [:ahead, :far]
      seen = :boids_boid.perceive(boid(id: :me, vel: {1, 0}, fov: 0.1), near)
      assert Enum.map(seen, & &1.id) == [:ahead]
      seen = :boids_boid.perceive(boid(id: :me, vel: {-1, 0}, fov: 1), near)
      assert Enum.map(seen, & &1.id) == [:behind]
    end

    test "a boid at the same point is in each angle", %{near: near} do
      seen = :boids_boid.perceive(boid(id: :other, vel: {0, -1}, fov: 0.1), near)
      assert Enum.map(seen, & &1.id) == [:me]
    end

    test "a boid that does not move sees all around", %{near: near} do
      seen = :boids_boid.perceive(boid(id: :me, fov: 0.1), near)
      assert Enum.map(seen, & &1.id) == [:ahead, :left, :behind, :far]
    end

    test "a boid sees only its maximum number of neighbors", %{near: near} do
      seen = :boids_boid.perceive(boid(id: :me, vel: {1, 0}, max_neighbors: 2), near)
      assert Enum.map(seen, & &1.id) == [:ahead, :left]
    end
  end

  describe "the rules of a flock" do
    setup do
      pos = {0, 0}

      neighbors = [
        neighbor(pos, {2, 0}, {0, 3}, %{group: :default}),
        neighbor(pos, {0, 4}, {3, 0}, %{group: :other}),
        neighbor(pos, {-8, 0}, {0, -3}, %{group: :default})
      ]

      %{neighbors: neighbors, body: body(pos, {0.0, 0.0})}
    end

    test "separation uses all the groups, in half of the perception", %{neighbors: ns, body: body} do
      assert_vec(force({:separation, 1}, %{}, ns), :boids_steer.separation(body, Enum.take(ns, 2)))
    end

    test "separation with a radius and groups", %{neighbors: ns, body: body} do
      assert_vec(force({:separation, 1, radius: 3}, %{}, ns), :boids_steer.separation(body, Enum.take(ns, 1)))
      assert_vec(force({:separation, 1, radius: :infinity}, %{}, ns), :boids_steer.separation(body, ns))
      same = [Enum.at(ns, 0), Enum.at(ns, 2)]

      assert_vec(
        force({:separation, 1, radius: 9, groups: :same}, %{}, ns),
        :boids_steer.separation(body, same)
      )
    end

    test "alignment and cohesion use the group of the boid", %{neighbors: ns, body: body} do
      same = [Enum.at(ns, 0), Enum.at(ns, 2)]
      assert_vec(force({:alignment, 1}, %{}, ns), :boids_steer.alignment(body, same))
      assert_vec(force({:cohesion, 1}, %{}, ns), :boids_steer.cohesion(body, same))
    end

    test "alignment and cohesion with a radius and groups", %{neighbors: ns, body: body} do
      other = [Enum.at(ns, 1)]
      assert_vec(force({:alignment, 1, groups: [:other]}, %{}, ns), :boids_steer.alignment(body, other))

      assert_vec(
        force({:cohesion, 1, groups: :all, radius: 5}, %{}, ns),
        :boids_steer.cohesion(body, Enum.take(ns, 2))
      )

      assert force({:cohesion, 1, groups: []}, %{}, ns) == {0.0, 0.0}
    end

    test "the group of the boid changes its neighbors", %{neighbors: ns, body: body} do
      assert_vec(force({:alignment, 1}, %{group: :other}, ns), :boids_steer.alignment(body, [Enum.at(ns, 1)]))
    end
  end

  describe "the rules with a target" do
    test "a point" do
      body = body({0, 0}, {0.0, 0.0})
      assert force({:seek, 1, target: {5, 0}}, %{}) == :boids_steer.seek(body, {5, 0})
      assert force({:flee, 1, target: {5, 0}}, %{}) == :boids_steer.flee(body, {5, 0})
      assert force({:arrive, 1, target: {5, 0}}, %{}) == :boids_steer.arrive(body, {5, 0}, 10.0)

      assert force({:arrive, 1, target: {5, 0}, slow_radius: 20}, %{}) ==
               :boids_steer.arrive(body, {5, 0}, 20)

      assert force({:pursue, 1, target: {5, 0}}, %{}) == :boids_steer.seek(body, {5, 0})
      assert force({:evade, 1, target: {5, 0, 0}}, %{pos: {0, 0, 0}}) == {-10.0, 0.0, 0.0}
    end

    test "a target out of the radius of flee and evade gives no force" do
      assert force({:flee, 1, target: {5, 0}, radius: 4}, %{}) == {0.0, 0.0}
      assert force({:flee, 1, target: {5, 0}, radius: 5}, %{}) == {-10.0, 0.0}
      assert force({:evade, 1, target: {5, 0}, radius: 4}, %{}) == {0.0, 0.0}
      assert force({:evade, 1, target: {5, 0}, radius: 6}, %{}) == {-10.0, 0.0}
    end

    test "a boid that is a neighbor" do
      body = body({0, 0}, {0.0, 0.0})
      ns = [neighbor({0, 0}, {10, 0}, {0, 5}, %{id: :prey})]
      assert force({:seek, 1, target: {:boid, :prey}}, %{}, ns) == :boids_steer.seek(body, {10, 0})
      assert force({:pursue, 1, target: {:boid, :prey}}, %{}, ns) == :boids_steer.seek(body, {10.0, 5.0})

      assert force({:pursue, 1, target: {:boid, :prey}, max_time: 0.2}, %{}, ns) ==
               :boids_steer.seek(body, {10.0, 1.0})

      assert force({:evade, 1, target: {:boid, :prey}, max_time: 0.2}, %{}, ns) ==
               :boids_steer.flee(body, {10.0, 1.0})
    end

    test "a boid that is not a neighbor comes from the function lookup" do
      body = body({0, 0}, {0.0, 0.0})

      lookup = fn
        :prey -> {:ok, %{pos: {100, 0}, vel: {0, 5}}}
        _ -> :error
      end

      assert force({:pursue, 1, target: {:boid, :prey}, max_time: 1}, %{}, [], %{lookup: lookup}) ==
               :boids_steer.seek(body, {100.0, 5.0})

      assert force({:seek, 1, target: {:boid, :ghost}}, %{}, [], %{lookup: lookup}) == {0.0, 0.0}
      assert force({:seek, 1, target: {:boid, :prey}}, %{}, [], %{}) == {0.0, 0.0}
    end

    test "a boid is not its own target" do
      ns = [neighbor({0, 0}, {10, 0}, nil, %{id: :me})]
      lookup = fn _ -> {:ok, %{pos: {100, 0}, vel: {0, 5}}} end
      assert force({:seek, 1, target: {:boid, :me}}, %{id: :me}, ns, %{lookup: lookup}) == {0.0, 0.0}
    end

    test "the nearest neighbor of a group" do
      body = body({0, 0}, {0.0, 0.0})

      ns = [
        neighbor({0, 0}, {1, 0}, nil, %{group: :fish}),
        neighbor({0, 0}, {0, 3}, {1, 0}, %{group: :cats}),
        neighbor({0, 0}, {5, 0}, nil, %{group: :cats})
      ]

      assert force({:flee, 1, target: {:group, :cats}}, %{}, ns) == :boids_steer.flee(body, {0, 3})
      assert force({:pursue, 1, target: {:group, :fish}}, %{}, ns) == :boids_steer.seek(body, {1.0, 0.0})
      assert force({:flee, 1, target: {:group, :dogs}}, %{}, ns) == {0.0, 0.0}
    end

    test "with wrap, the target is at its nearest position" do
      env = %{wrap: true, bounds: {{0, 0}, {100, 100}}}
      opts = %{pos: {5, 50}}
      assert_vec(force({:seek, 1, target: {95, 50}}, opts, [], env), {-10.0, 0.0})
      assert_vec(force({:seek, 1, target: {95, 50}}, opts, [], %{}), {10.0, 0.0})
      lookup = fn :far -> {:ok, %{pos: {50, 98}, vel: {0, 0}}} end

      assert_vec(
        force({:seek, 1, target: {:boid, :far}}, %{pos: {50, 2}}, [], Map.put(env, :lookup, lookup)),
        {0.0, -10.0}
      )
    end
  end

  describe "wander" do
    test "keeps its point in the state of the rule" do
      :rand.seed(:exsss, 7)
      boid = boid(rules: [wander: 1], vel: {1, 0})
      {force, moved} = force!(boid)
      point = state(moved, :wander)
      assert_in_delta :boids_vec.norm(point), 1.0, 1.0e-9
      assert_vec(force, :boids_vec.limit(:boids_steer.wander(boid, point, 2.0, 1.0), 20.0))
      {_, again} = force!(moved)
      assert state(again, :wander) != point
      assert :boids_vec.dist(state(again, :wander), point) < 1.0
    end

    test "without time, the point stays" do
      boid = boid(rules: [wander: 1], pos: {0, 0, 0})
      {_, first} = :boids_boid.force(boid, [], %{})
      {_, second} = :boids_boid.force(first, [], %{dt: 0})
      assert tuple_size(state(first, :wander)) == 3
      assert state(second, :wander) == state(first, :wander)
    end

    test "uses its options" do
      :rand.seed(:exsss, 7)
      boid = boid(rules: [{:wander, 1, distance: 5, radius: 0, jitter: 0}], vel: {0, 2}, max_force: 100)
      {force, _} = :boids_boid.force(boid, [], %{dt: 0.1})
      assert_vec(force, {0.0, 8.0})
    end

    test "a point that the step moves to zero stays" do
      boid = boid(rules: [{:wander, 1, jitter: 1}])
      :rand.seed(:exsss, 3)
      opposite = :boids_vec.neg(:boids_vec.random_unit(2))
      :rand.seed(:exsss, 3)
      {_, moved} = :boids_boid.force(%{boid | rules: [{:wander, 1, %{jitter: 1}, opposite}]}, [], %{dt: 1})
      assert state(moved, :wander) == opposite
    end
  end

  describe "avoid, contain and follow" do
    test "avoid uses the obstacles of the environment" do
      obstacles = [%{id: :rock, pos: {10, 0}, radius: 2}]
      opts = %{pos: {0, 1}, vel: {5, 0}}
      body = body({0, 1}, {5, 0})

      assert force({:avoid, 1}, opts, [], %{obstacles: obstacles}) ==
               :boids_steer.avoid(body, obstacles, 5.0, 1.0)

      assert force({:avoid, 1, lookahead: 4, clearance: 0}, opts, [], %{obstacles: obstacles}) ==
               :boids_steer.avoid(body, obstacles, 20, 0)

      assert force({:avoid, 1}, opts, [], %{}) == {0.0, 0.0}
    end

    test "avoid does not see an obstacle with a center of another size" do
      obstacles = [%{id: :rock, pos: {10, 0, 0}, radius: 2}]
      assert force({:avoid, 1}, %{pos: {0, 1}, vel: {5, 0}}, [], %{obstacles: obstacles}) == {0.0, 0.0}
    end

    test "with wrap, avoid sees an obstacle across a side" do
      env = %{obstacles: [%{id: :rock, pos: {98, 50}, radius: 2}], wrap: true, bounds: {{0, 0}, {100, 100}}}
      {_, y} = force({:avoid, 1, lookahead: 4}, %{pos: {5, 51}, vel: {-5, 0}}, [], env)
      assert y > 0

      assert force({:avoid, 1, lookahead: 4}, %{pos: {5, 51}, vel: {-5, 0}}, [], %{env | wrap: false}) ==
               {0.0, 0.0}
    end

    test "contain uses the box of the environment, or its own box" do
      opts = %{pos: {1, 50}, vel: {-1, 0}}
      env = %{bounds: {{0, 0}, {100, 100}}}
      assert force({:contain, 1}, opts, [], env) == {11.0, 0.0}
      assert force({:contain, 1, margin: 0.5}, opts, [], env) == {0.0, 0.0}
      assert force({:contain, 1, bounds: {{2, 0}, {100, 100}}, margin: 0}, opts, [], env) == {11.0, 0.0}
      assert force({:contain, 1}, opts, [], %{}) == {0.0, 0.0}
      assert force({:contain, 1}, opts, [], %{bounds: :undefined}) == {0.0, 0.0}
    end

    test "follow uses its path" do
      path = [{0, 0}, {100, 0}]
      opts = %{pos: {2, 1}, vel: {2, 0}}
      body = body({2, 1}, {2, 0})
      assert force({:follow, 1, path: path}, opts) == :boids_steer.follow(body, path, 10.0, 0.5, false)

      assert force({:follow, 1, path: path, ahead: 3, predict: 0, loop: true}, opts) ==
               :boids_steer.follow(body, path, 3, 0, true)
    end
  end

  describe "cruise, leader, dodge and flow" do
    test "cruise keeps the maximum speed, or its speed" do
      opts = %{vel: {3, 4}}
      assert_vec(force({:cruise, 1}, opts), :boids_steer.cruise(body({0, 0}, {3, 4}), 10.0))
      assert_vec(force({:cruise, 1}, opts), {3.0, 4.0})
      assert_vec(force({:cruise, 1, speed: 2}, opts), {-1.8, -2.4})
    end

    test "leader uses the position and the velocity of its target" do
      body = body({0, 0}, {0.0, 0.0})
      ns = [neighbor({0, 0}, {10, 0}, {2, 0}, %{id: :first})]

      assert force({:leader, 1, target: {:boid, :first}}, %{}, ns) ==
               :boids_steer.leader(body, {10, 0}, {2, 0}, 5.0, 10.0)

      assert force({:leader, 1, target: {:boid, :first}, distance: 3, slow_radius: 4}, %{}, ns) ==
               :boids_steer.leader(body, {10, 0}, {2, 0}, 3, 4)

      assert force({:leader, 1, target: {:boid, :nobody}}, %{}, ns) == {0.0, 0.0}
    end

    test "dodge uses its groups, and all the neighbors that the boid sees" do
      body = body({0, 0}, {1, 0})
      near = neighbor({0, 0}, {8, 0.5}, {-1, 0}, %{group: :cars})
      far = neighbor({0, 0}, {9, -0.5}, {-1, 0}, %{group: :default})
      opts = %{vel: {1, 0}}
      assert force({:dodge, 1}, opts, [near, far]) == :boids_steer.dodge(body, [near, far], 2.5, 2.0)

      assert force({:dodge, 1, radius: 1, horizon: 9}, opts, [near, far]) ==
               :boids_steer.dodge(body, [near, far], 1, 9)

      assert force({:dodge, 1, horizon: 9, groups: :same}, opts, [near, far]) ==
               :boids_steer.dodge(body, [far], 2.5, 9)

      assert force({:dodge, 1, horizon: 9, groups: [:cars]}, opts, [near, far]) ==
               :boids_steer.dodge(body, [near], 2.5, 9)
    end

    test "flow uses a vector, or a function of the position after the time of the prediction" do
      assert_vec(force({:flow, 1, field: {0, 2}}, %{vel: {1, 0}}), {-1.0, 10.0})
      turn = fn {x, y} -> {-y, x} end
      assert_vec(force({:flow, 1, field: turn}, %{pos: {1, 0}}), {0.0, 10.0})
      assert_vec(force({:flow, 1, field: turn}, %{pos: {0, 0}, vel: {2, 0}}), {-2.0, 10.0})
      assert_vec(force({:flow, 1, field: turn, predict: 0}, %{pos: {0, 3}, vel: {2, 0}}), {-12.0, 0.0})
    end
  end

  describe "a rule of your own" do
    test "a function gets the boid, the neighbors and the environment" do
      me = self()

      rule = fn boid, neighbors, env ->
        send(me, {boid.id, neighbors, env})
        {1, 2}
      end

      assert force({rule, 1}, %{id: :a}, [:n], %{dt: 0.5, more: 1}) == {1, 2}
      assert_received {:a, [:n], %{dt: 0.5, more: 1}}
    end

    test "a module gives its force at each step, and keeps its state" do
      boid = boid(rules: [{Push, 2}, {Push, 1, {3, 0}}, {Turn, 1}], max_force: 100)
      {first, boid} = force!(boid)
      {second, boid} = force!(boid)
      {third, _} = force!(boid)
      # Push gives {0, 1} with the weight 2, then {3, 0}. Turn gives {1, 0}, {0, 1}, {-1, 0}.
      assert {first, second, third} == {{4.0, 2.0}, {3.0, 3.0}, {2.0, 2.0}}
    end

    test "a module gets the boid, the neighbors and the environment" do
      boid = boid(pos: {4, 5}, rules: [{Mind, 1, %{owner: self()}}])
      assert {{+0.0, +0.0}, moved} = :boids_boid.force(boid, [:a, :b], %{dt: 0.5, more: 1})
      assert_received {:step, 1, {4, 5}, 2, %{dt: 0.5, more: 1}}
      assert state(moved, Mind).steps == 1
    end

    test "a module can give a force and no force" do
      plan = %{1 => {:force, {2, 0}}, 3 => {:force, {0, 3}, []}}
      boid = boid(rules: [{Mind, 2, %{plan: plan}}], max_force: 100)
      {first, boid} = force!(boid)
      {second, boid} = force!(boid)
      {third, _} = force!(boid)
      assert {first, second, third} == {{4.0, 0.0}, {0.0, 0.0}, {0.0, 6.0}}
    end

    test "a rule can remove itself" do
      boid = boid(rules: [{Mind, 1, %{owner: self(), plan: %{2 => :remove_rule}}}, {Push, 1}])
      {_, boid} = force!(boid)
      assert :boids_boid.which_rules(boid) == [Mind, Push]
      {force, boid} = force!(boid)
      assert force == {0.0, 1.0}
      assert :boids_boid.which_rules(boid) == [Push]
      assert_received {:terminated, :remove_rule, 1}
    end
  end

  describe "the actions of a rule" do
    test "change options of the boid" do
      plan = %{1 => {:actions, [{:set, %{max_speed: 3, data: :fast}}, {:set, group: :b}]}}
      {_, boid} = force!(boid(rules: [{Mind, 1, %{plan: plan}}]))
      assert %{max_speed: 3, data: :fast, group: :b} = boid
    end

    test "add rules and remove rules, after all the rules of the step" do
      actions = [
        {:delete_rule, Push},
        {:delete_rule, :wander, :bye},
        {:delete_rule, :nobody},
        {:add_rule, {{Push, :new}, 1, {5, 0}}},
        {:add_rule, {:cruise, 1}}
      ]

      plan = %{1 => {:force, {1, 0}, actions}}
      boid = boid(rules: [{Mind, 1, %{plan: plan}}, {Push, 1}, {:wander, 0}], max_force: 100)
      # The force of the step has the rule that the action removes.
      assert {{1.0, 1.0}, boid} = force!(boid)
      assert :boids_boid.which_rules(boid) == [Mind, {Push, :new}, :cruise]
      assert {{5.0, +0.0}, _} = force!(boid)
    end

    test "ask to stop the boid" do
      {_, stopped} = force!(boid(rules: [{Mind, 1, %{plan: %{1 => {:actions, [:stop]}}}}]))
      assert stopped.stop == :normal
      {_, stopped} = force!(boid(rules: [{Mind, 1, %{plan: %{1 => {:actions, [{:stop, :eaten}]}}}}]))
      assert stopped.stop == :eaten

      assert :boids_boid.step(boid(rules: [{Mind, 1, %{plan: %{1 => {:actions, [:stop]}}}}]), [], %{}, 0.1).stop ==
               :normal
    end

    test "a boid that a rule asked to stop keeps that in a change of its options" do
      {_, stopped} = force!(boid(rules: [{Mind, 1, %{plan: %{1 => {:actions, [{:stop, :eaten}]}}}}]))
      assert :boids_boid.update(stopped, %{max_speed: 1}).stop == :eaten
    end

    test "a bad action is an error of the boid" do
      for {action, reason} <- [
            {:fly, {:bad_action, :fly}},
            {{:set, %{max_speed: -1}}, {:bad_option, {:max_speed, -1}}},
            {{:add_rule, {:fly, 1}},
             {:bad_action, {:add_rule, {:fly, 1}}, {:bad_option, {:rules, {:fly, 1, %{}}}}}},
            {{:add_rule, {Mind, 1, :refuse}}, {:bad_action, {:add_rule, {Mind, 1, :refuse}}, :refused}}
          ] do
        boid = boid(rules: [{Mind, 1, %{plan: %{1 => {:actions, [action]}}}}])
        assert catch_error(force!(boid)) == reason
      end
    end
  end

  describe "a rule that fails" do
    @describetag :capture_log

    test "is removed from the boid, and the other rules continue" do
      for {result, reason} <- [
            {:crash, %RuntimeError{message: "a fault of a rule"}},
            {:throw, :a_fault},
            {:nonsense, {:bad_return, :nonsense}},
            {{:force, :up}, {:bad_force, :up}},
            {{:force, {1, 2, 3}}, {:bad_force, {1, 2, 3}}},
            {{:force, {1, 0}, :later},
             {:bad_return, {:force, {1, 0}, %{owner: self(), steps: 1, plan: %{}}, :later}}},
            {{:actions, :later}, {:bad_return, {:ok, %{owner: self(), steps: 1, plan: %{}}, :later}}}
          ] do
        boid = boid(rules: [{Mind, 1, %{owner: self(), plan: %{1 => result}}}, {Push, 1}])
        assert {{+0.0, 1.0}, boid} = force!(boid)
        assert :boids_boid.which_rules(boid) == [Push]
        assert_received {:terminated, {:error, error}, 0}

        case {reason, error} do
          {{:bad_return, {tag, a, state, b}}, {:bad_return, {tag, a, got, b}}} ->
            assert Map.take(got, [:owner]) == Map.take(state, [:owner])

          {{:bad_return, {tag, state, b}}, {:bad_return, {tag, got, b}}} ->
            assert Map.take(got, [:owner]) == Map.take(state, [:owner])

          _ ->
            assert error == reason
        end
      end
    end

    test "the log has the rule, the boid and the reason" do
      log =
        ExUnit.CaptureLog.capture_log(fn ->
          force!(boid(id: :bird, rules: [{{Mind, :first}, 1, %{plan: %{1 => :throw}}}]))
        end)

      assert log =~ "boids: the rule "
      assert log =~ "Mind"
      assert log =~ "of the boid "
      assert log =~ "bird"
      assert log =~ "failed, and the boid has it no more"
      assert log =~ "a_fault"
    end

    test "a function that fails is removed too" do
      bad = fn _, _, _ -> raise "a fault of a function" end
      wrong = fn _, _, _ -> :up end
      assert {{+0.0, 1.0}, boid} = force!(boid(rules: [{bad, 1}, {wrong, 1}, {Push, 1}]))
      assert :boids_boid.which_rules(boid) == [Push]
    end

    test "an error of terminate/2 after a fault changes nothing" do
      plan = %{1 => :crash}
      boid = boid(rules: [{Mind, 1, %{plan: plan}}])
      crashes = %{boid | rules: [{Mind, 1, %{}, %{owner: nil, steps: 0, plan: plan, last: :crash}}]}
      assert {_, %{rules: []}} = force!(crashes)
    end

    test "an exit of a rule is an exit of the process" do
      boid = boid(rules: [{Mind, 1, %{plan: %{1 => :exit}}}])
      assert catch_exit(force!(boid)) == :a_fault
    end
  end

  describe "add_rule/2, delete_rule/3 and which_rules/1" do
    test "add a rule at the end, and start a module" do
      boid = boid(rules: [{:wander, 1}])
      assert {:ok, boid} = :boids_boid.add_rule(boid, {:seek, 2, target: {1, 1}})
      assert {:ok, boid} = :boids_boid.add_rule(boid, {{Push, :a}, 1, {1, 0}})
      assert {:ok, boid} = :boids_boid.add_rule(boid, {Turn, 3})
      assert :boids_boid.which_rules(boid) == [:wander, :seek, {Push, :a}, Turn]
      assert List.last(boid.rules) == {Turn, 3, %{}, {1, 0}}
      # A rule as it is in a boid is added with its state.
      assert {:ok, %{rules: [_, _, _, _, {Turn, 1, %{}, {0, 1}}]}} =
               :boids_boid.add_rule(boid, {Turn, 1, %{}, {0, 1}})
    end

    test "refuse a bad rule, and a module that does not start" do
      boid = boid()
      assert :boids_boid.add_rule(boid, {:fly, 1}) == {:error, {:bad_option, {:rules, {:fly, 1, %{}}}}}

      assert :boids_boid.add_rule(boid, {:seek, 1, target: {1, 2, 3}}) ==
               {:error, {:bad_option, {:rules, {:seek, 1, [target: {1, 2, 3}]}}}}

      assert :boids_boid.add_rule(boid, {Mind, 1, :refuse}) == {:error, :refused}
      assert {:error, %RuntimeError{}} = :boids_boid.add_rule(boid, {Mind, 1, :crash})
      assert :boids_boid.add_rule(boid, {Mind, 1, :nonsense}) == {:error, {:bad_return, :nonsense}}
    end

    test "remove the first rule with a name, and stop a module" do
      boid = boid(rules: [{:wander, 1}, {Mind, 1, %{owner: self()}}, {Push, 1}, {:wander, 2}])
      assert {:ok, :ok, boid} = :boids_boid.delete_rule(boid, :wander, [])
      assert :boids_boid.which_rules(boid) == [Mind, Push, :wander]
      assert {:ok, {:ended, 0}, boid} = :boids_boid.delete_rule(boid, Mind, :done)
      assert_received {:terminated, :done, 0}
      # A module with no terminate/2.
      assert {:ok, :ok, boid} = :boids_boid.delete_rule(boid, Push, :done)
      assert :boids_boid.which_rules(boid) == [:wander]
      assert :boids_boid.delete_rule(boid, Push, :done) == {:error, :not_found}
    end
  end

  describe "call_rule/3" do
    test "gives the answer of the module, which sees the boid" do
      boid = boid(pos: {3, 4}, rules: [{Mind, 1}, {{Mind, 2}, 1, %{steps: 7}}])
      assert {{3, 4}, ^boid} = :boids_boid.call_rule(boid, Mind, :where)
      assert {7, ^boid} = :boids_boid.call_rule(boid, {Mind, 2}, :steps)
      assert {:ok, changed} = :boids_boid.call_rule(boid, Mind, {:plan, %{1 => :remove_rule}})
      assert state(changed, Mind).plan == %{1 => :remove_rule}
    end

    test "the answer can have actions" do
      boid = boid(rules: [{Mind, 1}])

      assert {:done, changed} =
               :boids_boid.call_rule(boid, Mind, {:actions, [{:set, %{data: 1}}, {:stop, :asked}]})

      assert %{data: 1, stop: :asked} = changed
    end

    test "the rule can remove itself" do
      boid = boid(rules: [{Mind, 1, %{owner: self()}}])
      assert {:bye, %{rules: []}} = :boids_boid.call_rule(boid, Mind, :leave)
      assert_received {:terminated, :remove_rule, 0}
    end

    test "a boid with no such rule, or a rule with no handle_call/3" do
      boid = boid(rules: [{Push, 1}, {:wander, 1}])
      assert :boids_boid.call_rule(boid, Mind, :steps) == {{:error, :bad_rule}, boid}
      assert :boids_boid.call_rule(boid, Push, :steps) == {{:error, :bad_rule}, boid}
      assert :boids_boid.call_rule(boid, :wander, :steps) == {{:error, :bad_rule}, boid}
    end

    @tag :capture_log
    test "a rule that fails is removed" do
      boid = boid(rules: [{Mind, 1, %{owner: self()}}])
      assert {{:error, {:failed, %RuntimeError{}}}, %{rules: []}} = :boids_boid.call_rule(boid, Mind, :crash)
      assert_received {:terminated, {:error, %RuntimeError{}}, 0}

      assert {{:error, {:failed, {:bad_return, :nonsense}}}, %{rules: []}} =
               :boids_boid.call_rule(boid, Mind, :nonsense)
    end
  end

  describe "info/2" do
    test "gives a message to each module with handle_info/3" do
      boid = boid(rules: [{Mind, 1}, {Push, 1}, {:wander, 1}, {{Mind, 2}, 1, %{steps: 10}}])
      told = :boids_boid.info(boid, {:count, 5})
      assert state(told, Mind).steps == 5
      assert state(told, {Mind, 2}).steps == 15
      assert :boids_boid.info(boid, :hello) == boid
    end

    test "a rule can have actions, and can remove itself" do
      boid = boid(rules: [{Mind, 1, %{owner: self()}}, {{Mind, 2}, 1}])
      told = :boids_boid.info(boid, {:actions, [{:set, %{data: 1}}]})
      assert told.data == 1
      left = :boids_boid.info(boid, :leave)
      assert left.rules == []
      assert_received {:terminated, :remove_rule, 0}
    end

    @tag :capture_log
    test "a rule that fails is removed" do
      boid = boid(rules: [{Mind, 1, %{owner: self()}}, {Push, 1}])
      assert :boids_boid.which_rules(:boids_boid.info(boid, :crash)) == [Push]
      assert_received {:terminated, {:error, %RuntimeError{}}, 0}
      assert :boids_boid.which_rules(:boids_boid.info(boid, :nonsense)) == [Push]
    end
  end

  test "terminate/2 stops each rule that is a module" do
    boid =
      boid(
        rules: [
          {Mind, 1, %{owner: self()}},
          {Push, 1},
          {:wander, 1},
          {{Mind, 2}, 1, %{owner: self(), steps: 3}}
        ]
      )

    assert :boids_boid.terminate(boid, {:stop, :normal}) == :ok
    assert_received {:terminated, {:stop, :normal}, 0}
    assert_received {:terminated, {:stop, :normal}, 3}
  end

  describe "the sum of the forces" do
    test "each force is multiplied by its weight" do
      rules = [{:seek, 0.5, target: {10, 0}}, {:seek, 2, target: {0, 10}}]
      assert_vec(force(rules |> hd(), %{}), {5.0, 0.0})
      {force, _} = :boids_boid.force(boid(rules: rules, max_force: 100), [], %{})
      assert_vec(force, {5.0, 20.0})
    end

    test "the sum has the length of the maximum force at most" do
      rules = [{:seek, 1, target: {10, 0}}, {:seek, 1, target: {0, 10}}]
      {force, _} = :boids_boid.force(boid(rules: rules, max_force: 5), [], %{})
      assert_vec(force, :boids_vec.set_norm({1, 1}, 5))
    end

    test "no rule gives no force" do
      boid = boid(id: :a)
      assert :boids_boid.force(boid, [], %{}) == {{0.0, 0.0}, boid}
      {force, _} = :boids_boid.force(boid(pos: {0, 0, 0}), [], %{})
      assert force == {0.0, 0.0, 0.0}
    end

    test "with priority, the first rules use the force first" do
      rules = [{:seek, 1, target: {10, 0}}, {:seek, 1, target: {0, 10}}]
      {force, _} = :boids_boid.force(boid(rules: rules, max_force: 15, combine: :priority), [], %{})
      assert_vec(force, {10.0, 5.0})
      {force, _} = :boids_boid.force(boid(rules: rules, max_force: 10, combine: :priority), [], %{})
      assert_vec(force, {10.0, 0.0})
      {force, _} = :boids_boid.force(boid(rules: rules, max_force: 4, combine: :priority), [], %{})
      assert_vec(force, {4.0, 0.0})
      {force, _} = :boids_boid.force(boid(rules: rules, max_force: 100, combine: :priority), [], %{})
      assert_vec(force, {10.0, 10.0})
    end

    property "the force has the length of the maximum force at most" do
      check all(
              combine <- member_of([:sum, :priority]),
              max_force <- float(min: 0.0, max: 50.0),
              pos <- vec(2, 50.0),
              vel <- vec(2, 5.0),
              targets <- list_of(vec(2, 50.0), max_length: 5),
              others <- list_of(tuple({vec(2, 50.0), vec(2, 5.0)}), max_length: 8)
            ) do
        rules =
          [{:separation, 1.5}, {:alignment, 1.0}, {:cohesion, 1.0}, {:avoid, 2.0}, {:contain, 1.0}] ++
            for(target <- targets, do: {:seek, 1.0, target: target})

        boid = boid(pos: pos, vel: vel, max_speed: 7.07, rules: rules, max_force: max_force, combine: combine)
        neighbors = for {other, velocity} <- others, do: neighbor(pos, other, velocity)
        env = %{obstacles: [%{id: 1, pos: {0, 0}, radius: 5}], bounds: {{-40, -40}, {40, 40}}}
        {force, _} = :boids_boid.force(boid, neighbors, env)
        assert :boids_vec.norm(force) <= max_force + 1.0e-9
      end
    end
  end

  describe "integrate/4" do
    test "the force changes the velocity, and the velocity changes the position" do
      boid = boid(pos: {1, 1}, vel: {2, 0})
      moved = :boids_boid.integrate(boid, {0, 4}, %{}, 0.5)
      assert_vec(moved.vel, {2.0, 2.0})
      assert_vec(moved.pos, {2.0, 2.0})
    end

    test "the mass divides the force" do
      moved = :boids_boid.integrate(boid(mass: 4, pos: {0, 0, 0}), {8, 0, 0}, %{}, 1)
      assert_vec(moved.vel, {2.0, 0.0, 0.0})
    end

    test "the speed stays in its limits" do
      fast = :boids_boid.integrate(boid(vel: {9, 0}), {100, 0}, %{}, 1)
      assert_vec(fast.vel, {10.0, 0.0})
      assert_vec(fast.pos, {10.0, 0.0})
      slow = :boids_boid.integrate(boid(vel: {3, 0}, min_speed: 2), {-2, 0}, %{}, 1)
      assert_vec(slow.vel, {2.0, 0.0})
      stopped = :boids_boid.integrate(boid(vel: {3, 0}, min_speed: 2), {-3, 0}, %{}, 1)
      assert_vec(stopped.vel, {0.0, 0.0})
    end

    test "no time changes nothing" do
      boid = boid(vel: {3, 0})
      assert :boids_boid.integrate(boid, {5, 5}, %{}, 0) == boid
      assert :boids_boid.integrate(boid, {5, 5}, %{}, -1) == boid
    end

    test "with wrap, the position stays in the box" do
      env = %{wrap: true, bounds: {{0, 0}, {10, 10}}}
      moved = :boids_boid.integrate(boid(pos: {9, 1}, vel: {4, -4}), {0, 0}, env, 0.5)
      assert_vec(moved.pos, {1.0, 9.0})

      free =
        :boids_boid.integrate(
          boid(pos: {9, 1}, vel: {4, -4}),
          {0, 0},
          %{wrap: false, bounds: {{0, 0}, {10, 10}}},
          0.5
        )

      assert_vec(free.pos, {11.0, -1.0})
    end

    property "the speed is the maximum speed at most" do
      check all(
              d <- dim(),
              pos <- vec(d),
              vel <- vec(d, 20.0),
              force <- vec(d),
              max_speed <- float(min: 0.0, max: 30.0),
              dt <- float(min: 0.001, max: 2.0)
            ) do
        moved = :boids_boid.integrate(boid(pos: pos, vel: vel, max_speed: max_speed), force, %{}, dt)
        assert :boids_vec.norm(moved.vel) <= max_speed + 1.0e-6
        assert_vec(moved.pos, :boids_vec.add(pos, :boids_vec.scale(moved.vel, dt)), 1.0e-6)
      end
    end
  end

  describe "step/4" do
    test "is the force of the rules, then the movement" do
      boid = boid(rules: [{:seek, 1, target: {100, 0}}], max_force: 4)
      moved = :boids_boid.step(boid, [], %{}, 0.5)
      assert_vec(moved.vel, {2.0, 0.0})
      assert_vec(moved.pos, {1.0, 0.0})
    end

    test "gives the time of the step to the rules" do
      me = self()

      rule = fn _, _, env ->
        send(me, env)
        {0, 0}
      end

      :boids_boid.step(boid(rules: [{rule, 1}]), [], %{wrap: false}, 0.25)
      assert_received %{dt: 0.25, wrap: false}
    end

    test "no time changes nothing" do
      boid = boid(rules: [wander: 1], vel: {1, 1})
      assert :boids_boid.step(boid, [], %{}, 0) == boid
      assert :boids_boid.step(boid, [], %{}, -0.5) == boid
    end

    test "a boid arrives at its target, and stops there" do
      boid = boid(rules: [{:arrive, 1, target: {30, 40}}], max_force: 50)
      arrived = Enum.reduce(1..400, boid, fn _, b -> :boids_boid.step(b, [], %{}, 0.05) end)
      assert_vec(arrived.pos, {30.0, 40.0}, 0.01)
      assert :boids_vec.norm(arrived.vel) < 0.01
    end

    test "with cruise, a boid gets its speed and keeps it" do
      boid = boid(vel: {0.1, 0}, rules: [{:cruise, 1, speed: 6}])
      moved = Enum.reduce(1..200, boid, fn _, b -> :boids_boid.step(b, [], %{}, 0.05) end)
      assert_vec(moved.vel, {6.0, 0.0}, 0.01)
    end

    test "with leader, a boid stays behind its leader" do
      rules = [{:leader, 1, target: {:boid, :first}, distance: 4, slow_radius: 5}]
      follower = boid(pos: {0, 5}, rules: rules, max_force: 40)

      {follower, at} =
        Enum.reduce(1..400, {follower, {10, 0}}, fn _, {b, at} ->
          first = neighbor(b.pos, at, {3, 0}, %{id: :first})
          {:boids_boid.step(b, [first], %{}, 0.05), :boids_vec.add(at, {0.15, 0})}
        end)

      # A boid that arrives at a point that moves stays a little behind it.
      assert_vec(follower.pos, :boids_vec.sub(at, {4, 0}), 2.0)
      assert_vec(follower.vel, {3.0, 0.0}, 0.5)
    end

    test "with dodge, two boids that come at each other do not hit" do
      nearest = fn rules ->
        a = boid(id: :a, pos: {0, 0.2}, vel: {5, 0}, rules: rules, max_force: 30)
        b = boid(id: :b, pos: {40, -0.2}, vel: {-5, 0}, rules: rules, max_force: 30)

        {_, _, nearest} =
          Enum.reduce(1..120, {a, b, 1.0e9}, fn _, {a, b, nearest} ->
            see = fn me, other -> [neighbor(me.pos, other.pos, other.vel, %{id: other.id})] end
            a1 = :boids_boid.step(a, see.(a, b), %{}, 0.05)
            b1 = :boids_boid.step(b, see.(b, a), %{}, 0.05)
            {a1, b1, min(nearest, :boids_vec.dist(a1.pos, b1.pos))}
          end)

        nearest
      end

      assert nearest.([{:cruise, 1, speed: 5}]) < 0.5
      assert nearest.([{:dodge, 3, radius: 3, horizon: 3}, {:cruise, 1, speed: 5}]) > 2.0
    end

    test "with flow, a boid goes around the circle of a field" do
      # The field turns around the center, and goes to the circle of the radius 10.
      field = fn {x, y} ->
        radius = :math.sqrt(x * x + y * y)
        to_circle = 3 * (10 - radius) / radius
        {-y + to_circle * x, x + to_circle * y}
      end

      boid = boid(pos: {14, 0}, rules: [{:flow, 1, field: field, predict: 0.1}], max_speed: 5, max_force: 50)

      {places, _} =
        Enum.map_reduce(1..700, boid, fn _, b ->
          next = :boids_boid.step(b, [], %{}, 0.02)
          {next.pos, next}
        end)

      # 70 units of way: more than one time around the circle.
      for pos <- Enum.drop(places, 100), do: assert_in_delta(:boids_vec.norm(pos), 10.0, 2.0)
      assert Enum.any?(places, fn {x, _} -> x < -9 end)
      assert Enum.any?(places, fn {_, y} -> y < -9 end)
    end

    test "a boid follows a path to its end" do
      path = [{0, 0}, {30, 0}, {30, 30}]
      boid = boid(rules: [{:follow, 1, path: path, ahead: 5}], max_force: 40)

      {arrived, far} =
        Enum.reduce(1..400, {boid, 0.0}, fn _, {b, far} ->
          next = :boids_boid.step(b, [], %{}, 0.05)
          {x, y} = next.pos
          # The distance from the path.
          {next, max(far, min(abs(y) + max(x - 30, 0), abs(x - 30) + max(-y, 0)))}
        end)

      assert_vec(arrived.pos, {30.0, 30.0}, 0.05)
      # The boid cuts the corner, because it goes to a point 5 units ahead.
      assert far < 4.0
    end
  end
end
