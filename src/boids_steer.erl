-module(boids_steer).
-moduledoc """
The steering rules, as functions with no state.

Each function gives a steering force for one boid: the velocity that the
rule wants, minus the velocity of the boid. A force of zero changes
nothing. `boids_boid` multiplies each force by the weight of its rule,
and adds them.

A boid here is a map with `pos`, `vel` and `max_speed`. A neighbor is a
map with `pos`, `vel`, `offset` (the vector from the boid to the
neighbor) and `dist` (the length of `offset`), as `boids_space:near/3`
gives it.
""".

-export([heading/1]).
-export([seek/2, flee/2, arrive/3, pursue/4, evade/4, wander/4]).
-export([separation/2, alignment/2, cohesion/2]).
-export([avoid/4, contain/3, follow/5]).
-export([cruise/2, leader/5, dodge/4, flow/2]).

-export_type([body/0, neighbor/0, obstacle/0]).

-type vec() :: boids_vec:vec().
-type body() :: #{pos := vec(), vel := vec(), max_speed := number(), _ => _}.
-type neighbor() :: #{pos := vec(), vel := vec(), offset := vec(), dist := number(), _ => _}.
-type obstacle() :: #{pos := vec(), radius := number(), _ => _}.

-doc "The direction of the movement: a vector of length 1, or zero for a boid that does not move.".
-spec heading(body()) -> vec().
heading(#{vel := Vel}) -> boids_vec:normalize(Vel).

-doc "Move to the point `Target` at the maximum speed.".
-spec seek(body(), vec()) -> vec().
seek(#{pos := Pos, vel := Vel, max_speed := Max}, Target) ->
    Desired = boids_vec:set_norm(boids_vec:sub(Target, Pos), Max),
    boids_vec:sub(Desired, Vel).

-doc "Move away from the point `Target` at the maximum speed.".
-spec flee(body(), vec()) -> vec().
flee(#{pos := Pos, vel := Vel, max_speed := Max}, Target) ->
    Desired = boids_vec:set_norm(boids_vec:sub(Pos, Target), Max),
    boids_vec:sub(Desired, Vel).

-doc """
Move to the point `Target`, and stop there. The speed decreases from the
distance `SlowRadius`.
""".
-spec arrive(body(), vec(), number()) -> vec().
arrive(#{pos := Pos, vel := Vel, max_speed := Max}, Target, SlowRadius) ->
    Offset = boids_vec:sub(Target, Pos),
    Dist = boids_vec:norm(Offset),
    Speed =
        case Dist < SlowRadius of
            true -> Max * Dist / SlowRadius;
            false -> Max
        end,
    boids_vec:sub(boids_vec:set_norm(Offset, Speed), Vel).

-doc """
Move to the point where a target that moves will be. The target is at
`Pos` with the velocity `Vel`. The prediction looks `MaxTime` seconds
ahead at most.
""".
-spec pursue(body(), vec(), vec(), number() | infinity) -> vec().
pursue(Boid, Pos, Vel, MaxTime) ->
    seek(Boid, predict(Boid, Pos, Vel, MaxTime)).

-doc """
Move away from the point where a target that moves will be. See
`pursue/4`.
""".
-spec evade(body(), vec(), vec(), number() | infinity) -> vec().
evade(Boid, Pos, Vel, MaxTime) ->
    flee(Boid, predict(Boid, Pos, Vel, MaxTime)).

%% The time to the target at the maximum speed gives the prediction.
predict(#{pos := Own, max_speed := Max}, Pos, Vel, MaxTime) ->
    Time =
        case Max > 0 of
            true -> min(boids_vec:dist(Own, Pos) / Max, MaxTime);
            false -> 0.0
        end,
    boids_vec:add(Pos, boids_vec:scale(Vel, Time)).

-doc """
Move in a direction that changes slowly. `Point` is a vector of length 1:
a point on a circle (a sphere in 3D) of the radius `Radius`, at the
distance `Distance` ahead of the boid. The caller moves `Point` a small
random step before each call.
""".
-spec wander(body(), vec(), number(), number()) -> vec().
wander(Boid = #{vel := Vel, max_speed := Max}, Point, Distance, Radius) ->
    Ahead = boids_vec:scale(heading(Boid), Distance),
    Desired = boids_vec:set_norm(boids_vec:add(Ahead, boids_vec:scale(Point, Radius)), Max),
    boids_vec:sub(Desired, Vel).

-doc """
Move away from the neighbors. A near neighbor counts more than a far
neighbor. For a neighbor at the same point, the direction is random.
""".
-spec separation(body(), [neighbor()]) -> vec().
separation(#{vel := Vel, max_speed := Max}, Neighbors) ->
    Zero = boids_vec:zero(boids_vec:dim(Vel)),
    Sum = lists:foldl(fun(N, Acc) -> boids_vec:add(Acc, away(N, Vel)) end, Zero, Neighbors),
    wanted(Sum, Vel, Max).

away(#{dist := Dist}, Vel) when Dist == 0 ->
    boids_vec:random_unit(boids_vec:dim(Vel));
away(#{offset := Offset, dist := Dist}, _Vel) ->
    boids_vec:scale(Offset, -1 / (Dist * Dist)).

-doc "Move in the mean direction of the neighbors.".
-spec alignment(body(), [neighbor()]) -> vec().
alignment(#{vel := Vel, max_speed := Max}, Neighbors) ->
    Zero = boids_vec:zero(boids_vec:dim(Vel)),
    Sum = lists:foldl(fun(#{vel := V}, Acc) -> boids_vec:add(Acc, V) end, Zero, Neighbors),
    wanted(Sum, Vel, Max).

%% The force for a wanted direction. No direction gives no force.
wanted(Direction, Vel, Max) ->
    case boids_vec:norm(Direction) of
        Norm when Norm == 0 -> boids_vec:zero(boids_vec:dim(Vel));
        Norm -> boids_vec:sub(boids_vec:scale(Direction, Max / Norm), Vel)
    end.

-doc "Move to the center of the neighbors.".
-spec cohesion(body(), [neighbor()]) -> vec().
cohesion(#{vel := Vel}, []) ->
    boids_vec:zero(boids_vec:dim(Vel));
cohesion(Boid = #{pos := Pos}, Neighbors) ->
    Zero = boids_vec:zero(boids_vec:dim(Pos)),
    Sum = lists:foldl(fun(#{offset := O}, Acc) -> boids_vec:add(Acc, O) end, Zero, Neighbors),
    Center = boids_vec:add(Pos, boids_vec:scale(Sum, 1 / length(Neighbors))),
    seek(Boid, Center).

-doc """
Move around the obstacles. An obstacle is a circle (a sphere in 3D) with
`pos` and `radius`.

The boid looks the distance `Ahead` along its direction. The first
obstacle that it will touch gives a force to the side, away from the
center of the obstacle. The force increases when the obstacle comes
near. `Clearance` is the distance that the boid keeps from each
obstacle. A boid in an obstacle moves out of it.
""".
-spec avoid(body(), [obstacle()], number(), number()) -> vec().
avoid(Boid = #{pos := Pos, vel := Vel, max_speed := Max}, Obstacles, Ahead, Clearance) ->
    Heading = heading(Boid),
    Threats = [T || O <- Obstacles, T <- threat(Pos, Heading, O, Ahead, Clearance)],
    case lists:sort(Threats) of
        [] ->
            boids_vec:zero(boids_vec:dim(Vel));
        [{_Hit, Urgency, Direction} | _] ->
            boids_vec:scale(Direction, Max * Urgency)
    end.

%% A threat is {Hit, Urgency, Direction}: the distance to the point of
%% contact along the direction of the boid, how much force it needs
%% (0 to 1), and the direction of the force.
threat(Pos, Heading, #{pos := Center, radius := Radius}, Ahead, Clearance) ->
    Offset = boids_vec:sub(Center, Pos),
    Dist = boids_vec:norm(Offset),
    Reach = Radius + Clearance,
    Forward = boids_vec:dot(Offset, Heading),
    Side = boids_vec:sub(Offset, boids_vec:scale(Heading, Forward)),
    SideDist = boids_vec:norm(Side),
    if
        Dist < Radius ->
            %% In the obstacle: move out, away from the center.
            [{-Radius, 1.0, out(Offset, Dist, Heading)}];
        Forward =< 0; SideDist >= Reach ->
            [];
        true ->
            Hit = max(Forward - math:sqrt(Reach * Reach - SideDist * SideDist), 0.0),
            case Hit < Ahead of
                true -> [{Hit, 1 - Hit / Ahead, aside(Side, SideDist, Heading)}];
                false -> []
            end
    end.

%% At the center, each direction goes out: continue ahead.
out(Offset, Dist, Heading) when Dist == 0 ->
    case boids_vec:norm(Heading) of
        Norm when Norm == 0 -> boids_vec:random_unit(boids_vec:dim(Offset));
        _ -> Heading
    end;
out(Offset, Dist, _Heading) ->
    boids_vec:scale(Offset, -1 / Dist).

%% The direction to the side, away from the center. With the center
%% exactly ahead, a side has no better direction than the other.
aside(_Side, SideDist, Heading) when SideDist == 0 ->
    boids_vec:orthogonal(Heading);
aside(Side, SideDist, _Heading) ->
    boids_vec:scale(Side, -1 / SideDist).

-doc """
Stay in the box from `Min` to `Max`. Nearer than `Margin` to a side, or
out of the box, the boid moves away from that side at the maximum speed.
""".
-spec contain(body(), {vec(), vec()}, number()) -> vec().
contain(#{pos := {X, Y}, vel := {Vx, Vy}, max_speed := S}, {{X1, Y1}, {X2, Y2}}, M) ->
    {contain1(X, Vx, X1, X2, M, S), contain1(Y, Vy, Y1, Y2, M, S)};
contain(#{pos := {X, Y, Z}, vel := {Vx, Vy, Vz}, max_speed := S}, {{X1, Y1, Z1}, {X2, Y2, Z2}}, M) ->
    {contain1(X, Vx, X1, X2, M, S), contain1(Y, Vy, Y1, Y2, M, S), contain1(Z, Vz, Z1, Z2, M, S)}.

%% One axis. A margin of more than half of the box is half of the box.
contain1(P, V, Lo, Hi, Margin0, Speed) ->
    Margin = min(Margin0, (Hi - Lo) / 2),
    if
        P < Lo + Margin -> Speed - V;
        P > Hi - Margin -> -Speed - V;
        true -> 0.0
    end.

-doc """
Move along a path: a list of one or more points.

The boid finds the point of the path nearest to its position in
`Predict` seconds. It moves to the point at the distance `Ahead` along
the path from there. With `Loop`, the path continues from its last point
to its first point. Without `Loop`, the boid stops at the last point.
""".
-spec follow(body(), [vec(), ...], number(), number(), boolean()) -> vec().
follow(Boid = #{pos := Pos, vel := Vel}, Path, Ahead, Predict, Loop) ->
    Segments = segments(Path, Loop),
    Total = lists:sum([Length || {_, _, Length} <- Segments]),
    Future = boids_vec:add(Pos, boids_vec:scale(Vel, Predict)),
    Along = nearest(Future, Segments) + Ahead,
    case Loop of
        true when Total > 0 ->
            seek(Boid, point_at(Segments, Along - Total * floor(Along / Total)));
        _ when Along < Total ->
            seek(Boid, point_at(Segments, Along));
        _ ->
            arrive(Boid, lists:last(Path), max(Ahead, 1.0e-9))
    end.

segments(Path = [First | Rest], Loop) ->
    Ends =
        case Loop of
            true -> Rest ++ [First];
            false -> Rest
        end,
    [{A, B, boids_vec:dist(A, B)} || {A, B} <- lists:zip(lists:sublist(Path, length(Ends)), Ends)].

%% The distance along the path of its point nearest to Point.
nearest(Point, Segments) ->
    {_, Along, _} =
        lists:foldl(
            fun({A, B, Length}, {Best, BestAlong, Start}) ->
                T = project(Point, A, B, Length),
                Dist2 = boids_vec:dist2(Point, boids_vec:lerp(A, B, T)),
                case Best =:= none orelse Dist2 < Best of
                    true -> {Dist2, Start + T * Length, Start + Length};
                    false -> {Best, BestAlong, Start + Length}
                end
            end,
            {none, 0.0, 0.0},
            Segments
        ),
    Along.

project(_Point, _A, _B, Length) when Length == 0 ->
    0.0;
project(Point, A, B, Length) ->
    T = boids_vec:dot(boids_vec:sub(Point, A), boids_vec:sub(B, A)) / (Length * Length),
    max(0.0, min(1.0, T)).

point_at([{A, B, Length} | Rest], Along) ->
    case Along =< Length orelse Rest =:= [] of
        true when Length > 0 -> boids_vec:lerp(A, B, min(Along / Length, 1.0));
        true -> A;
        false -> point_at(Rest, Along - Length)
    end.

-doc """
Keep the speed `Speed` in the direction of the movement. A boid that
does not move gets no force.
""".
-spec cruise(body(), number()) -> vec().
cruise(Boid = #{vel := Vel}, Speed) ->
    boids_vec:scale(heading(Boid), Speed - boids_vec:norm(Vel)).

-doc """
Follow a leader at `Pos` with the velocity `Vel`: go to the point at the
distance `Distance` behind it, and stop there (see `arrive/3`). A boid
ahead of the leader, in its way, also moves away from where the leader
will be.
""".
-spec leader(body(), vec(), vec(), number(), number()) -> vec().
leader(Boid = #{pos := Own}, Pos, Vel, Distance, SlowRadius) ->
    Direction = boids_vec:normalize(Vel),
    Behind = boids_vec:sub(Pos, boids_vec:scale(Direction, Distance)),
    Ahead = boids_vec:add(Pos, boids_vec:scale(Direction, Distance)),
    Arrive = arrive(Boid, Behind, SlowRadius),
    case boids_vec:norm2(Direction) > 0 andalso boids_vec:dist(Own, Ahead) =< Distance of
        true -> boids_vec:add(Arrive, evade(Boid, Pos, Vel, infinity));
        false -> Arrive
    end.

-doc """
Move away from the neighbor that comes too near first. For each
neighbor, the boid calculates the moment when the two are the nearest,
if the two keep their velocities. A neighbor counts when that moment is
in the next `Horizon` seconds, and the distance is then less than
`Radius`. The force is away from where that neighbor will be, and it
increases when the moment comes near.
""".
-spec dodge(body(), [neighbor()], number(), number()) -> vec().
dodge(#{vel := Vel, max_speed := Max}, Neighbors, Radius, Horizon) ->
    case lists:sort([Threat || N <- Neighbors, Threat <- approach(Vel, N, Radius, Horizon)]) of
        [] -> boids_vec:zero(boids_vec:dim(Vel));
        [{Time, Away} | _] -> boids_vec:scale(Away, Max * (1 - Time / Horizon))
    end.

%% The moment when a neighbor is the nearest, and the direction away
%% from it then: {Time, Away}.
approach(Vel, #{offset := Offset, vel := Other}, Radius, Horizon) ->
    Relative = boids_vec:sub(Other, Vel),
    case boids_vec:norm2(Relative) of
        Speed2 when Speed2 > 0 ->
            Time = -boids_vec:dot(Offset, Relative) / Speed2,
            Gap = boids_vec:add(Offset, boids_vec:scale(Relative, Time)),
            case boids_vec:norm(Gap) of
                %% The two move apart, or the moment is too far.
                _ when Time =< 0; Time >= Horizon -> [];
                Dist when Dist >= Radius -> [];
                %% The two will be at the same point: go to a side.
                Dist when Dist == 0 -> [{Time, boids_vec:orthogonal(Relative)}];
                Dist -> [{Time, boids_vec:scale(Gap, -1 / Dist)}]
            end;
        _ ->
            %% The two have the same velocity: the distance does not change.
            []
    end.

-doc """
Move in the direction `Direction` at the maximum speed: the vector of a
field at the position of the boid. A zero vector gives no force.
""".
-spec flow(body(), vec()) -> vec().
flow(#{vel := Vel, max_speed := Max}, Direction) ->
    wanted(Direction, Vel, Max).
