defmodule BoidsAppTest do
  # The stop of the application stops all the environments, so no other test
  # runs at the same time.
  use ExUnit.Case, async: false

  @tag :capture_log
  test "the application starts and stops the supervisor of the environments" do
    {:ok, environment} = :boids.start_environment()
    assert is_pid(Process.whereis(:boids_sup))
    assert :application.stop(:boids) == :ok
    refute Process.alive?(environment)
    assert Process.whereis(:boids_sup) == nil
    assert {:ok, _} = :application.ensure_all_started(:boids)
    {:ok, again} = :boids.start_environment()
    assert :boids.stop_environment(again) == :ok
  end
end
