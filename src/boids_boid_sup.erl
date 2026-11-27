-module(boids_boid_sup).
-moduledoc false.
-behavior(supervisor).

%% The supervisor of the boids of one space. A boid that stops with an
%% error does not start again: it goes from the space, and the other
%% boids continue. A boid that has an error at each step would start
%% again without end.

-export([start_link/0, init/1]).

start_link() ->
    supervisor:start_link(?MODULE, []).

init([]) ->
    %% See boids_space_server:init/1.
    process_flag(priority, high),
    Boid = #{id => gen_boid, start => {gen_boid, start_link, []}, restart => temporary},
    {ok, {#{strategy => simple_one_for_one}, [Boid]}}.
