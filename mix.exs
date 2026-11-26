defmodule Boids.MixProject do
  use Mix.Project

  # The library is Erlang code (src/), for Erlang and for Elixir. Mix
  # builds it, runs its tests (ExUnit, test/) and makes its package.
  # rebar3 builds it too (rebar.config, src/boids.app.src).
  @version (fn ->
              {:ok, [{:application, :boids, props}]} =
                :file.consult(Path.expand("src/boids.app.src", __DIR__))

              to_string(props[:vsn])
            end).()

  def project do
    [
      app: :boids,
      version: @version,
      language: :erlang,
      erlc_options: [:debug_info, :warnings_as_errors],
      deps: deps(),
      test_coverage: [summary: [threshold: 100]],
      description: "Boids: flocks of Erlang processes with steering rules",
      package: package(),
      docs: [main: "readme", extras: ["README.md", "CHANGELOG.md", "LICENSE"]]
    ]
  end

  def application do
    [mod: {:boids_app, []}, registered: [:boids_sup]]
  end

  defp deps do
    [
      {:stream_data, "~> 1.4", only: [:dev, :test]},
      {:ex_doc, "~> 0.40", only: :dev, runtime: false}
    ]
  end

  defp package do
    [
      licenses: ["Apache-2.0"],
      links: %{},
      files: ~w(src rebar.config mix.exs README.md CHANGELOG.md LICENSE)
    ]
  end
end
