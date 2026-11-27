defmodule BoidsSite.MixProject do
  use Mix.Project

  # The site of the library: a home page, the examples and a playground.
  # It is one Cowboy app. beam.com makes one file of it (app.com), which
  # runs on this computer and on Cloudflare Workers (see README.md).
  def project do
    [
      app: :boids_site,
      version: "0.1.0",
      elixir: "~> 1.18",
      start_permanent: Mix.env() == :prod,
      deps: deps()
    ]
  end

  def application do
    [mod: {BoidsSite.Application, []}, extra_applications: [:logger]]
  end

  defp deps do
    [
      {:boids, path: ".."},
      {:cowboy, "~> 2.13"}
    ]
  end
end
