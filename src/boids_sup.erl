-module(boids_sup).
-moduledoc false.
-behavior(supervisor).

%% The supervisor of the flocks that boids:start_flock/1 starts.

-export([start_link/0, init/1]).

start_link() ->
    supervisor:start_link({local, ?MODULE}, ?MODULE, []).

init([]) ->
    Flock = #{
        id => boids_flock_sup,
        start => {boids_flock_sup, start_link, []},
        restart => temporary,
        type => supervisor
    },
    {ok, {#{strategy => simple_one_for_one}, [Flock]}}.
