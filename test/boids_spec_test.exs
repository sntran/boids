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
    test "with no lost answer, the boid has one process after each move, and each move ends" do
      assert {:ok, %{distinct_states: states}} = Checker.check(@move)
      assert states > 100
    end

    test "with lost calls and answers, the boid keeps a process, and each move ends" do
      assert {:ok, %{distinct_states: states}} = Checker.check(@move, config(@move, "Lost"))
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

    test "a limit: after a lost answer, the boid can have a process on each node" do
      assert {:error, %{kind: :invariant, property: "OneProcess"}, _} =
               Checker.check(@move, config(@move, "Two"))
    end
  end
end
