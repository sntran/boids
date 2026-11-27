defmodule BoidsExamples.Application do
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
           {"/", :cowboy_static, {:priv_file, :boids_examples, "index.html"}},
           {"/showcases", BoidsExamples.Showcase, :index},
           {"/showcases/:game", BoidsExamples.Showcase, []},
           # The addresses of the first version of the site.
           {"/game", BoidsExamples.Showcase, {:moved, "/showcases/rock-patrol"}},
           {"/flight", BoidsExamples.Showcase, {:moved, "/showcases/long-flight"}},
           {"/playground", :cowboy_static, {:priv_file, :boids_examples, "playground.html"}},
           {"/assets/[...]", :cowboy_static, {:priv_dir, :boids_examples, "assets"}},
           {"/ws/:scene", BoidsExamples.Socket, []}
         ]}
      ])

    BoidsExamples.Scene.setup()
    {:ok, _} = :cowboy.start_clear(:boids_examples_http, [port: port], %{env: %{dispatch: dispatch}})
    Supervisor.start_link([], strategy: :one_for_one, name: BoidsExamples.Supervisor)
  end
end
