# A flock in the browser: birds that flock, two hawks that hunt them and
# then rest, a convoy that follows its leader, and three rocks.
#
#     mix run examples/web.exs              (then open http://localhost:4000)
#     mix run examples/web.exs 8080         (another port)
#     mix run examples/web.exs record FILE  (a run of 30 seconds in a file)
#
# With `record`, a FILE.html is one page that plays the run with no
# server, and a FILE.json has only the positions.
#
# The example shows the parts of the library:
#
# - the birds are boids of `boids:populate/3`, with rules only;
# - a hawk is a module with the behavior `gen_boid`: it senses its prey,
#   it decides to hunt or to rest, and it acts (it uses its energy);
# - each boid of the convoy has the relation `follows` to the boid
#   before it (`boids:relate/4`), and a rule with that relation;
# - the number of groups comes from the flock as a graph
#   (`boids:graph/2`).

defmodule Web do
  defmodule Hawk do
    @moduledoc "A hawk hunts the birds that it sees while it has energy. Then it rests."
    @behaviour :gen_boid

    @hunt [{:avoid, 4.0, %{lookahead: 1.5}}, {:pursue, 1.0, %{target: {:group, :birds}}}]
    @rest [{:avoid, 4.0, %{lookahead: 1.5}}, {:wander, 1.0}, {:cruise, 0.5, %{speed: 4.0}}]

    @impl true
    def init(options) do
      {:ok,
       Map.merge(%{group: :hawks, perception: 28, rules: @rest, state: %{mode: :rests, energy: 6.0}}, options)}
    end

    # Sense: the prey are the birds that the hawk sees.
    @impl true
    def handle_sense(%{neighbors: neighbors} = seen, boid) do
      {:ok, Map.put(seen, :prey, Enum.filter(neighbors, &(&1.group == :birds))), boid}
    end

    # Decide: hunt with energy and prey, rest with no energy.
    @impl true
    def handle_decide(seen, %{state: %{mode: mode, energy: energy}} = boid) do
      next =
        cond do
          mode == :hunts and energy <= 0.5 -> :rests
          mode == :rests and energy >= 9.5 and seen.prey != [] -> :hunts
          true -> mode
        end

      if next == mode, do: {:ok, boid}, else: {:ok, change(boid, next)}
    end

    # Act: a hunt uses energy, and a rest gives it. The other boids, and
    # the page, see the mode and the energy in the data of the hawk.
    @impl true
    def handle_act(%{state: %{mode: mode, energy: energy} = state} = boid) do
      energy = if mode == :hunts, do: max(energy - 0.04, 0.0), else: min(energy + 0.03, 10.0)
      {:ok, %{boid | state: %{state | energy: energy}, data: {mode, energy}}}
    end

    defp change(boid, :hunts), do: update(boid, :hunts, @hunt, 15.0)
    defp change(boid, :rests), do: update(boid, :rests, @rest, 6.0)

    defp update(boid, mode, rules, speed) do
      boid = :boids_boid.update(boid, %{rules: rules, max_speed: speed})
      %{boid | state: %{boid.state | mode: mode}}
    end
  end

  @width 160
  @height 90
  @groups [:birds, :hawks, :convoy]
  @rocks [{:north, {40, 62}, 7}, {:east, {118, 30}, 9}, {:south, {82, 12}, 5}]

  @doc "Start the flock. The result has the flock, and its boids in a constant order."
  def start(tick) do
    {:ok, flock} =
      :boids.start_flock(
        bounds: {{0, 0}, {@width, @height}},
        wrap: true,
        relations: :acyclic,
        defaults: %{tick: tick}
      )

    for {id, pos, radius} <- @rocks, do: :ok = :boids.set_obstacle(flock, id, pos, radius)

    birds = [
      {:avoid, 4.0, %{lookahead: 1.5}},
      {:evade, 3.0, %{target: {:group, :hawks}, radius: 16}},
      {:separation, 1.5, %{radius: 3}},
      {:alignment, 1.0},
      {:cohesion, 1.0}
    ]

    {:ok, bird_ids} =
      :boids.populate(flock, 140,
        group: :birds,
        rules: birds,
        min_speed: 6,
        max_speed: 12,
        combine: :priority,
        search: 2
      )

    hawk_ids =
      for pos <- [{20, 20}, {140, 70}] do
        {:ok, pid} = :gen_boid.start(Hawk, %{pos: pos, combine: :priority}, flock: flock)
        pid
      end

    # The convoy: a leader that wanders, and boids that each follow the
    # boid before them.
    lead = [{:avoid, 4.0}, {:wander, 1.0}, {:cruise, 1.0, %{speed: 7.0}}]

    {:ok, leader} =
      :boids.add(flock,
        pos: {80, 45},
        vel: {7, 0},
        group: :convoy,
        rules: lead,
        max_speed: 7,
        combine: :priority
      )

    followers =
      for n <- 1..7 do
        rules = [
          {:avoid, 4.0},
          {:leader, 2.0, %{target: {:related, :follows}, distance: 3}},
          {:separation, 1.0, %{radius: 2}}
        ]

        opts = [pos: {80 - 3 * n, 45}, group: :convoy, rules: rules, max_speed: 11, combine: :priority]
        {:ok, id} = :boids.add(flock, opts)
        id
      end

    convoy_ids = [leader | followers]

    for {from, to} <- Enum.zip(followers, convoy_ids) do
      :ok = :boids.relate(flock, from, :follows, to)
    end

    ids = bird_ids ++ hawk_ids ++ convoy_ids
    %{flock: flock, space: :boids.space(flock), ids: ids, hawks: hawk_ids}
  end

  @doc "The things that do not change in a run: the box, the rocks and the relations."
  def header(%{space: space, ids: ids}, more) do
    index = Map.new(Enum.with_index(ids))
    relations = :boids.relations(space)

    Map.merge(
      %{
        box: [@width, @height],
        groups: @groups,
        rocks: for(%{pos: {x, y}, radius: r} <- :boids.obstacles(space), do: [x, y, r]),
        # Each relation, as the numbers of its two boids.
        links: for({from, to, :follows} <- :graph.edges(relations), do: [index[from], index[to]])
      },
      more
    )
  end

  @doc "One moment of the flock: for each boid, its position, its direction and its group."
  def frame(%{space: space, ids: ids, hawks: hawks}, number) do
    boids =
      Enum.flat_map(ids, fn id ->
        {:ok, %{pos: {x, y}, vel: {vx, vy}, group: group}} = :boids.lookup(space, id)

        [
          Float.round(x * 1.0, 1),
          Float.round(y * 1.0, 1),
          Float.round(:math.atan2(vy, vx), 2),
          Enum.find_index(@groups, &(&1 == group))
        ]
      end)

    hawks =
      for id <- hawks do
        case :boids.lookup(space, id) do
          {:ok, %{data: {mode, energy}}} -> [mode, Float.round(energy, 1)]
          _ -> [:rests, 0.0]
        end
      end

    frame = %{n: number, b: boids, h: hawks}

    # The groups of the flock, from the flock as a graph: each second.
    if rem(number, 20) == 0 do
      Map.put(frame, :g, length(:graph.components(:boids.graph(space, 8))))
    else
      frame
    end
  end

  def json(term), do: IO.iodata_to_binary(:json.encode(term))

  # --- A run in a file ---------------------------------------------------

  @doc "Make a run of `seconds` with steps of 50 ms, and write it to a file."
  def record(file, seconds) do
    scene = start(:manual)
    # The first seconds move the birds from random positions to a flock.
    for _ <- 1..100, do: :boids.step(scene.flock, 0.05)

    frames =
      for number <- 1..(seconds * 20) do
        :ok = :boids.step(scene.flock, 0.05)
        frame(scene, number)
      end

    run = json(header(scene, %{frames: frames}))

    case Path.extname(file) do
      ".json" -> File.write!(file, run)
      _ -> File.write!(file, document(["<script>window.BOIDS = ", run, "</script>"]))
    end

    IO.puts(
      "#{file}: #{length(frames)} moments of #{length(scene.ids)} boids, #{div(byte_size(run), 1024)} KB"
    )
  end

  # --- The server --------------------------------------------------------

  @doc "Serve the page and the moments of a flock that moves in real time."
  def serve(port) do
    scene = start(50)

    {:ok, listen} =
      :gen_tcp.listen(port, [:binary, packet: :http_bin, active: false, reuseaddr: true, ip: {127, 0, 0, 1}])

    IO.puts("Open http://localhost:#{port} to see the flock. Stop with Ctrl-C.")
    accept(listen, scene)
  end

  defp accept(listen, scene) do
    {:ok, socket} = :gen_tcp.accept(listen)
    pid = spawn(fn -> request(socket, scene) end)
    :gen_tcp.controlling_process(socket, pid)
    send(pid, :start)
    accept(listen, scene)
  end

  defp request(socket, scene) do
    receive do
      :start -> :ok
    end

    with {:ok, {:http_request, :GET, {:abs_path, path}, _}} <- :gen_tcp.recv(socket, 0, 5000),
         :ok <- headers(socket) do
      :inet.setopts(socket, packet: :raw)

      case path do
        "/" ->
          page = document("<script>window.BOIDS = {live: true}</script>")

          :gen_tcp.send(socket, [
            "HTTP/1.1 200 OK\r\ncontent-type: text/html; charset=utf-8\r\ncontent-length: #{byte_size(page)}\r\nconnection: close\r\n\r\n",
            page
          ])

        "/events" ->
          :gen_tcp.send(
            socket,
            "HTTP/1.1 200 OK\r\ncontent-type: text/event-stream\r\ncache-control: no-cache\r\n\r\n"
          )

          :gen_tcp.send(socket, ["event: start\ndata: ", json(header(scene, %{})), "\n\n"])
          events(socket, scene, 1)

        _ ->
          :gen_tcp.send(socket, "HTTP/1.1 404 Not Found\r\ncontent-length: 0\r\nconnection: close\r\n\r\n")
      end
    end

    :gen_tcp.close(socket)
  end

  defp headers(socket) do
    case :gen_tcp.recv(socket, 0, 5000) do
      {:ok, :http_eoh} -> :ok
      {:ok, _header} -> headers(socket)
      other -> other
    end
  end

  # One moment each 50 ms, until the browser closes the connection.
  defp events(socket, scene, number) do
    case :gen_tcp.send(socket, ["data: ", json(frame(scene, number)), "\n\n"]) do
      :ok ->
        Process.sleep(50)
        events(socket, scene, number + 1)

      {:error, _} ->
        :ok
    end
  end

  # The page is examples/web.html. It has no <html> and no <body> of its
  # own, so that it is also the page of a published run.
  defp document(data) do
    page = File.read!(Path.join(__DIR__, "web.html"))

    IO.iodata_to_binary([
      "<!doctype html>\n<html lang=\"en\">\n<head>\n<meta charset=\"utf-8\">\n",
      "<meta name=\"viewport\" content=\"width=device-width, initial-scale=1, viewport-fit=cover\">\n</head>\n<body>\n",
      data,
      "\n",
      page,
      "\n</body>\n</html>\n"
    ])
  end
end

case System.argv() do
  [] -> Web.serve(4000)
  ["record", file] -> Web.record(file, 30)
  [port] -> Web.serve(String.to_integer(port))
end
