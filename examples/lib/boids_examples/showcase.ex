defmodule BoidsExamples.Showcase do
  @moduledoc """
  The pages of the showcases. `/showcases` is the list of the games
  (`BoidsExamples.Game.all/0`), and `/showcases/SLUG` is the page of a
  game (`page/0` of its module). An old address of a game moves to its
  new address.
  """
  @behaviour :cowboy_handler

  @impl true
  def init(request, {:moved, to}) do
    {:ok, :cowboy_req.reply(301, %{"location" => to}, request), nil}
  end

  def init(request, :index) do
    {:ok, html(request, 200, index()), :index}
  end

  def init(request, state) do
    slug = :cowboy_req.binding(:game, request)

    request =
      case slug && BoidsExamples.Game.find(slug) do
        nil -> :cowboy_req.reply(404, %{"content-type" => "text/plain"}, "There is no such game.", request)
        module -> html(request, 200, module.page())
      end

    {:ok, request, state}
  end

  @doc "The page of the list of the games."
  def index do
    template = File.read!(Path.join([:code.priv_dir(:boids_examples), "showcases", "index.html"]))
    String.replace(template, "<!-- games -->", Enum.map_join(BoidsExamples.Game.all(), "\n", &item(&1.info())))
  end

  defp item(%{slug: slug, title: title, tag: tag, pitch: pitch, shows: shows, icon: icon}) do
    """
        <li>
          <svg viewBox="0 0 56 56" aria-hidden="true">#{icon}</svg>
          <div>
            <h2><a href="/showcases/#{slug}">#{escape(title)}</a><span class="tag">#{escape(tag)}</span></h2>
            <p class="pitch">#{escape(pitch)}</p>
            <p class="shows">Shows: #{escape(shows)}</p>
          </div>
          <a class="play" href="/showcases/#{slug}">Play</a>
        </li>\
    """
  end

  defp escape(text) do
    text |> String.replace("&", "&amp;") |> String.replace("<", "&lt;") |> String.replace(">", "&gt;")
  end

  defp html(request, status, body) do
    :cowboy_req.reply(status, %{"content-type" => "text/html; charset=utf-8"}, body, request)
  end
end
