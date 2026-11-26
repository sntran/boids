defmodule BoidsAppTest do
  # The stop of the application stops all the flocks, so no other test
  # runs at the same time.
  use ExUnit.Case, async: false

  @tag :capture_log
  test "the application starts and stops the supervisor of the flocks" do
    {:ok, flock} = :boids.start_flock()
    assert is_pid(Process.whereis(:boids_sup))
    assert :application.stop(:boids) == :ok
    refute Process.alive?(flock)
    assert Process.whereis(:boids_sup) == nil
    assert {:ok, _} = :application.ensure_all_started(:boids)
    {:ok, again} = :boids.start_flock()
    assert :boids.stop_flock(again) == :ok
  end
end
