defmodule BoidsAppTest do
  # The stop of the application stops all the worlds, so no other test
  # runs at the same time.
  use ExUnit.Case, async: false

  @tag :capture_log
  test "the application starts and stops the supervisor of the worlds" do
    {:ok, world} = :boids.start_world()
    assert is_pid(Process.whereis(:boids_sup))
    assert :application.stop(:boids) == :ok
    refute Process.alive?(world)
    assert Process.whereis(:boids_sup) == nil
    assert {:ok, _} = :application.ensure_all_started(:boids)
    {:ok, again} = :boids.start_world()
    assert :boids.stop_world(again) == :ok
  end
end
