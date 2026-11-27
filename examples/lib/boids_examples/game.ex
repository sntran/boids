defmodule BoidsExamples.Game do
  @moduledoc """
  A game of the showcases. A game is a scene (`BoidsExamples.Scene`) that
  also tells what it is: its address, its title, and what it shows of
  the library.

  Each game is a folder of `examples/` with three files: its module
  (`rock_patrol/rock_patrol.ex`), its page (`rock_patrol.html`) and its
  tests (`rock_patrol_test.exs`). The module has `use BoidsExamples.Game`,
  which puts the page in the module (`page/0`): the page is then a part
  of the release, also on Cloudflare Workers.

  The site and the tests find the games with `all/0`: a new game needs
  only its folder. The common test (`test/games_test.exs`) starts each
  game, runs it for some seconds, and checks its page.
  """

  @doc false
  defmacro __using__(_options) do
    page = Path.rootname(__CALLER__.file) <> ".html"

    quote do
      @behaviour BoidsExamples.Game
      @external_resource unquote(page)
      @boids_examples_page File.read!(unquote(page))

      @doc "The page of the game: the file next to its module, with the extension `.html`."
      @impl BoidsExamples.Game
      def page, do: @boids_examples_page
    end
  end

  @typedoc """
  What a game is:

  - `slug`: the last part of its address, `/showcases/SLUG`, and the name
    of its socket, `/ws/SLUG`;
  - `title`, `pitch` (what the person does), `shows` (what the game shows
    of the library), and `tag` (the kind of control: "Keys", "Cards");
  - `icon`: the inner part of an SVG of 56 by 56, with the classes
    `mark-ink`, `mark-warm`, `mark-cool` and `mark-rock` for its colors;
  - `order`: the place of the game in the list of the showcases.
  """
  @type info :: %{
          slug: String.t(),
          title: String.t(),
          pitch: String.t(),
          shows: String.t(),
          tag: String.t(),
          icon: String.t(),
          order: integer()
        }

  @doc "What the game is."
  @callback info() :: info()

  @doc "The HTML of the page of the game (`use BoidsExamples.Game` gives it)."
  @callback page() :: String.t()

  @doc """
  A definition that starts the game, for a game that waits for a
  definition of its page (`c:BoidsExamples.Scene.waits/0`). The common
  test uses it.
  """
  @callback sample() :: term()

  @optional_callbacks sample: 0

  @doc "The modules of the games, in the order of the showcases."
  @spec all() :: [module()]
  def all do
    {:ok, modules} = :application.get_key(:boids_examples, :modules)

    modules
    |> Enum.filter(&game?/1)
    |> Enum.sort_by(& &1.info().order)
  end

  @doc "The module of the game with this slug, or nil."
  @spec find(String.t()) :: module() | nil
  def find(slug) when is_binary(slug), do: Enum.find(all(), &(&1.info().slug == slug))

  @doc "True for a module with the behavior of a game."
  def game?(module) do
    Code.ensure_loaded?(module) and function_exported?(module, :info, 0) and
      __MODULE__ in List.flatten(Keyword.get_values(module.module_info(:attributes), :behaviour))
  end
end
