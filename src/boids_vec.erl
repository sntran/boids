-module(boids_vec).
-moduledoc """
Vectors of two or three numbers.

A vector is a tuple: `{X, Y}` or `{X, Y, Z}`. The vectors of one call
have the same size.
""".

-export([zero/1, dim/1, add/2, sub/2, scale/2, neg/1, dot/2]).
-export([norm/1, norm2/1, dist/2, dist2/2]).
-export([normalize/1, set_norm/2, limit/2, lerp/3]).
-export([orthogonal/1, random_unit/1, random_in/2]).
-export([wrap/3, shortest/3]).

-export_type([vec/0]).

-type vec() :: {number(), number()} | {number(), number(), number()}.

-doc "The vector of size `Dim` with each number 0.".
-spec zero(2 | 3) -> vec().
zero(2) -> {0.0, 0.0};
zero(3) -> {0.0, 0.0, 0.0}.

-doc "The size of a vector: 2 or 3.".
-spec dim(vec()) -> 2 | 3.
dim({_, _}) -> 2;
dim({_, _, _}) -> 3.

-doc "The sum of two vectors.".
-spec add(vec(), vec()) -> vec().
add({X1, Y1}, {X2, Y2}) -> {X1 + X2, Y1 + Y2};
add({X1, Y1, Z1}, {X2, Y2, Z2}) -> {X1 + X2, Y1 + Y2, Z1 + Z2}.

-doc "The vector from `B` to `A`: `A - B`.".
-spec sub(vec(), vec()) -> vec().
sub({X1, Y1}, {X2, Y2}) -> {X1 - X2, Y1 - Y2};
sub({X1, Y1, Z1}, {X2, Y2, Z2}) -> {X1 - X2, Y1 - Y2, Z1 - Z2}.

-doc "The vector `V` multiplied by the number `K`.".
-spec scale(vec(), number()) -> vec().
scale({X, Y}, K) -> {X * K, Y * K};
scale({X, Y, Z}, K) -> {X * K, Y * K, Z * K}.

-doc "The opposite vector.".
-spec neg(vec()) -> vec().
neg({X, Y}) -> {-X, -Y};
neg({X, Y, Z}) -> {-X, -Y, -Z}.

-doc "The dot product of two vectors.".
-spec dot(vec(), vec()) -> number().
dot({X1, Y1}, {X2, Y2}) -> X1 * X2 + Y1 * Y2;
dot({X1, Y1, Z1}, {X2, Y2, Z2}) -> X1 * X2 + Y1 * Y2 + Z1 * Z2.

-doc "The length of a vector.".
-spec norm(vec()) -> float().
norm(V) -> math:sqrt(dot(V, V)).

-doc "The square of the length of a vector.".
-spec norm2(vec()) -> number().
norm2(V) -> dot(V, V).

-doc "The distance between two points.".
-spec dist(vec(), vec()) -> float().
dist(A, B) -> norm(sub(A, B)).

-doc "The square of the distance between two points.".
-spec dist2(vec(), vec()) -> number().
dist2(A, B) -> norm2(sub(A, B)).

-doc "The vector of length 1 with the direction of `V`. A zero vector stays zero.".
-spec normalize(vec()) -> vec().
normalize(V) -> set_norm(V, 1.0).

-doc "The vector of length `Length` with the direction of `V`. A zero vector stays zero.".
-spec set_norm(vec(), number()) -> vec().
set_norm(V, Length) ->
    case norm(V) of
        N when N == 0 -> zero(dim(V));
        N -> scale(V, Length / N)
    end.

-doc "The vector `V`, with a length of `Max` at most.".
-spec limit(vec(), number()) -> vec().
limit(V, Max) ->
    case norm2(V) > Max * Max of
        true -> set_norm(V, Max);
        false -> V
    end.

-doc "The point between `A` and `B`: `A` for `T = 0`, `B` for `T = 1`.".
-spec lerp(vec(), vec(), number()) -> vec().
lerp(A, B, T) -> add(A, scale(sub(B, A), T)).

-doc """
A vector of length 1 at a right angle to `V`. For a zero vector, the
result is zero.
""".
-spec orthogonal(vec()) -> vec().
orthogonal({X, Y}) ->
    normalize({-Y, X});
orthogonal({X, Y, Z}) when abs(X) =< abs(Y), abs(X) =< abs(Z) ->
    %% The cross product with the axis that is the least parallel.
    normalize({0.0, -Z, Y});
orthogonal({X, Y, Z}) when abs(Y) =< abs(Z) ->
    normalize({Z, 0.0, -X});
orthogonal({X, Y, _Z}) ->
    normalize({-Y, X, 0.0}).

-doc """
A random vector of length 1, with the generator `rand` of the process.
Each direction has the same probability.
""".
-spec random_unit(2 | 3) -> vec().
random_unit(2) ->
    A = rand:uniform() * 2 * math:pi(),
    {math:cos(A), math:sin(A)};
random_unit(3) ->
    A = rand:uniform() * 2 * math:pi(),
    Z = rand:uniform() * 2 - 1,
    R = math:sqrt(1 - Z * Z),
    {R * math:cos(A), R * math:sin(A), Z}.

-doc "A random point of the box from `Min` to `Max`.".
-spec random_in(vec(), vec()) -> vec().
random_in({X1, Y1}, {X2, Y2}) ->
    {between(X1, X2), between(Y1, Y2)};
random_in({X1, Y1, Z1}, {X2, Y2, Z2}) ->
    {between(X1, X2), between(Y1, Y2), between(Z1, Z2)}.

between(Min, Max) -> Min + rand:uniform() * (Max - Min).

-doc """
The point `P` in the box from `Min` to `Max`, when each side of the box
continues at the opposite side. Each number of the result is in
`[Min, Max)`.
""".
-spec wrap(vec(), vec(), vec()) -> vec().
wrap({X, Y}, {X1, Y1}, {X2, Y2}) ->
    {wrap1(X, X1, X2), wrap1(Y, Y1, Y2)};
wrap({X, Y, Z}, {X1, Y1, Z1}, {X2, Y2, Z2}) ->
    {wrap1(X, X1, X2), wrap1(Y, Y1, Y2), wrap1(Z, Z1, Z2)}.

wrap1(X, Min, Max) when X >= Min, X < Max ->
    X;
wrap1(X, Min, Max) ->
    Size = Max - Min,
    case X - Size * floor((X - Min) / Size) of
        %% The limit of the precision can give Max.
        W when W >= Max -> Min;
        W -> W
    end.

-doc """
The shortest vector that is equal to the difference `D` in the box from
`Min` to `Max`, when each side of the box continues at the opposite side.
""".
-spec shortest(vec(), vec(), vec()) -> vec().
shortest({X, Y}, {X1, Y1}, {X2, Y2}) ->
    {shortest1(X, X2 - X1), shortest1(Y, Y2 - Y1)};
shortest({X, Y, Z}, {X1, Y1, Z1}, {X2, Y2, Z2}) ->
    {shortest1(X, X2 - X1), shortest1(Y, Y2 - Y1), shortest1(Z, Z2 - Z1)}.

%% Most differences are short already.
shortest1(D, Size) when 2 * D =< Size, 2 * D >= -Size -> D;
shortest1(D, Size) -> D - Size * round(D / Size).
