-module(boids_sup).
-moduledoc false.
-behavior(supervisor).

%% The supervisor of the spaces that boids:start_space/1 starts.

-export([start_link/0, init/1]).

start_link() ->
    supervisor:start_link({local, ?MODULE}, ?MODULE, []).

init([]) ->
    Space = #{
        id => boids_space_sup,
        start => {boids_space_sup, start_link, []},
        restart => temporary,
        type => supervisor
    },
    {ok, {#{strategy => simple_one_for_one}, [Space]}}.
