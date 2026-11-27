defmodule BoidsExamples.LabTest do
  # Flock Lab: the levels, the programs of the player, the stars, and the
  # code of a program. The tests move the boids with a manual clock
  # (boids:step/2), so a level of 40 seconds takes a few seconds.
  use ExUnit.Case, async: true
  alias BoidsExamples.Games.FlockLab, as: Lab

  @dt 0.05

  defp b(name, power), do: %{"block" => name, "power" => power}
  defp w(what, inner), do: %{"when" => what, "do" => inner}

  # Start a level with a manual clock. The world stops at the end of the
  # test.
  defp start(n, blocks, more \\ %{}) do
    scene = begin(n, blocks, more)
    on_exit(fn -> :boids.stop_world(scene.space) end)
    scene
  end

  defp begin(n, blocks, more \\ %{}) do
    {:ok, scene} = Lab.start(Map.merge(%{"level" => n, "blocks" => blocks, manual: true}, more))
    scene
  end

  # A try of a level in a process of its own: start, run, and stop.
  defp try_level(n, blocks) do
    scene = begin(n, blocks)
    status = run(scene)
    :boids.stop_world(scene.space)
    status
  end

  # Run a level to its result, or to `max` seconds.
  defp run(scene, max \\ 60), do: run(scene, 1, max)

  defp run(scene, step, max) do
    :ok = :boids.step(scene.space, @dt)
    status = Lab.Director.observe(scene.director, step * @dt)

    case status.x.state do
      "running" when step * @dt < max -> run(scene, step + 1, max)
      _ -> status
    end
  end

  # A level is a simulation: the sheep start at random places. A good
  # program wins in almost each try. The test gives it two tries.
  defp best(n, blocks) do
    first = try_level(n, blocks)
    if first.x.state == "won" and first.x.stars == 3, do: first, else: try_level(n, blocks)
  end

  defp three,
    do: %{
      1 => [b("flag", 3)],
      2 => [b("flag", 5)],
      3 => [b("flag", 3), b("space", 3)],
      4 => [b("friends", 3), b("wander", 2)],
      5 => [b("rocks", 5), b("flag", 3)],
      6 => [b("flag", 3), w("wolf", [b("wolf", 5)])],
      7 => [b("leader", 4)],
      8 => [b("behind", 3)]
    }

  test "each level has a program with 3 stars" do
    results =
      Task.async_stream(three(), fn {n, blocks} -> {n, best(n, blocks)} end, timeout: :infinity, ordered: false)
      |> Enum.map(fn {:ok, result} -> result end)

    for {n, status} <- results do
      assert status.x.state == "won", "level #{n}: #{status.x.text}"
      assert status.x.stars == 3, "level #{n}: #{status.x.text}"
      assert status.x.text == "3 of 3 stars. Great program!"
    end
  end

  test "an empty program does not win a level" do
    results =
      Task.async_stream(Lab.levels(), fn %{n: n} -> {n, try_level(n, [])} end, timeout: :infinity, ordered: false)
      |> Enum.map(fn {:ok, result} -> result end)

    for {n, status} <- results do
      assert status.x.state == "failed", "level #{n}"
      assert status.x.text =~ "Time is up"
    end
  end

  test "more blocks than the level asks give fewer stars, with a tip" do
    status = run(start(1, [b("flag", 3), b("wander", 1)]))
    assert %{state: "won", stars: 2} = status.x
    assert status.x.text == "2 of 3 stars. Try with 1 block or fewer."
  end

  test "a slow program gives fewer stars, with a tip" do
    # Against the wind of level 2, a weak flag is slow.
    status = run(start(2, [b("flag", 3)]))
    assert %{state: "won", stars: 2} = status.x
    assert status.x.text =~ "Try to be faster: finish in 25 seconds."
  end

  test "a program with too many bumps fails" do
    status = run(start(3, [b("flag", 3)]))
    assert status.x.state == "failed"
    assert status.x.text =~ "Too many bumps"
    assert ["Bumps", bumps] = List.last(status.r)
    assert bumps > 3
  end

  test "the order of the blocks changes the result of level 5" do
    first = run(start(5, [b("rocks", 4), b("flag", 2)]))
    assert first.x.state == "won"
    # Without "Walk around rocks", the sheep go into the rocks.
    second = run(start(5, [b("flag", 2)]))
    assert second.x.state == "failed"
    assert second.x.text =~ "Too many sheep are lost"
  end

  test "a When I see block changes the rules of a sheep that sees the wolf" do
    scene = start(6, [b("flag", 3), w("wolf", [b("wolf", 5)])])
    sheep = for %{group: :sheep, pid: pid} <- :boids.snapshot(scene.space, :local), do: pid
    assert Enum.all?(sheep, &(:gen_boid.which_rules(&1) == [:contain, :seek]))

    seen =
      Enum.find_value(1..400, fn step ->
        :ok = :boids.step(scene.space, @dt)
        Lab.Director.observe(scene.director, step * @dt)
        alive = for pid <- sheep, Process.alive?(pid), do: pid

        Enum.find(alive, fn pid ->
          try do
            :gen_boid.which_rules(pid) == [:contain, :flee]
          catch
            :exit, _ -> false
          end
        end)
      end)

    assert seen != nil
  end

  test "the leader of level 7 has the relation follows from each other sheep" do
    scene = start(7, [b("leader", 3)])
    rows = :boids.snapshot(scene.space, :local)
    [leader] = for %{data: {:leader, false}, id: id} <- rows, do: id
    others = for %{group: :sheep, data: {0, false}, id: id} <- rows, do: id
    assert length(others) == 9
    for id <- others, do: assert(:boids.related(scene.space, id, :follows) == [leader])
  end

  test "a sheep in the pen stays in the pen" do
    scene = start(1, [b("flag", 4)])
    status = run(scene)
    assert status.x.state == "won"

    for %{group: :sheep, data: data, pos: {x, y}} <- :boids.snapshot(scene.space, :local) do
      assert data == {0, true}
      assert x >= 136 and x <= 158 and y >= 28 and y <= 62
    end
  end

  test "a preview shows the level, and the boids do not move" do
    scene = start(1, [b("flag", 3)], %{"preview" => true})
    before = for %{pos: pos} <- :boids.snapshot(scene.space, :local), do: pos

    for step <- 1..20 do
      :ok = :boids.step(scene.space, @dt)
      Lab.Director.observe(scene.director, step * @dt)
    end

    after_ = for %{pos: pos} <- :boids.snapshot(scene.space, :local), do: pos
    assert before == after_
    status = Lab.Director.observe(scene.director, 1.0)
    assert status.x.state == "ready"
    assert status.x.text == "Build your program, then press Run."
  end

  test "a bad program or a bad level is refused with a text for the player" do
    bad = fn definition ->
      assert {:error, text} = Lab.start(definition)
      text
    end

    assert bad.(%{"level" => 9, "blocks" => []}) == "There is no such level."
    assert bad.(%{"blocks" => []}) == "Choose a level."
    assert bad.(%{"level" => "1", "blocks" => []}) == "Choose a level."
    assert bad.(%{"level" => 1, "blocks" => "flag"}) == "The program is a list of blocks."
    assert bad.(%{"level" => 1, "blocks" => [b("wolf", 3)]}) =~ "This level has no block"
    assert bad.(%{"level" => 1, "blocks" => [b("fly", 3)]}) =~ "This level has no block"
    assert bad.(%{"level" => 1, "blocks" => [b("flag", 0)]}) == "A strength is from 1 to 5."
    assert bad.(%{"level" => 1, "blocks" => [b("flag", 6)]}) == "A strength is from 1 to 5."
    assert bad.(%{"level" => 1, "blocks" => [b("flag", "3")]}) == "A strength is from 1 to 5."
    assert bad.(%{"level" => 1, "blocks" => [%{"code" => "x"}]}) =~ "A block is not right"
    assert bad.(%{"level" => 1, "blocks" => [b("flag", 3), b("flag", 2)]}) =~ "the same block two times"
    assert bad.(%{"level" => 1, "blocks" => List.duplicate(b("wander", 1), 9)}) == "A program has 8 blocks at most."
    assert bad.(%{"level" => 1, "blocks" => [w("wolf", [b("flag", 3)])]}) =~ "no block \"When I see\""
    assert bad.(%{"level" => 6, "blocks" => [w("dog", [b("flag", 3)])]}) =~ "can not see that"
    assert bad.(%{"level" => 6, "blocks" => [w("wolf", [w("wolf", [])])]}) =~ "can not be in another one"
    assert bad.(%{"level" => 6, "blocks" => [w("wolf", List.duplicate(b("flag", 1), 5))]}) =~ "4 blocks at most"
    # In level 6, "Run from the wolf" goes only in a "When I see" block.
    assert bad.(%{"level" => 6, "blocks" => [b("wolf", 3)]}) ==
             "Put the block \"Run from the wolf\" inside a \"When I see\" block."
  end

  test "the code of a program is the rules of the server, in Erlang and in Elixir" do
    blocks = [b("flag", 3), b("friends", 2), w("wolf", [b("wolf", 5), b("space", 2)])]
    scene = start(6, blocks)
    %{code: %{erlang: erlang, elixir: elixir}} = Lab.header(scene)
    [sheep | _] = for %{group: :sheep, id: id} <- :boids.snapshot(scene.space, :local), do: id
    {:ok, boid} = :boids.boid(scene.space, sheep)

    # Erlang: Rules = [...]. When = [...].
    {rules, others} = eval_erlang(erlang)
    assert normalize(rules) == boid.rules
    assert normalize(rules) == normalize(boid.state.rules)
    assert [{:wolf, when_rules}] = others
    assert [{:wolf, server_when}] = boid.state.others
    assert normalize(when_rules) == normalize(server_when)

    # Elixir: rules = [...] when = [...]
    {elixir_rules, elixir_binding} = Code.eval_string(elixir)
    assert normalize(elixir_binding[:rules]) == boid.rules
    assert elixir_binding[:when_i_see] == others
    assert elixir_rules == others

    # The comments name the blocks.
    assert erlang =~ "%% Go to the flag"
    assert elixir =~ "# Stay with friends"
    assert erlang =~ "%% the level adds this"
  end

  test "the code of the dog has its function rule" do
    scene = start(8, [b("behind", 3), b("pen", 1)])
    %{code: %{erlang: erlang, elixir: elixir}} = Lab.header(scene)
    assert erlang =~ "%% The rules of the dog."
    assert elixir =~ "&BoidsExamples.Games.FlockLab.behind/3"
    [dog] = for %{group: :dog, id: id} <- :boids.snapshot(scene.space, :local), do: id
    {:ok, boid} = :boids.boid(scene.space, dog)
    {rules, []} = eval_erlang(erlang)
    assert normalize(rules) == boid.rules
  end

  test "the header has the level, the levels and the pens, for the page" do
    scene = start(3, [b("flag", 3)])
    header = Lab.header(scene)
    assert header.level.title == "Two teams"
    assert Enum.map(header.level.palette, & &1.name) == ~w(flag space friends wander)
    assert hd(header.level.palette).label == "Go to the flag"
    assert length(header.levels) == 8
    assert [[136, 25, 158, 65, "cool", "Pen"], [2, 25, 24, 65, "warm", "Brown pen"]] = header.zones
    assert header.ground == "grass"
    assert length(Lab.kinds(scene)) == 6
    assert BoidsExamples.Scene.waits?(Lab)
    assert is_binary(IO.iodata_to_binary(:json.encode(header)))
  end

  test "the readings and the kinds of the boids" do
    scene = start(3, [b("space", 4), b("flag", 2)])
    status = run(scene, 2)
    assert [["Time", _], ["In the pen", "0 of 14"], ["Lost", 0], ["Bumps", _]] = status.r
    kinds = for row <- :boids.snapshot(scene.space, :local), do: elem(Lab.look(scene, row), 0)
    assert Enum.sort(Enum.uniq(kinds)) == [0, 2]

    scene = start(6, [b("flag", 3)])
    kinds = for row <- :boids.snapshot(scene.space, :local), do: elem(Lab.look(scene, row), 0)
    assert 4 in kinds

    scene = start(7, [b("leader", 3)])
    kinds = for row <- :boids.snapshot(scene.space, :local), do: elem(Lab.look(scene, row), 0)
    assert 3 in kinds

    scene = start(8, [b("behind", 3)])
    kinds = for row <- :boids.snapshot(scene.space, :local), do: elem(Lab.look(scene, row), 0)
    assert 5 in kinds
  end

  test "a scene of the site runs with the clock, and the director stops with its world" do
    {:ok, scene} = Lab.start(%{"level" => 4, "blocks" => [b("friends", 3), b("align", 2)]})
    status = Lab.more(scene, 1)
    assert status.x.state in ["running", "won"]
    assert [["Time", _], ["Flocks", _]] = status.r
    ref = Process.monitor(scene.director)
    :boids.stop_world(scene.space)
    assert_receive {:DOWN, ^ref, :process, _, :normal}, 2000
  end

  # Evaluate the Erlang code of a program: the variables Rules and When.
  defp eval_erlang(text) do
    clean = text |> String.split("\n") |> Enum.map_join("\n", &String.replace(&1, ~r/%%.*$/, ""))
    # The two statements become one sequence of expressions.
    clean = String.replace(clean, ~r/\]\.(\s*)When/, "],\\1When")
    {:ok, tokens, _} = :erl_scan.string(String.to_charlist(clean))
    {:ok, expressions} = :erl_parse.parse_exprs(tokens)
    {:value, _value, binding} = :erl_eval.exprs(expressions, :erl_eval.new_bindings())
    {:value, rules} = :erl_eval.binding(:Rules, binding)
    {rules, when_of(binding)}
  end

  defp when_of(binding) do
    case :erl_eval.binding(:When, binding) do
      {:value, value} -> value
      :unbound -> []
    end
  end

  # The library keeps each rule as {Name, Weight, Options}.
  defp normalize(rules), do: for(rule <- rules, do: if(tuple_size(rule) == 2, do: Tuple.append(rule, %{}), else: rule))
end
