defmodule BoidsExamples.GamesTest do
  # Each game of the showcases: its description, its page, and a run of
  # some seconds. A new game gets these tests with no change here. A change
  # of the library that breaks a game fails here.
  use ExUnit.Case, async: false
  alias BoidsExamples.{Game, Scene, Showcase}

  @games Game.all()

  test "the showcases have the games, each with a slug, a title and a place of its own" do
    assert length(@games) >= 5
    infos = Enum.map(@games, & &1.info())
    assert infos |> Enum.map(& &1.slug) |> Enum.uniq() |> length() == length(infos)
    assert infos |> Enum.map(& &1.order) |> Enum.uniq() |> length() == length(infos)
    assert Enum.map(infos, & &1.order) == Enum.sort(Enum.map(infos, & &1.order))

    for info <- infos do
      assert info.slug =~ ~r/^[a-z][a-z-]*[a-z]$/

      for key <- [:title, :tag, :pitch, :shows, :icon] do
        assert is_binary(Map.fetch!(info, key)) and Map.fetch!(info, key) != ""
      end

      assert info.icon =~ "<"
      assert Game.find(info.slug) == Enum.find(@games, &(&1.info().slug == info.slug))
    end

    assert Game.find("no-such-game") == nil
  end

  test "the list of the showcases has each game, and each game has its page" do
    index = Showcase.index()
    refute index =~ "<!-- games -->"

    for game <- @games do
      %{slug: slug, title: title} = game.info()
      assert index =~ ~s(href="/showcases/#{slug}")
      assert index =~ title
      page = game.page()
      assert page =~ ~s(aria-current="page">Showcases)
      # The page connects to the socket of its game.
      assert page =~ ~s(name: "#{slug}")
    end
  end

  test "each game page reads a point of the field with scene.toWorld, and draws all of the field in the scene" do
    for game <- @games do
      %{slug: slug} = game.info()
      page = game.page()
      assert page =~ ~s(<meta name="viewport" content="width=device-width, initial-scale=1">), slug
      # scene.toWorld knows the size of the canvas and the box of the world.
      refute page =~ "clientX - rect.left", "#{slug}: a point of the field with no scene.toWorld"
      # A canvas over the field does not follow the canvas of the scene:
      # the page draws with the options beneath and above.
      refute page =~ ~r/<canvas[^>]*><\/canvas>\s*<canvas/, "#{slug}: a canvas over the field"
    end
  end

  # The scene makes the keys of a game from data of the page (the option
  # keys of Boids.scene): on a phone it changes an arrow of the screen to
  # a direction of the world. The page has no key of its own.
  test "the keys of each game come from data of its page" do
    for game <- @games do
      %{slug: slug} = game.info()
      page = game.page()
      refute page =~ ~r/<button[^>]*data-key=/, "#{slug}: a key in the markup of the page"
      refute page =~ "keys: Object.keys(", "#{slug}: the page sends the keys itself"
    end
  end

  test "the server gives the list, the page of each game, and moves the old addresses" do
    assert {200, _, body} = get("/showcases")
    for game <- @games, do: assert(body =~ game.info().title)
    for game <- @games, do: assert({200, _, _} = get("/showcases/#{game.info().slug}"))
    assert {404, _, _} = get("/showcases/no-such-game")
    assert {301, %{"location" => "/showcases/rock-patrol"}, _} = get("/game")
    assert {301, %{"location" => "/showcases/long-flight"}, _} = get("/flight")
  end

  for game <- Game.all() do
    @game game
    test "#{game.info().title} starts, runs for two seconds, and stops" do
      count = :persistent_term.get(Scene)
      before = :counters.get(count, 1)
      definition = if Scene.waits?(@game), do: apply(@game, :sample, [])
      test = self()

      visitor =
        spawn(fn ->
          send(test, {:started, Scene.start(@game, definition)})
          Process.sleep(:infinity)
        end)

      assert_receive {:started, {:ok, scene}}, 10_000
      header = Scene.header(scene)
      assert [_ | _] = header.kinds
      assert is_binary(IO.iodata_to_binary(:json.encode(header)))

      moments =
        for number <- 1..div(2000, Scene.tick()) do
          Process.sleep(Scene.tick())
          moment = Scene.frame(scene, number)
          assert rem(length(moment.b), 6) == 0
          assert is_binary(IO.iodata_to_binary(:json.encode(moment)))
          moment
        end

      # The game has boids, and they move.
      assert Enum.any?(moments, &(&1.b != []))
      assert hd(moments).b != List.last(moments).b

      # The scene stops with its visitor. A scene of an earlier test can
      # stop in this time too, so the count can go below its first value.
      Process.exit(visitor, :kill)
      assert Enum.any?(1..50, fn _ -> Process.sleep(100) || :counters.get(count, 1) <= before end)
    end
  end

  # A request of HTTP/1.1 to the server of the tests, with gen_tcp. The
  # result is the status, the headers (as a map) and the body.
  defp get(path) do
    port = :ranch.get_port(:boids_examples_http)
    {:ok, socket} = :gen_tcp.connect(~c"127.0.0.1", port, [:binary, active: false])
    :ok = :gen_tcp.send(socket, "GET #{path} HTTP/1.1\r\nhost: localhost\r\nconnection: close\r\n\r\n")
    [head, body] = socket |> read_all("") |> String.split("\r\n\r\n", parts: 2)
    ["HTTP/1.1 " <> status | lines] = String.split(head, "\r\n")

    headers =
      Map.new(lines, fn line ->
        [key, value] = String.split(line, ": ", parts: 2)
        {String.downcase(key), value}
      end)

    {String.to_integer(binary_part(status, 0, 3)), headers, body}
  end

  defp read_all(socket, acc) do
    case :gen_tcp.recv(socket, 0, 5000) do
      {:ok, data} -> read_all(socket, acc <> data)
      {:error, :closed} -> acc
    end
  end
end
