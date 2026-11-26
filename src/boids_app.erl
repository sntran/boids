-module(boids_app).
-moduledoc false.
-behavior(application).

-export([start/2, stop/1]).

start(_Type, _Args) ->
    boids_sup:start_link().

stop(_State) ->
    ok.
