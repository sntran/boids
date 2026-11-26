-module(boids_flock_sup).
-moduledoc false.
-behavior(supervisor).

%% The supervisor of one flock: the process of the flock (boids_flock,
%% the owner of the tables), then the supervisor of its boids. When the
%% process of the flock stops, the tables go, so the boids stop too.

-export([start_link/1, init/1]).

start_link(Opts) ->
    supervisor:start_link(?MODULE, Opts).

init(Opts) ->
    %% See boids_flock:init/1.
    process_flag(priority, high),
    Flock = #{id => boids_flock, start => {boids_flock, start_link, [self(), Opts]}},
    Boids = #{id => boids_boid_sup, start => {boids_boid_sup, start_link, []}, type => supervisor},
    {ok, {#{strategy => rest_for_one}, [Flock, Boids]}}.
