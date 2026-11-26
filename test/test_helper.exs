defmodule Boids.Helpers do
  @moduledoc false
  import ExUnit.Assertions
  import StreamData

  @doc "A check that two vectors are equal, in the limits of the precision."
  def assert_vec(left, right, delta \\ 1.0e-9) do
    assert tuple_size(left) == tuple_size(right),
           "#{inspect(left)} and #{inspect(right)} have different sizes"

    for {a, b} <- Enum.zip(Tuple.to_list(left), Tuple.to_list(right)) do
      assert_in_delta a, b, delta, "#{inspect(left)} is not #{inspect(right)}"
    end

    :ok
  end

  @doc "A generator of a number of a position."
  def coordinate(limit \\ 1000.0), do: float(min: -limit, max: limit)

  @doc "A generator of a vector of the size `dim`."
  def vec(dim, limit \\ 1000.0)
  def vec(2, limit), do: tuple({coordinate(limit), coordinate(limit)})
  def vec(3, limit), do: tuple({coordinate(limit), coordinate(limit), coordinate(limit)})

  @doc "A generator of a vector that is not near zero."
  def vec_not_zero(dim), do: filter(vec(dim), &(:boids_vec.norm(&1) > 1.0e-3))

  @doc "A generator of the size of a vector."
  def dim, do: member_of([2, 3])

  @doc "A boid for the functions of boids_steer."
  def body(pos, vel, max_speed \\ 10.0), do: %{pos: pos, vel: vel, max_speed: max_speed}

  @doc "A neighbor of a boid at `pos`, as boids_space:near/3 gives it."
  def neighbor(pos, other, vel \\ nil, more \\ %{}) do
    offset = :boids_vec.sub(other, pos)

    Map.merge(
      %{
        id: make_ref(),
        pos: other,
        vel: vel || :boids_vec.zero(tuple_size(pos)),
        group: :default,
        data: nil,
        offset: offset,
        dist: :boids_vec.norm(offset)
      },
      more
    )
  end

  @doc "How much the boids move in one direction: 0 (none) to 1 (all)."
  def order(rows) do
    sum =
      Enum.reduce(rows, :boids_vec.zero(tuple_size(hd(rows).vel)), fn %{vel: vel}, acc ->
        :boids_vec.add(acc, :boids_vec.normalize(vel))
      end)

    :boids_vec.norm(sum) / length(rows)
  end

  @doc "Wait until `fun` gives a true value, for 2 seconds at most."
  def eventually(fun, tries \\ 200) do
    case fun.() do
      value when value in [false, nil] and tries > 0 ->
        Process.sleep(10)
        eventually(fun, tries - 1)

      value ->
        value
    end
  end
end

ExUnit.start()
