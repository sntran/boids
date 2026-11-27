-module(boids_sup).
-moduledoc false.
-behavior(supervisor).

%% The supervisor of the environments that boids:start_environment/1 starts.

-export([start_link/0, init/1]).

start_link() ->
    supervisor:start_link({local, ?MODULE}, ?MODULE, []).

init([]) ->
    Environment = #{
        id => boids_environment_sup,
        start => {boids_environment_sup, start_link, []},
        restart => temporary,
        type => supervisor
    },
    {ok, {#{strategy => simple_one_for_one}, [Environment]}}.
