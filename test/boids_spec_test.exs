defmodule BoidsSpecTest do
  # The model checks of the specifications (specs/), with the native
  # checker of Accord. Each fault model must fail: a check that cannot
  # fail proves nothing.
  use ExUnit.Case, async: true

  alias Accord.TLA.Checker

  @members Path.expand("../specs/MCMembers.tla", __DIR__)
  @space Path.expand("../specs/MCSpace.tla", __DIR__)
  @step Path.expand("../specs/MCStep.tla", __DIR__)
  @move Path.expand("../specs/MCMove.tla", __DIR__)
  @three Path.expand("../specs/MCMoveThree.tla", __DIR__)
  @facts Path.expand("../specs/MCFacts.tla", __DIR__)

  defp config(model, name), do: [config: Path.rootname(model) <> name <> ".cfg"]

  # The checker of Accord can use a worker for each processor. That makes
  # the models of Space and of Step about two times faster, and the
  # models of Space a little slower.
  @workers [workers: :auto]

  describe "specs/Members.tla: the members of a world" do
    test "a boid that runs has its row, and no row of a process that stopped stays" do
      assert {:ok, %{distinct_states: states}} = Checker.check(@members, @workers)
      assert states > 1000
    end

    test "the row of an id does not change with the messages for another id" do
      assert {:ok, %{distinct_states: states}} = Checker.check(@members, config(@members, "Two") ++ @workers)
      assert states > 1000
    end

    test "a world that keeps the row of a process that stopped refuses the process that starts again" do
      assert {:error, %{kind: :invariant, property: "Fair"}, _} =
               Checker.check(@members, config(@members, "Keep"))
    end

    test "a leave with no check of its process takes the row of a new process" do
      assert {:error, %{kind: :invariant, property: "LiveHasRow"}, _} =
               Checker.check(@members, config(@members, "Leave"))
    end
  end

  describe "specs/Space.tla: a write against a read" do
    test "a reader finds each boid one time at most, and each boid that stays in its cell" do
      assert {:ok, %{distinct_states: states}} = Checker.check(@space)
      assert states > 1000
    end

    test "the same with three writes of a boid during one read" do
      assert {:ok, %{distinct_states: states}} = Checker.check(@space, config(@space, "Long"))
      assert states > 1000
    end

    test "a write that removes the old copy first hides a boid from a reader" do
      assert {:error, %{kind: :invariant, property: "Finds"}, _} =
               Checker.check(@space, config(@space, "Gap"))
    end

    test "a world that removes only the copy of the row leaves a copy of a boid that stopped in a write" do
      assert {:error, %{kind: :invariant, property: "Gone"}, _} =
               Checker.check(@space, config(@space, "Leak"))
    end

    test "a reader that keeps each copy finds a boid two times" do
      assert {:error, %{kind: :invariant, property: "OneTime"}, _} =
               Checker.check(@space, config(@space, "Twice"))
    end

    test "a reader finds each obstacle one time, also an obstacle that the one writer moves" do
      assert {:ok, %{distinct_states: states}} = Checker.check(@space, config(@space, "Obstacles"))
      assert states > 1000
    end

    test "the same with three moves of an obstacle during one read" do
      assert {:ok, %{distinct_states: states}} = Checker.check(@space, config(@space, "ObstaclesLong"))
      assert states > 1000
    end

    test "two processes that write the obstacles lose the cell of an obstacle" do
      assert {:error, %{kind: :invariant, property: "Indexed"}, _} =
               Checker.check(@space, config(@space, "TwoWriters"))
    end

    test "a reader that does not check the version does not find an obstacle that moves" do
      assert {:error, %{kind: :invariant, property: "Exact"}, _} =
               Checker.check(@space, config(@space, "NoCheck"))
    end
  end

  describe "specs/Step.tla: one step of all the boids" do
    test "each boid calculates from the state at the start of the step, and each step ends" do
      assert {:ok, %{distinct_states: states}} = Checker.check(@step, @workers)
      assert states > 1000
    end

    test "a boid that moves when it calculates changes the world for the next boid" do
      assert {:error, %{kind: :invariant, property: "Quiet"}, _} =
               Checker.check(@step, config(@step, "OnePart"))
    end

    test "a boid with its own clock moves during the step" do
      assert {:error, %{kind: :invariant, property: "Quiet"}, _} =
               Checker.check(@step, config(@step, "Clock"))
    end
  end

  describe "specs/Move.tla: the move of a boid to another node" do
    test "with a connection that does not end, the boid has one process after each move, and each move ends" do
      assert {:ok, %{distinct_states: states}} = Checker.check(@move)
      assert states > 100
    end

    test "with splits of the network, the boid keeps a process, and it has one process after the last heal" do
      assert {:ok, %{distinct_states: states}} = Checker.check(@move, config(@move, "Split"))
      assert states > 1000
    end

    test "a node that always keeps its process lets two processes stop for each other" do
      assert {:error, %{kind: :invariant, property: "NotLost"}, _} =
               Checker.check(@move, config(@move, "Older"))
    end

    test "a process that stays when the other node has the boid does not end its move" do
      assert {:error, %{kind: :temporal, property: "Lands"}, _} =
               Checker.check(@move, config(@move, "Stays"))
    end

    test "a node that stops a process of each age when it is told can stop the only process" do
      assert {:error, %{kind: :invariant, property: "NotLost"}, _} =
               Checker.check(@move, config(@move, "Any"))
    end

    test "a limit: during a split, the boid can have a process on each node" do
      assert {:error, %{kind: :invariant, property: "OneProcess"}, _} =
               Checker.check(@move, config(@move, "Two"))
    end
  end

  describe "specs/MoveMany.tla: the move of a boid in a world on three nodes" do
    # The bounds: three nodes, one boid, three crossings of a border, and
    # one split that cuts one node from the two others.
    @tag timeout: 300_000
    test "the boid keeps a process, and it has one process when all the nodes have a connection and no message is on its way" do
      assert {:ok, %{distinct_states: states}} = Checker.check(@three, @workers)
      assert states > 100_000
    end

    # The bounds: three nodes, one boid, two crossings, and two splits.
    # A split cuts one node from the two others, or all the nodes.
    test "the same with two splits, and the world comes to rest with one process after the last heal" do
      assert {:ok, %{distinct_states: states}} = Checker.check(@three, config(@three, "Splits") ++ @workers)
      assert states > 10_000
    end

    test "a decision that uses the tile of a process can stop the two processes of a boid" do
      assert {:error, %{kind: :invariant, property: "NotLost"}, _} =
               Checker.check(@three, config(@three, "Tiles") ++ @workers)
    end

    test "a node that starts a process and tells no other node leaves two processes on nodes with a connection" do
      assert {:error, %{kind: :invariant, property: "Settled"}, _} =
               Checker.check(@three, config(@three, "Alone") ++ @workers)
    end

    test "a node that stops a process of each age when it is told can stop the only process, on three nodes" do
      assert {:error, %{kind: :invariant, property: "NotLost"}, _} =
               Checker.check(@three, config(@three, "Any") ++ @workers)
    end
  end

  describe "specs/Facts.tla: the facts of a world on several nodes" do
    # The bounds: two nodes, one key, three changes and two splits. The
    # counter of a change is larger than the largest counter that its
    # node knows by 1, or by 2 (a clock that is ahead).
    test "all the nodes come to the same facts, and an older change does not bring back a removed fact" do
      assert {:ok, %{distinct_states: states}} = Checker.check(@facts, @workers)
      assert states > 10_000
    end

    # The bounds: three nodes, one key, two changes and one split.
    test "the same on three nodes" do
      assert {:ok, %{distinct_states: states}} = Checker.check(@facts, config(@facts, "Three") ++ @workers)
      assert states > 10_000
    end

    # The bounds: two nodes, two keys, three changes and no split.
    test "the same with two keys, which share the counter of a node" do
      assert {:ok, %{distinct_states: states}} = Checker.check(@facts, config(@facts, "Keys") ++ @workers)
      assert states > 1000
    end

    test "nodes that compare only the counters of two versions keep two different facts" do
      assert {:error, %{kind: :invariant, property: "Same"}, _} =
               Checker.check(@facts, config(@facts, "Counter"))
    end

    test "a counter that is only the time of a clock that stands still gives one version to two changes" do
      assert {:error, %{kind: :invariant, property: "Same"}, _} =
               Checker.check(@facts, config(@facts, "Clock"))
    end

    test "with no mark for a removed fact, an older change brings the fact back" do
      assert {:error, %{kind: :invariant, property: "NoReturn"}, _} =
               Checker.check(@facts, config(@facts, "NoMark"))
    end

    test "a limit: after a split that is longer than the time of a mark, an older change brings the fact back" do
      assert {:error, %{kind: :invariant, property: "NoReturn"}, _} =
               Checker.check(@facts, config(@facts, "Early"))
    end
  end
end
