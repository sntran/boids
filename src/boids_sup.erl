-module(boids_sup).
-moduledoc false.
-behavior(supervisor).

%% The supervisor of the application: the group of the worlds of all the
%% nodes (a scope of pg), and the supervisor of the worlds that
%% boids:start_world/1 starts (boids_worlds).

-export([start_link/0, start_link/1, init/1]).

start_link() ->
    supervisor:start_link({local, ?MODULE}, ?MODULE, top).

start_link(worlds) ->
    supervisor:start_link({local, boids_worlds}, ?MODULE, worlds).

init(top) ->
    Group = #{id => pg, start => {pg, start_link, [boids]}},
    Worlds = #{id => boids_worlds, start => {?MODULE, start_link, [worlds]}, type => supervisor},
    {ok, {#{strategy => one_for_one}, [Group, Worlds]}};
init(worlds) ->
    World = #{
        id => boids_world_sup,
        start => {boids_world_sup, start_link, []},
        restart => temporary,
        type => supervisor
    },
    {ok, {#{strategy => simple_one_for_one}, [World]}}.
