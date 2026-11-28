defmodule BoidsExamples.Games.LastSeenTest do
  # Last Seen: thefts, witnesses and their calls, officers that share
  # sightings and chase, the coat, the gates, and the input of the page.
  use ExUnit.Case, async: false
  alias BoidsExamples.Games.LastSeen
  alias BoidsExamples.Games.LastSeen.Director

  # A short call, so that the tests do not wait.
  @call {100, 200}

  # Start a scene in a process of its own. The scene stops with that process.
  defp start(options) do
    test = self()

    pid =
      spawn(fn ->
        send(test, {:scene, BoidsExamples.Scene.start(LastSeen, options)})
        Process.sleep(:infinity)
      end)

    on_exit(fn -> Process.exit(pid, :kill) end)
    assert_receive {:scene, {:ok, scene}}, 10_000
    scene
  end

  defp rows(scene), do: :boids.snapshot(scene.space, :local)
  defp group(scene, group), do: Enum.filter(rows(scene), &(&1.group == group))
  defp thief(scene), do: hd(group(scene, :thief))
  defp state(scene), do: GenServer.call(scene.director, :state)
  defp input(scene, message), do: LastSeen.input(scene, message)

  # True when the function gives a true value in the time limit.
  defp eventually(fun, limit \\ 6000) do
    Enum.any?(1..div(limit, 50), fn _ -> fun.() || (Process.sleep(50) && false) end)
  end

  # A citizen that does not move.
  defp still(pos, purse \\ false), do: %{pos: pos, purse: purse, speed: 0.0}

  test "a level has the citizens, the purses, the officers, the thief, the stalls and the gates" do
    scene = start(nil)
    assert length(group(scene, :citizens)) == 34
    assert Enum.count(group(scene, :citizens), & &1.data.purse) == 5
    assert length(group(scene, :officers)) == 3
    assert %{data: %{coat: :red, theft_at: nil}} = thief(scene)

    header = BoidsExamples.Scene.header(scene)
    assert header.ground == "sand"
    # The stalls are drawn by the page, and are not stones.
    assert header.rocks == []
    assert length(:boids.obstacles(scene.space)) == 7
    assert Enum.map(header.zones, &List.last/1) == ["Mill gate", "Bridge gate", "Hill gate", "Port gate"]
    assert length(header.kinds) == 7

    status = Director.status(scene.director)
    assert Enum.map(status.r, &hd/1) == ["Level", "Loot", "Sightings", "Chasing", "Coat"]
    assert status.x.state == :sneaking and status.x.need == 3 and status.x.changes == 1
    assert length(status.x.stalls) == 7
    assert Enum.count(status.x.stalls, &(Enum.at(&1, 4) == "purse")) == 2
    # Nothing is null in JSON for the page.
    assert status.x.wanted == :null and status.x.note == :null
    assert IO.iodata_to_binary(:json.encode(status)) =~ ~s("wanted":null)
  end

  test "the levels have more officers, fewer citizens and faster calls" do
    [one, two, three] = Director.levels()
    assert length(one.officers) < length(two.officers) and length(two.officers) < length(three.officers)
    assert one.citizens > two.citizens and two.citizens > three.citizens
    assert elem(one.call, 1) > elem(two.call, 1) and elem(two.call, 1) > elem(three.call, 1)

    scene = start(%{level: 3})
    assert length(group(scene, :officers)) == 5
    assert Director.status(scene.director).x.need == 5
    # Each level has more purses than it needs.
    for level <- Director.levels() do
      purses = level.purses + Enum.count(level.stalls, &(elem(&1, 3) == :purse))
      assert purses > level.need
    end
  end

  test "the thief steals the purse of a citizen next to it, and a citizen that sees it calls the police" do
    scene =
      start(%{
        citizens: [still({21, 45}, true), still({28, 48})],
        officers: [{150, 80}],
        thief: {20.0, 45.0},
        call: @call
      })

    input(scene, %{"steal" => true})
    assert eventually(fn -> state(scene).loot == 1 end)
    assert eventually(fn -> Enum.all?(group(scene, :citizens), &(&1.data.purse == false)) end)
    assert thief(scene).data.theft_at != nil

    # The witnesses call. Then the police have the sighting: its place, its
    # time and the red coat. The nearest officer knows it.
    assert eventually(fn -> state(scene).count >= 1 end)
    [sighting | _] = state(scene).sightings
    assert sighting.coat == :red and sighting.what == :theft
    assert :boids_vec.dist(sighting.pos, {20, 45}) < 1.0
    assert eventually(fn -> match?([%{data: %{newest: %{coat: :red}}}], group(scene, :officers)) end)

    # The page gets the sighting, with the name of the nearest stall. The
    # Fish stall and the Fruit stall are at the same distance.
    status = Director.status(scene.director)
    assert [[x, y, age, "warm", "theft", stall] | _] = status.x.sightings
    assert is_float(x) and is_float(y) and age >= 0 and stall in ["Fish", "Fruit"]
    assert ["Sightings", count] = Enum.at(status.r, 2)
    assert count >= 1
    assert status.x.wanted == "red"
  end

  test "a witness stands and calls for some time before the police know" do
    scene = start(%{citizens: [still({24, 45})], officers: [{150, 80}], thief: {20.0, 45.0}, call: {1500, 1600}})
    # A steal with no purse near takes nothing.
    input(scene, %{"steal" => true})
    assert state(scene).loot == 0
    # The citizen sees a person that runs, then calls.
    for _ <- 1..3, do: LastSeen.input(scene, %{"keys" => ["right", "run"]})
    assert eventually(fn -> Enum.any?(group(scene, :citizens), &(&1.data.role == :witness)) end)
    # The call takes more than one second: no sighting yet.
    assert state(scene).count == 0
    assert eventually(fn -> state(scene).count == 1 end)
    assert hd(state(scene).sightings).what == :running
    # After its call, the witness walks again.
    assert eventually(fn -> Enum.all?(group(scene, :citizens), &(&1.data.role == :citizen)) end)
  end

  test "a theft that no citizen sees gives no sighting, and a stall loses its purse" do
    # The Fish stall has a purse in level 1. The citizen is far.
    scene = start(%{citizens: [still({120, 80})], officers: [{150, 80}], thief: {31.5, 24.0}, call: @call})
    input(scene, %{"steal" => true})
    assert eventually(fn -> state(scene).loot == 1 end)
    assert List.keyfind(state(scene).stalls, "Fish", 0) |> elem(3) == :goods
    Process.sleep(700)
    assert state(scene).count == 0
    # The purse is gone: a second theft at the same stall takes nothing.
    input(scene, %{"steal" => true})
    Process.sleep(200)
    assert state(scene).loot == 1
  end

  test "a steal with no purse near takes nothing, and shows no theft" do
    scene = start(%{citizens: [still({40, 80}, true)], officers: [{150, 80}], thief: {8.0, 45.0}, call: @call})
    input(scene, %{"steal" => true})
    Process.sleep(300)
    assert state(scene).loot == 0
    assert thief(scene).data.theft_at == nil
  end

  test "a citizen that knows the coat of the last sighting reports the thief near it" do
    scene = start(%{citizens: [still({22, 45})], officers: [{150, 80}], thief: {20.0, 45.0}, call: @call})
    # The thief walks slowly: with no coat to look for, the citizen sees one person of many.
    Process.sleep(500)
    assert state(scene).count == 0
    [%{pid: pid}] = group(scene, :citizens)
    :gen_boid.cast(pid, {:wanted, :red})
    assert eventually(fn -> state(scene).count == 1 end)
    assert hd(state(scene).sightings).what == :coat
  end

  test "a citizen sees the coat only in front of it, or very near" do
    # The citizen stands, and the thief is 4 units from it.
    scene = start(%{citizens: [still({24, 45})], officers: [{150, 80}], thief: {20.0, 45.0}, call: @call})
    [%{pid: pid}] = group(scene, :citizens)
    :gen_boid.cast(pid, {:wanted, :red})
    Process.sleep(600)
    assert state(scene).count == 0
  end

  test "the thief must stop to steal" do
    scene = start(%{citizens: [], officers: [{150, 80}], thief: {31.5, 21.0}, call: @call})
    # The thief walks past the Fish stall, and steals while it walks.
    input(scene, %{"keys" => ["up"]})
    assert eventually(fn -> thief(scene).data.speed > 3.0 end)
    input(scene, %{"steal" => true})
    assert eventually(fn -> Director.status(scene.director).x.note == "Stop next to the purse, then steal it." end)
    assert state(scene).loot == 0
    # It stops, and steals.
    input(scene, %{"keys" => []})
    assert eventually(fn -> thief(scene).data.speed < 0.5 end)
    input(scene, %{"steal" => true})
    assert eventually(fn -> state(scene).loot == 1 end)
  end

  test "the director tells each citizen the coat of a sighting" do
    scene =
      start(%{
        citizens: [still({21, 45}, true), still({90, 80})],
        officers: [{150, 80}],
        thief: {20.0, 45.0},
        call: @call
      })

    input(scene, %{"steal" => true})
    assert eventually(fn -> state(scene).wanted == :red end)

    assert eventually(fn ->
             Enum.all?(group(scene, :citizens), fn %{pid: pid} -> :sys.get_state(pid).boid.state.wanted == :red end)
           end)
  end

  test "officers share the newest sighting with the officers that they see" do
    scene = start(%{citizens: [], officers: [{100, 45}, {108, 45}, {20, 80}], thief: {8.0, 10.0}})
    [first | _] = group(scene, :officers) |> Enum.sort_by(&:boids_vec.dist(&1.pos, {100, 45}))
    sighting = %{pos: {104.0, 40.0}, coat: :green, what: :theft, time: LastSeen.now(), id: :test}
    :gen_boid.cast(first.pid, {:sighting, sighting})

    assert eventually(fn ->
             Enum.count(group(scene, :officers), &match?(%{data: %{newest: %{id: :test}}}, &1)) == 2
           end)

    # The officer that is far sees no other officer: it does not know.
    far = Enum.max_by(group(scene, :officers), &:boids_vec.dist(&1.pos, {100, 45}))
    assert far.data.newest == nil
    # The officers go to the place of the sighting.
    assert eventually(fn -> Enum.any?(group(scene, :officers), &(&1.data.mode == :search)) end)
  end

  test "an officer forgets a sighting where it finds nothing, and patrols" do
    scene = start(%{citizens: [], officers: [{100, 45}], thief: {8.0, 10.0}})
    [officer] = group(scene, :officers)

    :gen_boid.cast(
      officer.pid,
      {:sighting, %{pos: {104.0, 45.0}, coat: :green, what: :theft, time: LastSeen.now(), id: :old}}
    )

    assert eventually(fn -> hd(group(scene, :officers)).data.mode == :search end)
    assert eventually(fn -> hd(group(scene, :officers)).data == %{mode: :patrol, newest: nil} end)
  end

  test "an officer that knows the coat chases the thief, and catches it" do
    scene = start(%{citizens: [], officers: [{30, 45}], thief: {20.0, 45.0}})
    [officer] = group(scene, :officers)

    :gen_boid.cast(
      officer.pid,
      {:sighting, %{pos: {25.0, 45.0}, coat: :red, what: :theft, time: LastSeen.now(), id: :t}}
    )

    assert eventually(fn -> Enum.any?(group(scene, :officers), &(&1.data.mode == :chase)) end)
    assert eventually(fn -> state(scene).state == :caught end)
    assert Director.status(scene.director).x.state == :caught
    # The keys do nothing after the end.
    input(scene, %{"keys" => ["right"]})
    # Try again: the same level, with a new thief.
    input(scene, %{"go" => true})
    assert eventually(fn -> state(scene).state == :sneaking end)
    assert state(scene).level == 1
  end

  test "an officer that sees a theft chases the thief, also with no sighting" do
    scene = start(%{citizens: [still({21, 45}, true)], officers: [{30, 45}], thief: {20.0, 45.0}, call: {5000, 6000}})
    input(scene, %{"steal" => true})
    assert eventually(fn -> Enum.any?(group(scene, :officers), &(&1.data.mode == :chase)) end)
  end

  test "an officer is tired after some seconds of a chase" do
    # A slow officer, and a thief that walks away from it.
    scene = start(%{citizens: [], officers: [{15, 45}], thief: {20.0, 45.0}, chase: 3.4})
    [officer] = group(scene, :officers)

    :gen_boid.cast(
      officer.pid,
      {:sighting, %{pos: {20.0, 45.0}, coat: :red, what: :theft, time: LastSeen.now(), id: :t}}
    )

    input(scene, %{"keys" => ["right"]})
    assert eventually(fn -> hd(group(scene, :officers)).data.mode == :chase end)
    # The chase stops after some seconds, with the thief near.
    assert eventually(fn -> hd(group(scene, :officers)).data.mode != :chase end, 9000)
    assert :sys.get_state(officer.pid).boid.state.tired != nil
    assert state(scene).state == :sneaking
  end

  test "an officer does not chase a thief in a coat that it does not know" do
    scene = start(%{citizens: [], officers: [{30, 45}], thief: {20.0, 45.0}})
    [officer] = group(scene, :officers)

    :gen_boid.cast(
      officer.pid,
      {:sighting, %{pos: {25.0, 45.0}, coat: :green, what: :theft, time: LastSeen.now(), id: :g}}
    )

    for _ <- 1..20 do
      Process.sleep(50)
      refute Enum.any?(group(scene, :officers), &(&1.data.mode == :chase))
    end

    assert state(scene).state == :sneaking
  end

  test "a new coat at the Coats stall: the old sightings no longer match" do
    # The Coats stall is at {80, 24}.
    scene = start(%{citizens: [], officers: [{150, 80}], thief: {80.0, 31.5}})
    input(scene, %{"coat" => true})
    assert eventually(fn -> thief(scene).data.coat == :green end)
    assert state(scene).changes == 0
    assert Director.status(scene.director).x.coat == "green"
    # One change for each level.
    input(scene, %{"coat" => true})
    Process.sleep(200)
    assert thief(scene).data.coat == :green
  end

  test "a new coat is not the coat that the police look for, and needs the Coats stall" do
    far = start(%{citizens: [], officers: [{150, 80}], thief: {8.0, 45.0}})
    input(far, %{"coat" => true})
    Process.sleep(200)
    assert thief(far).data.coat == :red and state(far).changes == 1

    scene = start(%{citizens: [still({82, 31.5})], officers: [{150, 80}], thief: {80.0, 31.5}, call: @call})
    [%{pid: pid}] = group(scene, :citizens)
    :gen_boid.cast(pid, {:wanted, :red})
    assert eventually(fn -> state(scene).wanted == :red end)
    # The police want red. The coat is red now: the new coat is green, and
    # with green wanted it would be blue.
    input(scene, %{"coat" => true})
    assert eventually(fn -> thief(scene).data.coat == :green end)
  end

  test "the thief with the loot escapes through a gate, and the next level starts" do
    scene =
      start(%{citizens: [still({9.5, 45}, true)], officers: [{150, 80}], thief: {8.0, 45.0}, need: 1, call: @call})

    input(scene, %{"steal" => true})
    assert eventually(fn -> state(scene).loot == 1 end)
    input(scene, %{"keys" => ["left"]})
    assert eventually(fn -> state(scene).state == :escaped end)
    status = Director.status(scene.director)
    assert status.x.state == :escaped and status.x.loot == 1 and status.x.time > 0
    input(scene, %{"go" => true})
    assert eventually(fn -> state(scene).level == 2 and state(scene).state == :sneaking end)
  end

  test "a gate does nothing for a thief with too little loot" do
    scene = start(%{citizens: [], officers: [{150, 80}], thief: {2.0, 45.0}})
    Process.sleep(400)
    assert state(scene).state == :sneaking
  end

  test "after the last level, the game starts again at level 1" do
    scene = start(%{level: 3, citizens: [still({9.5, 45}, true)], officers: [{150, 80}], thief: {8.0, 45.0}, need: 1})
    input(scene, %{"steal" => true})
    assert eventually(fn -> state(scene).loot == 1 end)
    input(scene, %{"keys" => ["left"]})
    assert eventually(fn -> state(scene).state == :escaped end)
    input(scene, %{"go" => true})
    assert eventually(fn -> state(scene).level == 1 end)
  end

  test "the keys move the thief, and run makes it fast" do
    scene = start(%{citizens: [], officers: [{150, 80}], thief: {40.0, 45.0}})
    input(scene, %{"keys" => ["right"]})
    assert eventually(fn -> elem(thief(scene).pos, 0) > 42 end)
    assert eventually(fn -> thief(scene).data.speed > 3.0 end)
    refute thief(scene).data.running
    input(scene, %{"keys" => ["right", "run"]})
    assert eventually(fn -> thief(scene).data.running end)
    input(scene, %{"keys" => []})
    assert eventually(fn -> thief(scene).data.speed < 0.5 end)
  end

  test "the input of the page is checked" do
    scene = start(%{citizens: [], officers: [{150, 80}], thief: {40.0, 45.0}})
    input(scene, %{"keys" => ["jump", 1, "fly"]})
    input(scene, %{"keys" => "right"})
    input(scene, %{"steal" => "yes"})
    input(scene, %{"go" => true})
    input(scene, %{"other" => 1})
    Process.sleep(200)
    assert state(scene).state == :sneaking and state(scene).loot == 0
    assert Process.alive?(scene.director)
    assert thief(scene).data.speed < 0.5
  end

  test "the look of each boid" do
    scene = start(nil)

    for row <- rows(scene) do
      {kind, angle, _size} = LastSeen.look(scene, row)
      assert kind in 0..6 and is_number(angle)
    end

    assert {2, _, _} = LastSeen.look(scene, %{group: :citizens, data: %{role: :witness, purse: true}, vel: {1.0, 0.0}})
    assert {1, _, _} = LastSeen.look(scene, %{group: :citizens, data: %{role: :citizen, purse: true}, vel: {1.0, 0.0}})
    assert {6, _, _} = LastSeen.look(scene, %{group: :thief, data: %{coat: :blue}, vel: {0.0, 1.0}})
    assert LastSeen.coat_name(:blue) == "dark blue" and LastSeen.coat_name(:red) == "red"
    assert LastSeen.in_gate?({2, 45}) and not LastSeen.in_gate?({80, 45})
  end
end
