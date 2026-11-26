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

  @source_url "https://github.com/sntran/boids"

  def project do
    [
      app: :boids,
      version: @version,
      source_url: @source_url,
      language: :erlang,
      erlc_options: [:debug_info, :warnings_as_errors],
      elixirc_paths: elixirc_paths(Mix.env()),
      deps: deps(),
      test_coverage: [
        summary: [threshold: 100],
        ignore_modules: [Boids.FlockSpec, ~r/TestRules/, ~r/TestBoids/]
      ],
      description: "Boids: flocks of Erlang processes with steering rules",
      package: package(),
      docs: [
        main: "readme",
        source_ref: "v#{@version}",
        extras: ["README.md", "docs/specs.md", "CHANGELOG.md", "LICENSE"]
      ]
    ]
  end

  def application do
    [mod: {:boids_app, []}, registered: [:boids_sup]]
  end

  # The replay of the code against the specifications (test/support).
  defp elixirc_paths(:test), do: ["test/support"]
  defp elixirc_paths(_), do: []

  defp deps do
    [
      {:stream_data, "~> 1.4", only: [:dev, :test]},
      # The specifications of the flows in TLA+ (specs/): their model
      # checks with the native checker of Accord (no Java), and the replay
      # of the code (the branch feat/native-tla-checker).
      {:accord,
       github: "sntran/accord",
       ref: "28bd66bbd218e2ac478c0b0e769a23ef0f8efae1",
       only: [:dev, :test],
       runtime: false},
      {:ex_doc, "~> 0.40", only: :dev, runtime: false}
    ]
  end

  defp package do
    [
      licenses: ["Apache-2.0"],
      links: %{"GitHub" => @source_url},
      files: ~w(src rebar.config mix.exs README.md CHANGELOG.md LICENSE)
    ]
  end
end
