-module(boids_boid_sup).
-moduledoc false.
-behavior(supervisor).

%% The supervisor of the boids of one flock. A boid that stops with an
%% error does not start again: it goes from the flock, and the other
%% boids continue. A boid that has an error at each step would start
%% again without end.

-export([start_link/0, init/1]).

start_link() ->
    supervisor:start_link(?MODULE, []).

init([]) ->
    %% See boids_flock:init/1.
    process_flag(priority, high),
    Boid = #{id => boids_server, start => {boids_server, start_link, []}, restart => temporary},
    {ok, {#{strategy => simple_one_for_one}, [Boid]}}.
