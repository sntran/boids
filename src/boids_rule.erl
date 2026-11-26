-module(boids_rule).
-moduledoc """
The behavior of a rule of your own.

A rule is a module with the function `force/4`. Use it in the list
`rules` of a boid as `{Module, Weight}` or `{Module, Weight, Options}`:

```erlang
-module(my_gravity).
-behavior(boids_rule).
-export([options/1, force/4]).

%% Check the options, and give them with their defaults.
options(Options) ->
    #{g := G} = maps:merge(#{g => 9.81}, Options),
    true = is_number(G),
    #{g => G}.

%% A force down.
force(_Boid, _Neighbors, _Env, #{g := G}) ->
    {0, -G}.
```

```erlang
boids:add(Flock, #{pos => {0, 50}, rules => [{my_gravity, 1.0, #{g => 3.7}}, {wander, 0.5}]}).
```

A module is better than a function (`{Fun, Weight}`) when the rule has
options, or when the code of the rule can change while the boids run: a
boid keeps the name of the module, and not a function of its old code.

## The memory of a rule

`force/4` gives a force, or `{Force, Memory}`. With a memory, the next
call for the same boid has it in `Env`, as `memory`. The first call has
`undefined` there. A change of the rules of a boid removes the memory.

```erlang
%% The force turns a quarter of a circle at each step.
force(_Boid, _Neighbors, #{memory := Memory}, _Options) ->
    {X, Y} = case Memory of undefined -> {1, 0}; Last -> Last end,
    {{X, Y}, {-Y, X}}.
```
""".

-doc """
Check the options of the rule, and give them with their defaults. The
library calls this function when a boid gets its rules, also with
options that this function gave before. An error refuses the rule: the
boid then gets the error `{bad_option, {rules, Rule}}`.

Without this function, the rule accepts each map of options.
""".
-callback options(Options :: map()) -> map().

-doc """
The force of the rule for one boid at one step. `Neighbors` are the
boids that the boid sees, the nearest first. `Env` has `dt` (the seconds
of the step), `obstacles`, `bounds`, `wrap` and `memory`. The force has
the size of the position of the boid. The library multiplies it by the
weight of the rule.
""".
-callback force(
    Boid :: boids_boid:boid(),
    Neighbors :: [boids_space:neighbor()],
    Env :: boids_boid:env(),
    Options :: map()
) -> boids_vec:vec() | {boids_vec:vec(), Memory :: term()}.

-optional_callbacks([options/1]).
