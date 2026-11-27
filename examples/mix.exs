defmodule BoidsExamples.MixProject do
  use Mix.Project

  # The site of the library: a home page, the examples and a playground.
  # It is one Cowboy app. beam.com makes one file of it (app.com), which
  # runs on this computer and on Cloudflare Workers (see README.md).
  def project do
    [
      app: :boids_examples,
      version: "0.1.0",
      elixir: "~> 1.18",
      start_permanent: Mix.env() == :prod,
      deps: deps(),
      # Each game is a folder of examples/ with its module, its page and
      # its tests: rock_patrol/rock_patrol.ex, rock_patrol.html and
      # rock_patrol_test.exs. The folder lib/ has the site.
      elixirc_paths: ["lib" | games()],
      test_paths: ["."],
      test_load_filters: [&test?/1],
      test_ignore_filters: [&(not test?(&1))]
    ]
  end

  # The folders of the games: a folder with a module of its own name.
  defp games do
    for dir <- File.ls!(__DIR__), File.regular?(Path.join([__DIR__, dir, dir <> ".ex"])), do: dir
  end

  # A test is a file *_test.exs in test/ or in the folder of a game.
  defp test?(path) do
    String.ends_with?(path, "_test.exs") and hd(Path.split(path)) in ["test" | games()]
  end

  def application do
    [mod: {BoidsExamples.Application, []}, extra_applications: [:logger]]
  end

  defp deps do
    [
      {:boids, path: ".."},
      {:cowboy, "~> 2.13"}
    ]
  end
end
