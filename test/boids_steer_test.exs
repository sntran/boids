defmodule BoidsSteerTest do
  use ExUnit.Case, async: true
  use ExUnitProperties
  import Boids.Helpers

  describe "heading/1" do
    test "is the direction of the velocity" do
      assert_vec(:boids_steer.heading(body({0, 0}, {3, 4})), {0.6, 0.8})
      assert :boids_steer.heading(body({0, 0, 0}, {0, 0, 0})) == {0.0, 0.0, 0.0}
    end
  end

  describe "seek/2 and flee/2" do
    test "seek/2 wants the maximum speed to the target" do
      assert_vec(:boids_steer.seek(body({0, 0}, {0, 0}), {10, 0}), {10.0, 0.0})
      assert_vec(:boids_steer.seek(body({0, 0}, {0, 5}), {10, 0}), {10.0, -5.0})
      assert_vec(:boids_steer.seek(body({1, 1, 1}, {0, 0, 0}, 3.0), {1, 1, 5}), {0.0, 0.0, 3.0})
    end

    test "seek/2 at the target stops the boid" do
      assert_vec(:boids_steer.seek(body({5, 5}, {1, 2}), {5, 5}), {-1.0, -2.0})
    end

    test "seek/2 gives no force to a boid that moves to the target at the maximum speed" do
      assert_vec(:boids_steer.seek(body({0, 0}, {6, 8}), {3, 4}), {0.0, 0.0})
    end

    test "flee/2 is the opposite direction" do
      assert_vec(:boids_steer.flee(body({0, 0}, {0, 0}), {10, 0}), {-10.0, 0.0})
      assert_vec(:boids_steer.flee(body({0, 0, 0}, {1, 0, 0}, 2.0), {0, 0, 4}), {-1.0, 0.0, -2.0})
    end

    property "seek/2 and flee/2 want opposite velocities" do
      check all(d <- dim(), pos <- vec(d), vel <- vec(d, 10.0), target <- vec(d)) do
        boid = body(pos, vel)
        seek = :boids_vec.add(:boids_steer.seek(boid, target), vel)
        flee = :boids_vec.add(:boids_steer.flee(boid, target), vel)
        assert_vec(seek, :boids_vec.neg(flee), 1.0e-6)
      end
    end
  end

  describe "arrive/3" do
    test "far from the target, it is seek/2" do
      boid = body({0, 0}, {1, 1})
      assert :boids_steer.arrive(boid, {100, 0}, 10) == :boids_steer.seek(boid, {100, 0})
    end

    test "in the radius, the speed decreases with the distance" do
      assert_vec(:boids_steer.arrive(body({0, 0}, {0, 0}), {5, 0}, 10), {5.0, 0.0})
      assert_vec(:boids_steer.arrive(body({0, 0, 0}, {0, 0, 2}), {0, 0, 1}, 4), {0.0, 0.0, 0.5})
    end

    test "at the target, it stops the boid" do
      assert_vec(:boids_steer.arrive(body({5, 5}, {1, 2}), {5, 5}, 10), {-1.0, -2.0})
      assert_vec(:boids_steer.arrive(body({5, 5}, {1, 2}), {5, 5}, 0), {-1.0, -2.0})
    end
  end

  describe "pursue/4 and evade/4" do
    test "pursue/4 goes to the position of the target after the time to it" do
      # The target is at 10 units: 1 second at the speed 10. It will be at {10, 5}.
      boid = body({0, 0}, {0, 0})
      assert_vec(:boids_steer.pursue(boid, {10, 0}, {0, 5}, :infinity), :boids_steer.seek(boid, {10, 5}))
    end

    test "pursue/4 looks ahead the maximum time at most" do
      boid = body({0, 0}, {0, 0})
      assert_vec(:boids_steer.pursue(boid, {10, 0}, {0, 5}, 0.2), :boids_steer.seek(boid, {10, 1}))
      assert_vec(:boids_steer.pursue(boid, {10, 0}, {0, 5}, 0), :boids_steer.seek(boid, {10, 0}))
    end

    test "evade/4 goes away from that position" do
      boid = body({0, 0, 0}, {0, 0, 0})

      assert_vec(
        :boids_steer.evade(boid, {10, 0, 0}, {0, 5, 0}, :infinity),
        :boids_steer.flee(boid, {10, 5, 0})
      )
    end

    test "a boid with no speed makes no prediction" do
      boid = body({0, 0}, {0, 0}, 0)
      assert :boids_steer.pursue(boid, {10, 0}, {0, 5}, :infinity) == :boids_steer.seek(boid, {10, 0})
    end
  end

  describe "wander/4" do
    test "goes to a point on the circle ahead" do
      # The circle of the radius 1 is 2 units ahead: the point is {2, 1}.
      force = :boids_steer.wander(body({0, 0}, {5, 0}), {0, 1}, 2, 1)
      assert_vec(force, :boids_vec.sub(:boids_vec.set_norm({2, 1}, 10), {5, 0}))
    end

    test "a boid that does not move goes to the point" do
      assert_vec(:boids_steer.wander(body({0, 0, 0}, {0, 0, 0}), {0, 0, 1}, 2, 1), {0.0, 0.0, 10.0})
    end
  end

  describe "separation/2" do
    test "no neighbor gives no force" do
      assert :boids_steer.separation(body({0, 0}, {1, 2}), []) == {0.0, 0.0}
      assert :boids_steer.separation(body({0, 0, 0}, {1, 2, 3}), []) == {0.0, 0.0, 0.0}
    end

    test "moves away from one neighbor" do
      pos = {0, 0}
      assert_vec(:boids_steer.separation(body(pos, {0, 0}), [neighbor(pos, {2, 0})]), {-10.0, 0.0})
      assert_vec(:boids_steer.separation(body(pos, {1, 1}), [neighbor(pos, {0, 3})]), {-1.0, -11.0})
    end

    test "a near neighbor counts more than a far neighbor" do
      pos = {0, 0, 0}
      # {-1/1, 0, 0} and {0, +1/4, 0}: the sum is {-1, 0.25, 0}.
      force =
        :boids_steer.separation(body(pos, {0, 0, 0}), [neighbor(pos, {1, 0, 0}), neighbor(pos, {0, -4, 0})])

      assert_vec(force, :boids_vec.set_norm({-1, 0.25, 0}, 10))
    end

    test "neighbors on opposite sides give no force" do
      pos = {0, 0}
      force = :boids_steer.separation(body(pos, {3, 0}), [neighbor(pos, {2, 0}), neighbor(pos, {-2, 0})])
      assert force == {0.0, 0.0}
    end

    test "a neighbor at the same point gives a random direction" do
      pos = {1, 1}
      force = :boids_steer.separation(body(pos, {0, 0}), [neighbor(pos, pos)])
      assert_in_delta :boids_vec.norm(force), 10.0, 1.0e-9
    end
  end

  describe "alignment/2" do
    test "no neighbor gives no force" do
      assert :boids_steer.alignment(body({0, 0}, {1, 2}), []) == {0.0, 0.0}
    end

    test "wants the mean direction of the neighbors at the maximum speed" do
      pos = {0, 0}
      neighbors = [neighbor(pos, {1, 0}, {0, 2}), neighbor(pos, {5, 5}, {0, 4})]
      assert_vec(:boids_steer.alignment(body(pos, {1, 0}), neighbors), {-1.0, 10.0})
    end

    test "neighbors with opposite velocities give no force" do
      pos = {0, 0, 0}
      neighbors = [neighbor(pos, {1, 0, 0}, {0, 2, 1}), neighbor(pos, {5, 5, 0}, {0, -2, -1})]
      assert :boids_steer.alignment(body(pos, {1, 0, 0}), neighbors) == {0.0, 0.0, 0.0}
    end
  end

  describe "cohesion/2" do
    test "no neighbor gives no force" do
      assert :boids_steer.cohesion(body({0, 0}, {1, 2}), []) == {0.0, 0.0}
      assert :boids_steer.cohesion(body({0, 0, 0}, {1, 2, 3}), []) == {0.0, 0.0, 0.0}
    end

    test "goes to the center of the neighbors" do
      pos = {1, 1}
      boid = body(pos, {0, 1})
      neighbors = [neighbor(pos, {3, 1}), neighbor(pos, {7, 1})]
      assert_vec(:boids_steer.cohesion(boid, neighbors), :boids_steer.seek(boid, {5, 1}))
      assert_vec(:boids_steer.cohesion(boid, neighbors), {10.0, -1.0})
    end
  end

  describe "avoid/4" do
    @obstacle %{pos: {10, 0}, radius: 2}

    test "no obstacle gives no force" do
      assert :boids_steer.avoid(body({0, 0}, {5, 0}), [], 20, 0) == {0.0, 0.0}
      assert :boids_steer.avoid(body({0, 0, 0}, {5, 0, 0}), [], 20, 0) == {0.0, 0.0, 0.0}
    end

    test "an obstacle ahead gives a force to the side, away from its center" do
      # The center is 1 unit to the right of the line of the boid.
      force = :boids_steer.avoid(body({0, 1}, {5, 0}), [@obstacle], 20, 0)
      {x, y} = force
      assert_in_delta x, 0.0, 1.0e-9
      assert y > 0
      # The contact is at 10 - sqrt(4 - 1) units, of 20.
      assert_in_delta y, 10 * (1 - (10 - :math.sqrt(3)) / 20), 1.0e-9
    end

    test "the force increases when the obstacle comes near" do
      far = :boids_steer.avoid(body({0, 1}, {5, 0}), [@obstacle], 20, 0)
      near = :boids_steer.avoid(body({6, 1}, {5, 0}), [@obstacle], 20, 0)
      assert :boids_vec.norm(near) > :boids_vec.norm(far)
    end

    test "an obstacle exactly ahead gives a force at a right angle" do
      force = :boids_steer.avoid(body({0, 0}, {5, 0}), [@obstacle], 20, 0)
      assert_in_delta :boids_vec.dot(force, {1, 0}), 0.0, 1.0e-9
      assert_in_delta :boids_vec.norm(force), 10 * (1 - 8 / 20), 1.0e-9
    end

    test "an obstacle behind, to the side or too far gives no force" do
      assert :boids_steer.avoid(body({20, 0}, {5, 0}), [@obstacle], 20, 0) == {0.0, 0.0}
      assert :boids_steer.avoid(body({0, 3}, {5, 0}), [@obstacle], 20, 0) == {0.0, 0.0}
      assert :boids_steer.avoid(body({0, 0}, {5, 0}), [@obstacle], 7, 0) == {0.0, 0.0}
    end

    test "the clearance makes the obstacle larger" do
      assert :boids_steer.avoid(body({0, 3}, {5, 0}), [@obstacle], 20, 0) == {0.0, 0.0}
      {_, y} = :boids_steer.avoid(body({0, 3}, {5, 0}), [@obstacle], 20, 2)
      assert y > 0
    end

    test "a boid in the clearance of an obstacle ahead gets all the force" do
      force = :boids_steer.avoid(body({7.5, 0.5}, {5, 0}), [@obstacle], 20, 1)
      assert_in_delta :boids_vec.norm(force), 10.0, 1.0e-9
    end

    test "the first obstacle on the way counts" do
      second = %{pos: {5, 0.5}, radius: 1}
      {_, y} = :boids_steer.avoid(body({0, 1}, {5, 0}), [@obstacle, second], 20, 0)
      {_, only} = :boids_steer.avoid(body({0, 1}, {5, 0}), [second], 20, 0)
      assert y == only
    end

    test "a boid that does not move sees no obstacle ahead" do
      assert :boids_steer.avoid(body({0, 0}, {0, 0}), [@obstacle], 20, 0) == {0.0, 0.0}
      assert :boids_steer.avoid(body({0, 0}, {5, 0}), [@obstacle], 0, 0) == {0.0, 0.0}
    end

    test "a boid in an obstacle moves out, away from the center" do
      assert_vec(:boids_steer.avoid(body({9, 0}, {0, 0}), [@obstacle], 0, 0), {-10.0, 0.0})

      assert_vec(
        :boids_steer.avoid(body({10, 1, 0}, {1, 0, 0}), [%{pos: {10, 0, 0}, radius: 2}], 1, 0),
        {0.0, 10.0, 0.0}
      )
    end

    test "a boid at the center of an obstacle continues ahead" do
      assert_vec(:boids_steer.avoid(body({10, 0}, {0, 3}), [@obstacle], 3, 0), {0.0, 10.0})
    end

    test "a boid at the center that does not move goes out in a random direction" do
      force = :boids_steer.avoid(body({10, 0}, {0, 0}), [@obstacle], 0, 0)
      assert_in_delta :boids_vec.norm(force), 10.0, 1.0e-9
    end

    test "in three dimensions, the force is to the side too" do
      force = :boids_steer.avoid(body({0, 0, 1}, {0, 5, 0}), [%{pos: {0, 10, 0}, radius: 2}], 20, 0)
      {x, y, z} = force
      assert_in_delta x, 0.0, 1.0e-9
      assert_in_delta y, 0.0, 1.0e-9
      assert z > 0
    end
  end

  describe "contain/3" do
    @box {{0, 0}, {100, 100}}

    test "in the box, far from the sides, there is no force" do
      assert :boids_steer.contain(body({50, 50}, {3, 4}), @box, 10) == {0.0, 0.0}
    end

    test "near a side, the boid moves away from it at the maximum speed" do
      assert_vec(:boids_steer.contain(body({5, 50}, {-3, 4}), @box, 10), {13.0, 0.0})
      assert_vec(:boids_steer.contain(body({50, 95}, {3, 4}), @box, 10), {0.0, -14.0})
      assert_vec(:boids_steer.contain(body({-20, 120}, {0, 0}), @box, 10), {10.0, -10.0})
    end

    test "with no margin, only a boid out of the box gets a force" do
      assert :boids_steer.contain(body({0, 100}, {1, 1}), @box, 0) == {0.0, 0.0}
      assert_vec(:boids_steer.contain(body({-1, 50}, {1, 1}), @box, 0), {9.0, 0.0})
    end

    test "a margin of more than half of the box is half of the box" do
      assert_vec(:boids_steer.contain(body({40, 60}, {0, 0}), @box, 500), {10.0, -10.0})
      assert :boids_steer.contain(body({50, 50}, {1, 1}), @box, 500) == {0.0, 0.0}
    end

    test "in three dimensions" do
      box = {{0, 0, 0}, {10, 10, 10}}
      assert_vec(:boids_steer.contain(body({1, 5, 9}, {0, 0, 0}, 2.0), box, 2), {2.0, 0.0, -2.0})
    end

    property "a boid out of the box gets a force to the box" do
      check all(pos <- vec(2), vel <- vec(2, 10.0)) do
        {fx, fy} = :boids_steer.contain(body(pos, vel, 20.0), @box, 0)
        {x, y} = pos
        if x < 0, do: assert(fx > 0)
        if x > 100, do: assert(fx < 0)
        if y < 0, do: assert(fy > 0)
        if y > 100, do: assert(fy < 0)
      end
    end
  end

  describe "cruise/2" do
    test "goes faster or slower in the direction of the movement" do
      assert_vec(:boids_steer.cruise(body({0, 0}, {3, 4}), 10), {3.0, 4.0})
      assert_vec(:boids_steer.cruise(body({0, 0}, {3, 4}), 5), {0.0, 0.0})
      assert_vec(:boids_steer.cruise(body({0, 0, 0}, {0, 0, 4}), 1), {0.0, 0.0, -3.0})
    end

    test "a boid that does not move gets no force" do
      assert :boids_steer.cruise(body({0, 0}, {0, 0}), 10) == {0.0, 0.0}
    end
  end

  describe "leader/5" do
    test "goes to the point behind the leader" do
      boid = body({0, 0}, {0, 0})
      assert_vec(:boids_steer.leader(boid, {10, 0}, {2, 0}, 3, 5), :boids_steer.arrive(boid, {7, 0}, 5))

      deep = body({0, 0, 0}, {0, 0, 0})

      assert_vec(
        :boids_steer.leader(deep, {0, 10, 0}, {0, 0, -1}, 3, 5),
        :boids_steer.arrive(deep, {0, 10, 3}, 5)
      )
    end

    test "a boid in the way of the leader also moves away from it" do
      boid = body({12, 1}, {0, 0})
      force = :boids_steer.leader(boid, {10, 0}, {2, 0}, 3, 5)

      assert_vec(
        force,
        :boids_vec.add(
          :boids_steer.arrive(boid, {7, 0}, 5),
          :boids_steer.evade(boid, {10, 0}, {2, 0}, :infinity)
        )
      )

      # Out of the way, at the side of the leader.
      beside = body({10, 4}, {0, 0})
      assert_vec(:boids_steer.leader(beside, {10, 0}, {2, 0}, 3, 5), :boids_steer.arrive(beside, {7, 0}, 5))
    end

    test "a leader that does not move has no direction: the boid goes to it" do
      boid = body({0, 0}, {1, 0})
      assert_vec(:boids_steer.leader(boid, {10, 0}, {0, 0}, 3, 5), :boids_steer.arrive(boid, {10, 0}, 5))
    end
  end

  describe "dodge/4" do
    @me {0, 0}

    test "no neighbor gives no force" do
      assert :boids_steer.dodge(body(@me, {1, 0}), [], 2, 10) == {0.0, 0.0}
      assert :boids_steer.dodge(body({0, 0, 0}, {1, 0, 0}), [], 2, 10) == {0.0, 0.0, 0.0}
    end

    test "moves away from where a neighbor will be at the nearest moment" do
      # The two are the nearest after 5 seconds: the neighbor is then 0.5 unit to the left.
      coming = neighbor(@me, {10, 0.5}, {-1, 0})
      assert_vec(:boids_steer.dodge(body(@me, {1, 0}), [coming], 2, 10), {0.0, -5.0})
    end

    test "the force increases when the moment comes near" do
      far = :boids_steer.dodge(body(@me, {1, 0}), [neighbor(@me, {10, 0.5}, {-1, 0})], 2, 10)
      near = :boids_steer.dodge(body(@me, {1, 0}), [neighbor(@me, {4, 0.5}, {-1, 0})], 2, 10)
      assert :boids_vec.norm(near) > :boids_vec.norm(far)
    end

    test "two boids that will be at the same point go to a side" do
      force = :boids_steer.dodge(body(@me, {1, 0}), [neighbor(@me, {10, 0}, {-1, 0})], 2, 10)
      assert_in_delta :boids_vec.dot(force, {1, 0}), 0.0, 1.0e-9
      assert_in_delta :boids_vec.norm(force), 5.0, 1.0e-9
    end

    test "a neighbor that goes away, that stays far, or that comes late gives no force" do
      boid = body(@me, {1, 0})
      assert :boids_steer.dodge(boid, [neighbor(@me, {10, 0.5}, {3, 0})], 2, 10) == {0.0, 0.0}
      assert :boids_steer.dodge(boid, [neighbor(@me, {10, 0.5}, {1, 0})], 2, 10) == {0.0, 0.0}
      assert :boids_steer.dodge(boid, [neighbor(@me, {10, 3}, {-1, 0})], 2, 10) == {0.0, 0.0}
      assert :boids_steer.dodge(boid, [neighbor(@me, {10, 0.5}, {-1, 0})], 2, 5) == {0.0, 0.0}
      assert :boids_steer.dodge(boid, [neighbor(@me, {10, 0.5}, {-1, 0})], 2, 0) == {0.0, 0.0}
    end

    test "the neighbor that comes first counts" do
      late = neighbor(@me, {10, 0.5}, {-1, 0})
      soon = neighbor(@me, {0.5, 4}, {1, -1})
      boid = body(@me, {1, 0})
      assert :boids_steer.dodge(boid, [late, soon], 2, 10) == :boids_steer.dodge(boid, [soon], 2, 10)
      assert :boids_steer.dodge(boid, [late, soon], 2, 10) != :boids_steer.dodge(boid, [late], 2, 10)
    end
  end

  describe "flow/2" do
    test "wants the maximum speed in the direction of the field" do
      assert_vec(:boids_steer.flow(body({0, 0}, {1, 0}), {0, 2}), {-1.0, 10.0})
      assert_vec(:boids_steer.flow(body({0, 0, 0}, {0, 0, 0}, 2.0), {0, 0, -9}), {0.0, 0.0, -2.0})
    end

    test "a field of zero gives no force" do
      assert :boids_steer.flow(body({0, 0}, {1, 0}), {0, 0}) == {0.0, 0.0}
    end
  end

  describe "follow/5" do
    @path [{0, 0}, {10, 0}, {10, 10}]

    test "goes to the point ahead on the path" do
      boid = body({2, 1}, {0, 0})
      assert_vec(:boids_steer.follow(boid, @path, 3, 0, false), :boids_steer.seek(boid, {5, 0}))
    end

    test "uses the position of the boid after the time of the prediction" do
      boid = body({2, 1}, {2, 0})
      assert_vec(:boids_steer.follow(boid, @path, 3, 1.5, false), :boids_steer.seek(boid, {8, 0}))
    end

    test "continues on the next segment" do
      boid = body({9, 1}, {0, 0})
      assert_vec(:boids_steer.follow(boid, @path, 3, 0, false), :boids_steer.seek(boid, {10, 2}))
    end

    test "uses the nearest segment" do
      boid = body({11, 6}, {0, 0})
      assert_vec(:boids_steer.follow(boid, @path, 2, 0, false), :boids_steer.seek(boid, {10, 8}))
    end

    test "stops at the last point" do
      boid = body({10, 9}, {0, 2})
      assert_vec(:boids_steer.follow(boid, @path, 4, 0, false), :boids_steer.arrive(boid, {10, 10}, 4))
      assert_vec(:boids_steer.follow(body({10, 10}, {0, 2}), @path, 4, 0, false), {0.0, -2.0})
    end

    test "with a loop, continues from the last point to the first point" do
      # The path has 20 units, and the way back has sqrt(200).
      boid = body({10, 9}, {0, 0})
      back = :boids_vec.lerp({10, 10}, {0, 0}, 3 / :math.sqrt(200))
      assert_vec(:boids_steer.follow(boid, @path, 4, 0, true), :boids_steer.seek(boid, back))
    end

    test "with a loop, continues from the end to the start" do
      square = [{0, 0}, {10, 0}, {10, 10}, {0, 10}]
      boid = body({-1, 1}, {0, 0})
      assert_vec(:boids_steer.follow(boid, square, 3, 0, true), :boids_steer.seek(boid, {2, 0}))
    end

    test "a path of one point is its point" do
      boid = body({0, 0}, {1, 0})
      assert_vec(:boids_steer.follow(boid, [{20, 0}], 5, 0, false), :boids_steer.arrive(boid, {20, 0}, 5))
      assert_vec(:boids_steer.follow(boid, [{20, 0}], 5, 0, true), :boids_steer.arrive(boid, {20, 0}, 5))
    end

    test "a segment with no length changes nothing" do
      boid = body({2, 1}, {0, 0})
      path = [{0, 0}, {0, 0}, {10, 0}, {10, 0}]
      assert_vec(:boids_steer.follow(boid, path, 3, 0, false), :boids_steer.seek(boid, {5, 0}))
      assert_vec(:boids_steer.follow(body({20, 0}, {0, 0}), path, 0, 0, false), {-10.0, 0.0})
      assert_vec(:boids_steer.follow(body({-1, 0}, {0, 0}), path, 0, 0, false), {10.0, 0.0})
    end

    test "in three dimensions" do
      boid = body({0, 1, 0}, {0, 0, 0})
      path = [{0, 0, 0}, {0, 0, 10}]
      assert_vec(:boids_steer.follow(boid, path, 5, 0, false), :boids_steer.seek(boid, {0, 0, 5}))
    end
  end
end
