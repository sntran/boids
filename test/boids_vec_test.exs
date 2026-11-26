defmodule BoidsVecTest do
  use ExUnit.Case, async: true
  use ExUnitProperties
  import Boids.Helpers

  describe "the basic operations" do
    test "zero/1 and dim/1" do
      assert :boids_vec.zero(2) == {0.0, 0.0}
      assert :boids_vec.zero(3) == {0.0, 0.0, 0.0}
      assert :boids_vec.dim({1, 2}) == 2
      assert :boids_vec.dim({1, 2, 3}) == 3
    end

    test "add/2, sub/2, scale/2 and neg/1 with two numbers" do
      assert :boids_vec.add({1, 2}, {3, 5}) == {4, 7}
      assert :boids_vec.sub({1, 2}, {3, 5}) == {-2, -3}
      assert :boids_vec.scale({1, -2}, 2.5) == {2.5, -5.0}
      assert :boids_vec.neg({1, -2}) == {-1, 2}
    end

    test "add/2, sub/2, scale/2 and neg/1 with three numbers" do
      assert :boids_vec.add({1, 2, 3}, {3, 5, 7}) == {4, 7, 10}
      assert :boids_vec.sub({1, 2, 3}, {3, 5, 7}) == {-2, -3, -4}
      assert :boids_vec.scale({1, -2, 3}, 2) == {2, -4, 6}
      assert :boids_vec.neg({1, -2, 3}) == {-1, 2, -3}
    end

    test "dot/2, norm/1, norm2/1, dist/2 and dist2/2" do
      assert :boids_vec.dot({1, 2}, {3, 4}) == 11
      assert :boids_vec.dot({1, 2, 3}, {4, 5, 6}) == 32
      assert :boids_vec.norm({3, 4}) == 5.0
      assert :boids_vec.norm2({3, 4}) == 25
      assert :boids_vec.norm({2, 3, 6}) == 7.0
      assert :boids_vec.dist({1, 1}, {4, 5}) == 5.0
      assert :boids_vec.dist2({1, 1, 1}, {3, 4, 7}) == 49
    end

    test "lerp/3 gives the two ends and the middle" do
      assert :boids_vec.lerp({0, 0}, {10, 20}, 0) == {0, 0}
      assert :boids_vec.lerp({0, 0}, {10, 20}, 1) == {10, 20}
      assert :boids_vec.lerp({0, 0, 0}, {10, 20, 30}, 0.5) == {5.0, 10.0, 15.0}
    end
  end

  describe "the length of a vector" do
    test "normalize/1 and set_norm/2" do
      assert_vec(:boids_vec.normalize({3, 4}), {0.6, 0.8})
      assert_vec(:boids_vec.set_norm({3, 4}, 10), {6.0, 8.0})
      assert_vec(:boids_vec.set_norm({0, 0, 2}, 5), {0.0, 0.0, 5.0})
    end

    test "a zero vector stays zero" do
      assert :boids_vec.normalize({0, 0}) == {0.0, 0.0}
      assert :boids_vec.normalize({0.0, 0.0, 0.0}) == {0.0, 0.0, 0.0}
      assert :boids_vec.set_norm({0, 0}, 7) == {0.0, 0.0}
    end

    test "limit/2 changes only a vector that is too long" do
      assert :boids_vec.limit({3, 4}, 10) == {3, 4}
      assert :boids_vec.limit({3, 4}, 5) == {3, 4}
      assert_vec(:boids_vec.limit({30, 40}, 5), {3.0, 4.0})
      assert :boids_vec.limit({1, 1, 1}, 0) == {0.0, 0.0, 0.0}
    end

    property "normalize/1 gives the length 1 and keeps the direction" do
      check all(d <- dim(), v <- vec_not_zero(d)) do
        unit = :boids_vec.normalize(v)
        assert_in_delta :boids_vec.norm(unit), 1.0, 1.0e-9
        assert_in_delta :boids_vec.dot(unit, v), :boids_vec.norm(v), 1.0e-6
      end
    end

    property "limit/2 gives a length of the maximum at most" do
      check all(d <- dim(), v <- vec(d), max <- float(min: 0.0, max: 2000.0)) do
        limited = :boids_vec.limit(v, max)
        assert :boids_vec.norm(limited) <= max + 1.0e-9
        if :boids_vec.norm(v) <= max, do: assert(limited == v)
      end
    end
  end

  describe "orthogonal/1" do
    property "gives a vector of length 1 at a right angle" do
      check all(d <- dim(), v <- vec_not_zero(d)) do
        side = :boids_vec.orthogonal(v)
        assert_in_delta :boids_vec.norm(side), 1.0, 1.0e-9
        assert_in_delta :boids_vec.dot(side, v) / :boids_vec.norm(v), 0.0, 1.0e-9
      end
    end

    test "uses the axis that is the least parallel" do
      assert_vec(:boids_vec.orthogonal({1, 0}), {0.0, 1.0})
      assert_vec(:boids_vec.orthogonal({0, 3, 4}), {0.0, -0.8, 0.6})
      assert_vec(:boids_vec.orthogonal({3, 0, 4}), {0.8, 0.0, -0.6})
      assert_vec(:boids_vec.orthogonal({3, 4, 0}), {-0.8, 0.6, 0.0})
    end

    test "a zero vector gives zero" do
      assert :boids_vec.orthogonal({0, 0}) == {0.0, 0.0}
      assert :boids_vec.orthogonal({0, 0, 0}) == {0.0, 0.0, 0.0}
    end
  end

  describe "the random vectors" do
    property "random_unit/1 has the length 1" do
      check all(d <- dim()) do
        unit = :boids_vec.random_unit(d)
        assert tuple_size(unit) == d
        assert_in_delta :boids_vec.norm(unit), 1.0, 1.0e-9
      end
    end

    test "random_unit/1 goes in each direction" do
      :rand.seed(:exsss, 1)

      for d <- [2, 3] do
        sum =
          Enum.reduce(1..2000, :boids_vec.zero(d), fn _, acc ->
            :boids_vec.add(acc, :boids_vec.random_unit(d))
          end)

        assert :boids_vec.norm(sum) / 2000 < 0.1
      end
    end

    property "random_in/2 is in the box" do
      check all(d <- dim(), a <- vec(d), b <- vec(d)) do
        point = :boids_vec.random_in(a, b)

        for {p, x, y} <- Enum.zip([Tuple.to_list(point), Tuple.to_list(a), Tuple.to_list(b)]) do
          assert p >= min(x, y) and p <= max(x, y)
        end
      end
    end
  end

  describe "a box whose sides continue at the opposite sides" do
    test "wrap/3 keeps a point of the box" do
      assert :boids_vec.wrap({1, 2}, {0, 0}, {10, 10}) == {1, 2}
      assert :boids_vec.wrap({0, 0, 0}, {0, 0, 0}, {10, 10, 10}) == {0, 0, 0}
    end

    test "wrap/3 moves a point out of the box into it" do
      assert_vec(:boids_vec.wrap({11, -2}, {0, 0}, {10, 10}), {1.0, 8.0})
      assert_vec(:boids_vec.wrap({10, 25, -31}, {0, 0, -10}, {10, 10, 10}), {0.0, 5.0, 9.0})
      assert_vec(:boids_vec.wrap({-6.0, 7.5}, {-5, -5}, {5, 5}), {4.0, -2.5})
    end

    test "wrap/3 never gives the maximum" do
      assert :boids_vec.wrap({-1.0e-17, 5}, {0, 0}, {10, 10}) == {0, 5}
    end

    property "wrap/3 gives a point of the box at a multiple of its size" do
      check all(d <- dim(), p <- vec(d), min <- vec(d, 100.0), size <- vec(d, 100.0)) do
        size = size |> Tuple.to_list() |> Enum.map(&(abs(&1) + 1.0)) |> List.to_tuple()
        max = :boids_vec.add(min, size)
        wrapped = :boids_vec.wrap(p, min, max)

        for {w, lo, hi, x, s} <-
              Enum.zip([
                Tuple.to_list(wrapped),
                Tuple.to_list(min),
                Tuple.to_list(max),
                Tuple.to_list(p),
                Tuple.to_list(size)
              ]) do
          assert w >= lo and w < hi
          turns = (x - w) / s
          assert_in_delta turns, round(turns), 1.0e-6
        end

        assert :boids_vec.wrap(wrapped, min, max) == wrapped
      end
    end

    test "shortest/3 goes through a side when that is shorter" do
      assert_vec(:boids_vec.shortest({9, -9}, {0, 0}, {10, 10}), {-1.0, 1.0})
      assert_vec(:boids_vec.shortest({2, -3, 6}, {0, 0, 0}, {10, 10, 10}), {2.0, -3.0, -4.0})
    end

    property "shortest/3 is half of the box at most, at a multiple of its size" do
      check all(d <- dim(), delta <- vec(d), size <- vec(d, 100.0)) do
        size = size |> Tuple.to_list() |> Enum.map(&(abs(&1) + 1.0)) |> List.to_tuple()
        short = :boids_vec.shortest(delta, :boids_vec.zero(d), size)

        for {s, x, w} <- Enum.zip([Tuple.to_list(short), Tuple.to_list(delta), Tuple.to_list(size)]) do
          assert abs(s) <= w / 2 + 1.0e-9
          turns = (x - s) / w
          assert_in_delta turns, round(turns), 1.0e-6
        end
      end
    end
  end
end
