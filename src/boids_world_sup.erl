-module(boids_world_sup).
-moduledoc false.
-behavior(supervisor).

%% The supervisor of one world: the process of the world
%% (boids_world, the owner of the tables), and the supervisor of
%% its boids. When the process of the world stops, the tables go. This
%% supervisor then stops too, with the boids: the supervisor above it
%% starts all the world again, or not.

-export([start_link/1, init/1]).

start_link(Opts) ->
    supervisor:start_link(?MODULE, Opts).

init(Opts) ->
    %% See boids_world:init/1.
    process_flag(priority, high),
    Server = #{
        id => boids_world,
        start => {boids_world, start_link, [self(), Opts]},
        restart => temporary,
        significant => true
    },
    Boids = #{id => boids_boid_sup, start => {boids_boid_sup, start_link, []}, type => supervisor},
    {ok, {#{strategy => one_for_one, auto_shutdown => any_significant}, [Server, Boids]}}.
