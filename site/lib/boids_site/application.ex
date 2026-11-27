defmodule BoidsSite.Application do
  @moduledoc """
  The site of boids: the pages of `priv/`, and one WebSocket for each
  scene that a visitor sees. The server listens on `PORT` (default 4000).
  """
  use Application

  @impl true
  def start(_type, _args) do
    port = String.to_integer(System.get_env("PORT", "4000"))

    dispatch =
      :cowboy_router.compile([
        {:_,
         [
           {"/", :cowboy_static, {:priv_file, :boids_site, "index.html"}},
           {"/game", :cowboy_static, {:priv_file, :boids_site, "game.html"}},
           {"/flight", :cowboy_static, {:priv_file, :boids_site, "flight.html"}},
           {"/playground", :cowboy_static, {:priv_file, :boids_site, "playground.html"}},
           {"/assets/[...]", :cowboy_static, {:priv_dir, :boids_site, "assets"}},
           {"/ws/:scene", BoidsSite.Socket, []}
         ]}
      ])

    BoidsSite.Scene.setup()
    {:ok, _} = :cowboy.start_clear(:boids_site_http, [port: port], %{env: %{dispatch: dispatch}})
    Supervisor.start_link([], strategy: :one_for_one, name: BoidsSite.Supervisor)
  end
end
