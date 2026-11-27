-module(boids_space_sup).
-moduledoc false.
-behavior(supervisor).

%% The supervisor of one space: the process of the space
%% (boids_space_server, the owner of the tables), and the supervisor of
%% its boids. When the process of the space stops, the tables go. This
%% supervisor then stops too, with the boids: the supervisor above it
%% starts all the space again, or not.

-export([start_link/1, init/1]).

start_link(Opts) ->
    supervisor:start_link(?MODULE, Opts).

init(Opts) ->
    %% See boids_space_server:init/1.
    process_flag(priority, high),
    Server = #{
        id => boids_space_server,
        start => {boids_space_server, start_link, [self(), Opts]},
        restart => temporary,
        significant => true
    },
    Boids = #{id => boids_boid_sup, start => {boids_boid_sup, start_link, []}, type => supervisor},
    {ok, {#{strategy => one_for_one, auto_shutdown => any_significant}, [Server, Boids]}}.
