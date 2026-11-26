-module(boids_flock_sup).
-moduledoc false.
-behavior(supervisor).

%% The supervisor of one flock: the process of the flock (boids_flock,
%% the owner of the tables), and the supervisor of its boids. When the
%% process of the flock stops, the tables go. This supervisor then stops
%% too, with the boids: the supervisor above it starts all the flock
%% again, or not.

-export([start_link/1, init/1]).

start_link(Opts) ->
    supervisor:start_link(?MODULE, Opts).

init(Opts) ->
    %% See boids_flock:init/1.
    process_flag(priority, high),
    Flock = #{
        id => boids_flock,
        start => {boids_flock, start_link, [self(), Opts]},
        restart => temporary,
        significant => true
    },
    Boids = #{id => boids_boid_sup, start => {boids_boid_sup, start_link, []}, type => supervisor},
    {ok, {#{strategy => one_for_one, auto_shutdown => any_significant}, [Flock, Boids]}}.
