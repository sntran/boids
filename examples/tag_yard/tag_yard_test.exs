defmodule BoidsExamples.TagYardTest do
  # The game Tag Yard: "it" and the runners, the tag as a message, no tag
  # back, the person, the modes Classic and Freeze, the bell and the score.
  use ExUnit.Case, async: false
  alias BoidsExamples.Scene
  alias BoidsExamples.Games.TagYard, as: Yard
  alias BoidsExamples.Games.TagYard.{Child, Director}

  # Start a round in a process of its own, as a visitor. The round stops
  # at the end of the test.
  defp run(options) do
    test = self()

    pid =
      spawn(fn ->
        send(test, {:scene, Scene.start(Yard, options)})
        Process.sleep(:infinity)
      end)

    assert_receive {:scene, {:ok, scene}}, 5000

    on_exit(fn ->
      Scene.stop(scene)
      Process.exit(pid, :kill)
    end)

    scene
  end

  # Wait until the function gives a true value, for 10 seconds at most.
  defp wait(fun, what, tries \\ 200) do
    case fun.() do
      value when value in [false, nil] ->
        if tries == 0, do: flunk("No #{what} in 10 seconds.")
        Process.sleep(50)
        wait(fun, what, tries - 1)

      value ->
        value
    end
  end

  defp status(scene), do: Director.status(scene.director)
  defp rows(scene), do: for(%{data: %{name: _}} = row <- :boids.snapshot(scene.space, :local), do: row)
  defp row(scene, name), do: Enum.find(rows(scene), &(&1.data.name == name))
  defp role(scene, name), do: (row = row(scene, name)) && row.data.role
  defp its(scene), do: for(%{data: %{role: :it, name: name}} <- rows(scene), do: name)
  defp send_to(scene, name, message), do: :gen_boid.cast(:boids.whereis(scene.space, row(scene, name).id), message)
  defp keys(scene, keys), do: Director.input(scene.director, %{"keys" => keys})
  defp speed(scene, name), do: :boids_vec.norm(row(scene, name).vel)

  # The children of a test: far from the trees and from the place of the
  # person, so that no child touches another child by chance.
  @far [{30.0, 20.0}, {140.0, 80.0}]

  test "a round of Classic has 15 children, one \"it\", the trees and a ground of sand" do
    scene = run(nil)
    header = Scene.header(scene)
    assert header.box == [160, 90]
    assert header.ground == "sand"
    assert Enum.sort(header.rocks) == Enum.sort(for {x, y, r} <- Yard.trees(), do: [x, y, r])

    assert Enum.map(header.kinds, & &1.name) ==
             ["runners", "it", "tired it", "frozen", "you", "you are it", "you are frozen"]

    wait(fn -> length(rows(scene)) == 15 and length(its(scene)) == 1 end, "15 children with one it")
    # The person starts free, away from "it".
    assert hd(its(scene)) in Yard.names()
    assert role(scene, "You") == :runner

    status = wait(fn -> (status = status(scene)) && match?([_], status.x.its) && status end, "it in the status")
    [it] = status.x.its

    assert [["Mode", "Classic"], ["It now", ^it], ["Your time free", _], ["Your score", "0 tags"], ["Frozen", "none"]] =
             status.r

    assert status.x.mode == :classic and status.x.phase == :playing
    assert status.x.left in 80..90

    # The page draws a ring under the person and under "it".
    assert [[_, _, "it"], [_, _, "you"]] = Enum.sort_by(status.x.marks, &List.last/1)

    # A moment of the scene is JSON for the page.
    moment = Scene.frame(scene, 1)
    assert length(moment.b) == 15 * 6
    assert is_binary(IO.iodata_to_binary(:json.encode(moment)))
  end

  test "the kind of a child on the page comes from its role, and the person has kinds of its own" do
    look = fn data -> elem(Yard.look(nil, %{data: data, vel: {1.0, 0.0}}), 0) end
    assert look.(%{name: "Ana", role: :runner}) == 0
    assert look.(%{name: "Ana", role: :it, tired: false}) == 1
    assert look.(%{name: "Ana", role: :it, tired: true}) == 2
    assert look.(%{name: "Ana", role: :frozen}) == 3
    assert look.(%{name: "You", role: :runner}) == 4
    assert look.(%{name: "You", role: :it}) == 5
    assert look.(%{name: "You", role: :frozen}) == 6
  end

  test "a tag is a message: the runner becomes \"it\", and the old \"it\" cannot be tagged back" do
    scene = run(%{kids: [{100.0, 45.0}, {101.5, 45.0}], it: [0], you: {20.0, 80.0}})
    wait(fn -> role(scene, "Ben") == :it end, "tag of Ben")

    # Ana tagged Ben: now she is a runner that Ben cannot tag back.
    assert %{role: :runner, immune: true} = row(scene, "Ana").data
    refute Yard.target?(row(scene, "Ana"))
    send_to(scene, "Ana", {:tagged, "Ben"})
    Process.sleep(300)
    assert role(scene, "Ana") == :runner

    wait(fn -> status(scene).x.last == "Ana tagged Ben." end, "the last tag in the status")
    assert status(scene).x.tags == 0
    assert status(scene).x.its == ["Ben"]
  end

  test "only a runner that can be tagged becomes \"it\"" do
    assert Yard.target?(%{data: %{role: :runner, immune: false}})
    refute Yard.target?(%{data: %{role: :runner, immune: true}})
    refute Yard.target?(%{data: %{role: :it, immune: false}})
    refute Yard.target?(%{data: %{role: :frozen, immune: false}})

    # The message itself: a runner with no "no tag back" time becomes it.
    scene = run(%{kids: @far, it: [1], you: {80.0, 45.0}})
    wait(fn -> its(scene) == ["Ben"] end, "Ben as it")
    send_to(scene, "Ana", {:tagged, "Ben"})
    wait(fn -> role(scene, "Ana") == :it end, "Ana as it")
  end

  test "the person can tag: the child that the person touches becomes \"it\", and the tags count" do
    scene = run(%{kids: [{101.0, 45.0}], you_it: true, you: {100.0, 45.0}})
    wait(fn -> role(scene, "Ana") == :it end, "tag of Ana by the person")
    assert %{role: :runner, immune: true} = row(scene, "You").data

    wait(fn -> status(scene).x.tags == 1 end, "a tag of the person")
    assert status(scene).x.last == "You tagged Ana."
    assert ["Your score", "1 tag"] in status(scene).r
  end

  test "when \"it\" touches the person, the person is it, and the time free stops" do
    scene = run(%{kids: [{100.0, 45.0}], it: [0], you: {101.0, 45.0}})
    wait(fn -> status(scene).x.you == :it end, "the person as it")
    assert ["It now", "You"] in status(scene).r
    free = status(scene).x.free
    Process.sleep(1200)
    assert status(scene).x.you == :it
    assert status(scene).x.free == free
  end

  test "the time free of the person grows while the person is a runner" do
    scene = run(%{kids: @far, it: [0], you: {80.0, 45.0}})
    wait(fn -> ["Your time free", "1 s"] in status(scene).r end, "one second free")
    wait(fn -> ["Your time free", "2 s"] in status(scene).r end, "two seconds free")
  end

  test "with no \"it\" for one second, a child that the computer moves becomes it" do
    scene = run(%{kids: @far, it: [], you: {80.0, 45.0}})
    [it] = wait(fn -> (its = its(scene)) != [] && its end, "a new it")
    assert it in ["Ana", "Ben"]
    assert role(scene, "You") == :runner
  end

  test "a child that is \"it\" for a long time in Classic is tired: it is slower, and the runners fear it less" do
    state = %{name: "Ana", person: false, mode: :classic, role: :it, immune: 0, it_steps: 0, stamina: 100.0}
    refute Child.data(state).tired
    assert Child.look(state).max_speed == 11.0

    long = %{state | it_steps: Yard.steps(20_000)}
    assert Child.data(long).tired
    assert Child.look(long).max_speed == 8.0
    assert Yard.fear(Child.data(long)) < Yard.fear(Child.data(state))

    # In Freeze, "it" does not get tired. The person does not get tired.
    refute Child.data(%{long | mode: :freeze}).tired
    assert Child.look(%{long | mode: :freeze}).max_speed == 11.0
    refute Child.data(%{long | person: true}).tired
  end

  test "a runner flees \"it\" only inside its distance of fear" do
    scene = run(%{kids: @far, it: [], you: {80.0, 45.0}})
    wait(fn -> row(scene, "Ana") end, "Ana")
    {:ok, boid} = :boids.boid(scene.space, row(scene, "Ana").id)
    {x, y} = boid.pos
    it = fn tired, dist -> %{data: %{role: :it, tired: tired}, dist: dist, pos: {x + dist, y}, vel: {0.0, 0.0}} end

    assert Yard.escape(boid, [it.(false, 10.0)], %{}) != {0.0, 0.0}
    assert Yard.escape(boid, [it.(true, 10.0)], %{}) == {0.0, 0.0}
    assert Yard.escape(boid, [it.(false, 20.0)], %{}) == {0.0, 0.0}

    assert Yard.escape(boid, [%{data: %{role: :runner}, dist: 2.0, pos: {x + 2, y}, vel: {0.0, 0.0}}], %{}) ==
             {0.0, 0.0}

    # "It" chases a runner that it can tag, and not a runner that was it.
    runner = fn immune -> %{data: %{role: :runner, immune: immune}, dist: 5.0, pos: {x + 5, y}, vel: {0.0, 0.0}} end
    assert Yard.chase(boid, [runner.(false)], %{}) != {0.0, 0.0}
    assert Yard.chase(boid, [runner.(true)], %{}) == {0.0, 0.0}
  end

  test "in Freeze, three children are it, and a child that it touches is frozen and stands still" do
    scene = run(%{mode: :freeze})
    wait(fn -> length(rows(scene)) == 15 and length(its(scene)) == 3 end, "three its")
    refute "You" in its(scene)

    scene = run(%{mode: :freeze, kids: [{100.0, 45.0}, {101.5, 45.0}, {30.0, 20.0}], it: [0], you: {140.0, 75.0}})
    wait(fn -> role(scene, "Ben") == :frozen end, "Ben frozen")
    assert role(scene, "Ana") == :it
    {:ok, ben} = :boids.boid(scene.space, row(scene, "Ben").id)
    assert ben.max_speed == 0.0 and ben.rules == []

    wait(fn -> ["Frozen", "1 of 3"] in status(scene).r end, "one frozen in the status")
    assert ["Mode", "Freeze"] in status(scene).r
    assert ["Your score", "0 rescues"] in status(scene).r
  end

  test "in Freeze, a free child that touches a frozen child frees it, and the rescues of the person count" do
    scene = run(%{mode: :freeze, kids: [{100.0, 45.0}, {20.0, 80.0}], it: [1], you: {101.0, 45.0}})
    wait(fn -> row(scene, "Ana") && row(scene, "You") end, "Ana and the person")
    send_to(scene, "Ana", {:tagged, "Ben"})
    wait(fn -> status(scene).x.rescues == 1 end, "a rescue of the person")
    assert status(scene).x.last == "You freed Ana."
    assert %{role: :runner, immune: true} = row(scene, "Ana").data

    # A child that is free again cannot be frozen at once.
    send_to(scene, "Ana", {:tagged, "Ben"})
    Process.sleep(300)
    assert role(scene, "Ana") == :runner
  end

  test "in Freeze, \"it\" wins when all the children are frozen" do
    scene = run(%{mode: :freeze, kids: [{100.0, 45.0}, {30.0, 20.0}], it: [1], you: {130.0, 70.0}})
    wait(fn -> its(scene) == ["Ben"] end, "Ben as it")
    send_to(scene, "Ana", {:tagged, "Ben"})
    send_to(scene, "You", {:tagged, "Ben"})

    wait(fn -> status(scene).x.phase == :over end, "the end of the round")
    status = status(scene)
    assert status.x.won == false
    assert status.x.text == "It froze all the children."
    assert ["Frozen", "2 of 2"] in status.r

    # The frozen person cannot move.
    {:ok, you} = :boids.boid(scene.space, row(scene, "You").id)
    assert you.max_speed == 0.0
    assert elem(Yard.look(scene, row(scene, "You")), 0) == 6
  end

  test "at the bell, the person wins when the person is not it, and in Freeze the runners win" do
    free = run(%{duration: 1500, kids: [{30.0, 20.0}], it: [0], you: {130.0, 70.0}})
    caught = run(%{duration: 1500, kids: [{30.0, 20.0}], you_it: true, you: {130.0, 70.0}})
    freeze = run(%{mode: :freeze, duration: 1500, kids: [{30.0, 20.0}], it: [0], you: {130.0, 70.0}})

    for scene <- [free, caught, freeze], do: wait(fn -> status(scene).x.phase == :over end, "the bell")

    assert %{won: true, text: "The bell rang, and you are not it.", left: 0} = status(free).x
    assert status(free).x.free >= 1
    assert %{won: false, text: "The bell rang, and you are it.", free: 0} = status(caught).x
    assert %{won: true, text: "The bell rang before it froze all the children."} = status(freeze).x

    # Go starts a new round of the same mode.
    Director.input(free.director, %{"go" => true})
    wait(fn -> status(free).x.phase == :playing end, "a new round")
    assert %{mode: :classic, text: "", won: false, last: "", tags: 0} = status(free).x
  end

  test "the keys move the person, and Shift makes the person run until its stamina is empty" do
    scene = run(%{kids: [{140.0, 80.0}], it: [0], you: {20.0, 45.0}})
    wait(fn -> row(scene, "You") end, "the person")
    keys(scene, ["right"])
    wait(fn -> elem(row(scene, "You").pos, 0) > 24 end, "a walk to the right")
    assert speed(scene, "You") <= 8.6

    keys(scene, ["right", "run"])
    wait(fn -> speed(scene, "You") > 10 end, "a run")
    # The stamina is empty after about 3 seconds: the person walks again.
    wait(fn -> speed(scene, "You") < 9 end, "a walk with no stamina")
    assert status(scene).x.stamina < 5

    keys(scene, [])
    wait(fn -> speed(scene, "You") < 1 end, "a stop")
  end

  test "the game ignores input that is not correct" do
    scene = run(%{kids: @far, it: [0], you: {80.0, 45.0}})
    wait(fn -> row(scene, "You") end, "the person")

    for message <- [
          %{"keys" => "left"},
          %{"keys" => ["jump", 5, nil]},
          %{"mode" => "other"},
          %{"mode" => 5},
          %{"go" => "yes"},
          %{"other" => true},
          "text",
          nil
        ] do
      Director.input(scene.director, message)
    end

    Process.sleep(500)
    assert speed(scene, "You") < 1
    assert %{mode: :classic, phase: :playing} = status(scene).x
    assert length(rows(scene)) == 3
  end

  test "a button of mode starts a round of that mode" do
    scene = run(%{kids: @far, it: [0], you: {80.0, 45.0}})
    Scene.input(scene, %{"mode" => "freeze"})
    wait(fn -> status(scene).x.mode == :freeze end, "the mode Freeze")
    assert Director.duration(:freeze) < Director.duration(:classic)
    assert status(scene).x.left in 50..60

    Scene.input(scene, %{"mode" => "classic"})
    wait(fn -> status(scene).x.mode == :classic end, "the mode Classic")
    wait(fn -> length(rows(scene)) == 3 end, "the children of the new round")
  end
end
