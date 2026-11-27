defmodule BoidsAppTest do
  # The stop of the application stops all the spaces, so no other test
  # runs at the same time.
  use ExUnit.Case, async: false

  @tag :capture_log
  test "the application starts and stops the supervisor of the spaces" do
    {:ok, space} = :boids.start_space()
    assert is_pid(Process.whereis(:boids_sup))
    assert :application.stop(:boids) == :ok
    refute Process.alive?(space)
    assert Process.whereis(:boids_sup) == nil
    assert {:ok, _} = :application.ensure_all_started(:boids)
    {:ok, again} = :boids.start_space()
    assert :boids.stop_space(again) == :ok
  end
end
