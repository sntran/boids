defmodule BoidsExamples.Games.HiveGuardTest do
  # The rules of Hive Guard: the waves, the beetles on the path, the
  # stings of the bees, the nectar, the lives of the hive, and the inputs
  # of the person.
  use ExUnit.Case, async: false
  alias BoidsExamples.Games.HiveGuard
  alias BoidsExamples.Games.HiveGuard.Director
  alias BoidsExamples.Scene

  # Start a game in a process of its own: the game stops with that
  # process. The options go to the director.
  defp game(options) do
    test = self()

    visitor =
      spawn(fn ->
        send(test, {:started, Scene.start(HiveGuard, options)})
        Process.sleep(:infinity)
      end)

    assert_receive {:started, {:ok, scene}}, 10_000

    # At the end of the test, the scene stops with its visitor. The test
    # waits for the end of its world, so that the next test counts no
    # scene of this test.
    on_exit(fn ->
      ref = Process.monitor(scene.guard)
      Process.exit(visitor, :kill)

      receive do
        {:DOWN, ^ref, :process, _pid, _reason} -> :ok
      after
        5000 -> :ok
      end
    end)

    {visitor, scene}
  end

  # Wait until the state of the director agrees with a function, for 30
  # seconds at most. The result is that state.
  defp until(scene, check, tries \\ 300) do
    state = Director.state(scene.director)

    cond do
      check.(state) -> state
      tries == 0 -> flunk("The game did not come to the state. Last state: #{inspect(Map.drop(state, [:space]))}")
      true -> Process.sleep(100) && until(scene, check, tries - 1)
    end
  end

  defp group(scene, group), do: for(row = %{group: ^group} <- :boids.snapshot(scene.space), do: row)

  defp place(scene, kind, {x, y}), do: HiveGuard.input(scene, %{"place" => [x, y], "kind" => kind})

  test "the waves get larger, and have large beetles from the wave 2" do
    assert HiveGuard.wave(1) == List.duplicate({:small, 2}, 6)
    assert {:large, 12} in HiveGuard.wave(2)
    sizes = for n <- 1..20, do: length(HiveGuard.wave(n))
    assert sizes == Enum.sort(sizes)
    # A wave has 32 beetles at most, so the world has 60 boids at most.
    assert Enum.max(sizes) == 32
    assert HiveGuard.bonus(3) > HiveGuard.bonus(1)
    assert HiveGuard.bounty(:large) > HiveGuard.bounty(:small)
  end

  test "the zones are the path, the hive and the posts of the bees" do
    path = HiveGuard.zones()
    assert length(path) == length(HiveGuard.path())
    assert List.last(path) |> Enum.at(4) == "warm"
    [post] = HiveGuard.zones([{:scout, {20.0, 30.0}}]) -- path
    assert post == [18.5, 28.5, 21.5, 31.5, "cool"]
  end

  test "with no bee, the beetles walk along the path to the hive and take its lives" do
    {_visitor, scene} = game(%{scale: 5.0, build: 0.2, seed: 1, bees: []})
    state = until(scene, &(&1.phase == :wave and map_size(&1.alive) > 0))
    assert state.wave == 1
    assert [_ | _] = group(scene, :beetles)

    # The 6 beetles of the wave 1 take 6 lives. The hive survived the wave.
    state = until(scene, &(&1.done == 1))
    assert state.lives == 4 and state.leaked == 6 and state.kills == 0
    assert state.nectar == 80 + HiveGuard.bonus(1)

    # The beetles of the wave 2 take the last lives: the game is over, and
    # its beetles go.
    state = until(scene, &(&1.phase == :over))
    assert state.lives <= 0 and state.done == 1
    Process.sleep(200)
    assert group(scene, :beetles) == []
    assert %{x: %{phase: :over}} = HiveGuard.more(scene, 1)
  end

  test "a sting takes health from a beetle, and a killed beetle gives nectar" do
    {_visitor, scene} = game(%{build: 1000.0, every: 0.05, seed: 2, bees: []})
    HiveGuard.input(scene, %{"go" => true})
    until(scene, &(&1.queue == [] and map_size(&1.alive) == 6))
    [%{id: id, data: {:small, 2}} | _] = group(scene, :beetles)
    pid = :boids.whereis(scene.space, id)

    :gen_boid.cast(pid, {:sting, 1})
    Process.sleep(100)
    assert {:ok, %{data: {:small, 1}}} = :boids.lookup(scene.space, id)

    ref = Process.monitor(pid)
    :gen_boid.cast(pid, {:sting, 1})
    assert_receive {:DOWN, ^ref, :process, ^pid, :normal}, 2000
    state = until(scene, &(&1.kills == 1))
    assert state.nectar == 80 + HiveGuard.bounty(:small)
    assert map_size(state.alive) == 5
  end

  test "a bee pursues the beetles that it sees, stings them, and goes back to its post" do
    {_visitor, scene} = game(%{scale: 3.0, build: 1000.0, nectar: 200, seed: 3, bees: []})
    place(scene, "soldier", {44, 66})
    place(scene, "soldier", {36, 28})
    until(scene, &(length(&1.guards) == 2))
    [%{id: bee} | _] = group(scene, :guards)
    assert {:ok, %{state: %{mode: :home, kind: :soldier}}} = :boids.boid(scene.space, bee)

    HiveGuard.input(scene, %{"go" => true})
    state = until(scene, &(&1.kills >= 3))
    assert state.nectar >= 200 - 100 + 3 * HiveGuard.bounty(:small)

    # A bee that stung rests, and does not go farther than its leash.
    stings = for %{id: id} <- group(scene, :guards), {:ok, boid} = :boids.boid(scene.space, id), do: boid.state.stings
    assert Enum.sum(stings) >= 3

    for %{id: id, pos: pos} <- group(scene, :guards) do
      {:ok, %{state: %{post: post, kind: kind}}} = :boids.boid(scene.space, id)
      assert :boids_vec.dist(pos, post) <= HiveGuard.guards()[kind].leash + 6
    end
  end

  test "a bee changes its rules: arrive at its post, pursue a beetle that it sees" do
    {_visitor, scene} = game(%{build: 1000.0, nectar: 100, bees: []})
    place(scene, "scout", {20, 72})
    until(scene, &(length(&1.guards) == 1))
    [%{id: bee}] = group(scene, :guards)
    assert :gen_boid.which_rules(:boids.whereis(scene.space, bee)) == [:arrive, :wander, :separation]
    assert HiveGuard.Guard.rules(:hunt, {0, 0}) |> hd() |> elem(0) == :pursue

    # A beetle near the bee: the bee hunts it.
    HiveGuard.input(scene, %{"go" => true})

    assert Enum.any?(1..100, fn _ ->
             Process.sleep(100)
             :gen_boid.which_rules(:boids.whereis(scene.space, bee)) == [:pursue, :separation]
           end)
  end

  test "the person places bees with nectar, in the field, and 12 at most" do
    {_visitor, scene} = game(%{build: 1000.0, nectar: 1000, bees: []})
    place(scene, "scout", {10, 10})
    place(scene, "soldier", {30, 10})
    state = until(scene, &(length(&1.guards) == 2))
    assert state.nectar == 1000 - 25 - 50
    assert [{:scout, {10.0, 10.0}}, {:soldier, {30.0, 10.0}}] == state.guards

    # Inputs that change nothing: a bad kind, a place out of the field or
    # on the hive, a bad message.
    place(scene, "queen", {50, 10})
    place(scene, "scout", {-5, 10})
    place(scene, "scout", {50, 200})
    {hx, hy} = HiveGuard.hive()
    place(scene, "scout", {hx, hy})
    HiveGuard.input(scene, %{"place" => ["a", 1], "kind" => "scout"})
    HiveGuard.input(scene, %{"other" => 1})
    HiveGuard.input(scene, "text")
    assert length(Director.state(scene.director).guards) == 2

    for n <- 1..12, do: place(scene, "scout", {10 + 8 * n, 50})
    state = until(scene, &(length(&1.guards) == 12))
    Process.sleep(200)
    assert length(Director.state(scene.director).guards) == 12
    assert length(group(scene, :guards)) == 12
    assert state.nectar == 1000 - 25 - 50 - 10 * 25

    # The posts are zones of the page.
    %{h: %{zones: zones}, r: readings, x: x} = HiveGuard.more(scene, 1)
    assert length(zones) == length(HiveGuard.zones()) + 12
    assert ["Nectar", 675] in readings
    assert x.guards == 12 and x.max_guards == 12
  end

  test "with too little nectar, no bee comes" do
    {_visitor, scene} = game(%{build: 1000.0, nectar: 40, bees: []})
    place(scene, "soldier", {10, 10})
    place(scene, "scout", {20, 10})
    state = until(scene, &(length(&1.guards) == 1))
    assert state.guards == [{:scout, {20.0, 10.0}}] and state.nectar == 15
  end

  test "Next wave now starts the wave, and Start again starts a new game" do
    {_visitor, scene} = game(%{build: 1000.0, lives: 1, every: 0.05, scale: 5.0, nectar: 100, bees: []})
    place(scene, "scout", {10, 10})
    assert %{phase: :building, wave: 0} = until(scene, &(length(&1.guards) == 1))
    HiveGuard.input(scene, %{"go" => true})
    assert %{wave: 1} = until(scene, &(&1.phase == :wave))
    # Go in a wave changes nothing.
    HiveGuard.input(scene, %{"go" => true})
    state = until(scene, &(&1.phase == :over))
    assert state.wave == 1 and state.done == 0
    # No bee in a game that is over.
    place(scene, "scout", {20, 20})
    Process.sleep(100)
    assert length(Director.state(scene.director).guards) == 1

    HiveGuard.input(scene, %{"go" => true})
    state = until(scene, &(&1.phase == :building and &1.guards == []))
    assert state.wave == 0 and state.lives == 1 and state.nectar == 100 and state.kills == 0
    Process.sleep(200)
    assert :boids.snapshot(scene.space) == []
  end

  test "a game starts with one free scout that hovers at its post, and Start again gives it again" do
    {_visitor, scene} = game(%{build: 1000.0, lives: 1, every: 0.05, scale: 5.0})
    state = until(scene, &(length(&1.guards) == 1))
    assert state.guards == [{:scout, {44.0, 66.0}}] and state.nectar == 80
    [%{id: bee, pos: first}] = group(scene, :guards)

    # The scout hovers: it moves a little, near its post.
    assert Enum.any?(1..50, fn _ ->
             Process.sleep(100)
             {:ok, %{pos: pos}} = :boids.lookup(scene.space, bee)
             pos != first and :boids_vec.dist(pos, {44.0, 66.0}) < 8
           end)

    HiveGuard.input(scene, %{"go" => true})
    until(scene, &(&1.phase == :over))
    HiveGuard.input(scene, %{"go" => true})
    state = until(scene, &(&1.phase == :building and &1.wave == 0))
    assert state.guards == [{:scout, {44.0, 66.0}}] and state.nectar == 80
    Process.sleep(200)
    assert [%{group: :guards}] = :boids.snapshot(scene.space)
  end

  test "the page draws each kind of boid" do
    {_visitor, scene} = game(%{build: 1000.0})

    assert [%{name: "beetles"}, %{name: "large beetles"}, %{name: "scouts"}, %{name: "soldiers"}] =
             HiveGuard.kinds(scene)

    assert %{zones: [_ | _]} = HiveGuard.header(scene)
    assert {1, _, 14} = HiveGuard.look(scene, %{group: :beetles, vel: {1, 0}, data: {:large, 14}})
    assert {0, _, 0} = HiveGuard.look(scene, %{group: :beetles, vel: {1, 0}, data: {:small, 2}})
    assert {3, _, 0} = HiveGuard.look(scene, %{group: :guards, vel: {1, 0}, data: :soldier})
    assert {2, _, 0} = HiveGuard.look(scene, %{group: :guards, vel: {1, 0}, data: :scout})
  end
end
