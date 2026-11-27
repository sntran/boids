defmodule BoidsSite.Showcase do
  @moduledoc """
  The pages of the showcases: `/showcases/NAME` is the page
  `priv/showcases/NAME.html`. An old address of a game moves to its new
  address.
  """
  @behaviour :cowboy_handler

  @games ~w(rock-patrol long-flight flock-lab quiet-herd living-land)

  @doc "The names of the games, in the order of the page of the showcases."
  def games, do: @games

  @impl true
  def init(request, {:moved, to}) do
    {:ok, :cowboy_req.reply(301, %{"location" => to}, request), nil}
  end

  def init(request, state) do
    game = :cowboy_req.binding(:game, request)
    path = game in @games && Path.join([:code.priv_dir(:boids_site), "showcases", game <> ".html"])

    request =
      if path && File.regular?(path) do
        headers = %{"content-type" => "text/html; charset=utf-8"}
        :cowboy_req.reply(200, headers, File.read!(path), request)
      else
        :cowboy_req.reply(404, %{"content-type" => "text/plain"}, "There is no such game.", request)
      end

    {:ok, request, state}
  end
end
