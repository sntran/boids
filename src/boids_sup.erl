-module(boids_sup).
-moduledoc false.
-behavior(supervisor).

%% The supervisor of the worlds that boids:start_world/1 starts.

-export([start_link/0, init/1]).

start_link() ->
    supervisor:start_link({local, ?MODULE}, ?MODULE, []).

init([]) ->
    World = #{
        id => boids_world_sup,
        start => {boids_world_sup, start_link, []},
        restart => temporary,
        type => supervisor
    },
    {ok, {#{strategy => simple_one_for_one}, [World]}}.
