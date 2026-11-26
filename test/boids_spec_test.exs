defmodule BoidsSpecTest do
  # The model checks of the specifications (specs/), with the native
  # checker of Accord. Each fault model must fail: a check that cannot
  # fail proves nothing.
  use ExUnit.Case, async: true

  alias Accord.TLA.Checker

  @flock Path.expand("../specs/MCFlock.tla", __DIR__)
  @space Path.expand("../specs/MCSpace.tla", __DIR__)
  @step Path.expand("../specs/MCStep.tla", __DIR__)

  defp config(model, name), do: [config: Path.rootname(model) <> name <> ".cfg"]

  describe "specs/Flock.tla: the members of a flock" do
    test "a boid that runs has its row, and no row of a process that stopped stays" do
      assert {:ok, %{distinct_states: states}} = Checker.check(@flock)
      assert states > 1000
    end

    test "the row of an id does not change with the messages for another id" do
      assert {:ok, %{distinct_states: states}} = Checker.check(@flock, config(@flock, "Two"))
      assert states > 1000
    end

    test "a flock that keeps the row of a process that stopped refuses the process that starts again" do
      assert {:error, %{kind: :invariant, property: "Fair"}, _} =
               Checker.check(@flock, config(@flock, "Keep"))
    end

    test "a leave with no check of its process takes the row of a new process" do
      assert {:error, %{kind: :invariant, property: "LiveHasRow"}, _} =
               Checker.check(@flock, config(@flock, "Leave"))
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

    test "a reader that keeps each copy finds a boid two times" do
      assert {:error, %{kind: :invariant, property: "OneTime"}, _} =
               Checker.check(@space, config(@space, "Twice"))
    end
  end

  describe "specs/Step.tla: one step of all the boids" do
    test "each boid calculates from the state at the start of the step, and each step ends" do
      assert {:ok, %{distinct_states: states}} = Checker.check(@step)
      assert states > 1000
    end

    test "a boid that moves when it calculates changes the flock for the next boid" do
      assert {:error, %{kind: :invariant, property: "Quiet"}, _} =
               Checker.check(@step, config(@step, "OnePart"))
    end

    test "a boid with its own clock moves during the step" do
      assert {:error, %{kind: :invariant, property: "Quiet"}, _} =
               Checker.check(@step, config(@step, "Clock"))
    end
  end
end
