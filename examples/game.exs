# Rock Patrol: a small game in the browser. A ship flies in a field of
# rocks. A queen and its drones hunt the ship.
#
#     mix run examples/game.exs              (then open http://localhost:4000)
#     mix run examples/game.exs 8080         (another port)
#     mix run examples/game.exs record FILE  (a run of 40 seconds in a file)
#
# Keys: the left and right arrows turn the ship, the up arrow gives
# thrust, and the space bar shoots. With no key for 5 seconds, an
# autopilot flies the ship.
#
# Each thing in the game is a boid: one process with the behavior
# `gen_boid`. The example shows the parts of the library:
#
# - Ship: a boid that a person controls. Its force is a rule of its own
#   (a function).
# - Rock: a boid that gets a message when a shot hits it. It starts two
#   smaller rocks, and stops.
# - Shot: a boid that lives for a short time. It senses what it hits, and
#   sends a message to that boid.
# - Drone: it follows its queen by a relation (`boids:relate/4`), and it
#   hunts the ship when it sees the ship.
# - Queen: it starts new drones.
# - The number of swarms comes from the flock as a graph
#   (`boids:graph/2`).

defmodule Game do
  @width 160
  @height 90
  @kinds [:ship, :rocks, :drones, :queen, :shots]

  def turn({x, y}, angle) do
    {x * :math.cos(angle) - y * :math.sin(angle), x * :math.sin(angle) + y * :math.cos(angle)}
  end

  def direction(angle), do: {:math.cos(angle), :math.sin(angle)}

  @doc "The distance at which a shot or the ship touches a boid."
  def radius(%{group: :rocks, data: size}), do: size * 2.2
  def radius(%{group: :queen}), do: 3.0
  def radius(_other), do: 1.5

  defmodule Rock do
    @moduledoc "A rock moves in a line. A hit makes two smaller rocks of it."
    @behaviour :gen_boid

    @impl true
    def init(%{pos: pos, vel: vel, size: size, flock: flock}) do
      speed = :boids_vec.norm(vel)

      {:ok,
       %{
         pos: pos,
         vel: vel,
         group: :rocks,
         data: size,
         perception: 12,
         min_speed: speed * 0.6,
         max_speed: speed * 1.4,
         rules: [{:cruise, 1.0, %{speed: speed}}, {:separation, 2.0, %{radius: size * 3.0, groups: [:rocks]}}],
         state: flock
       }}
    end

    @impl true
    def handle_cast(:hit, %{data: size, pos: pos, vel: vel, state: flock} = boid) do
      if size > 1 do
        for angle <- [-0.7, 0.7] do
          part = %{pos: pos, vel: :boids_vec.scale(Game.turn(vel, angle), 1.4), size: size - 1, flock: flock}
          {:ok, _} = :gen_boid.start(Rock, part, flock: flock)
        end
      end

      {:stop, :normal, boid}
    end
  end

  defmodule Shot do
    @moduledoc "A shot moves in a line for 1.2 seconds. It tells the boid that it hits, and stops."
    @behaviour :gen_boid

    @impl true
    def init(%{pos: pos, vel: vel, ship: ship}) do
      speed = :boids_vec.norm(vel)

      {:ok,
       %{
         pos: pos,
         vel: vel,
         group: :shots,
         perception: 8,
         rules: [],
         min_speed: speed,
         max_speed: speed,
         state: %{ship: ship, steps: 24}
       }}
    end

    # Decide: a target at the distance of its radius is hit.
    @impl true
    def handle_decide(%{neighbors: neighbors}, %{state: %{ship: ship}} = boid) do
      case Enum.find(neighbors, &(&1.group in [:rocks, :drones, :queen] and &1.dist <= Game.radius(&1))) do
        nil ->
          {:ok, boid}

        target ->
          # The id of a boid is its process.
          :gen_boid.cast(target.id, :hit)
          :gen_boid.cast(ship, {:scored, target.group})
          {:stop, :normal, boid}
      end
    end

    @impl true
    def handle_act(%{state: %{steps: 0}} = boid), do: {:stop, :normal, boid}
    def handle_act(%{state: state} = boid), do: {:ok, %{boid | state: %{state | steps: state.steps - 1}}}
  end

  defmodule Drone do
    @moduledoc "A drone stays near its queen. It hunts the ship when it sees the ship."
    @behaviour :gen_boid

    @swarm [
      {{:separation, :rocks}, 3.0, %{radius: 7, groups: [:rocks]}},
      {:separation, 1.5, %{radius: 3}},
      {:alignment, 0.8},
      {:cohesion, 0.8}
    ]
    @escort [{:leader, 1.5, %{target: {:related, :guards}, distance: 6}} | @swarm]
    @hunt [{:pursue, 2.5, %{target: {:group, :ship}}} | @swarm]

    @impl true
    def init(pos) do
      {:ok,
       %{
         pos: pos,
         group: :drones,
         perception: 26,
         max_speed: 13,
         min_speed: 4,
         rules: @escort,
         state: :escorts
       }}
    end

    @impl true
    def handle_decide(%{neighbors: neighbors}, %{state: mode} = boid) do
      case {Enum.any?(neighbors, &(&1.group == :ship)), mode} do
        {true, :escorts} -> {:ok, %{:boids_boid.update(boid, %{rules: @hunt}) | state: :hunts}}
        {false, :hunts} -> {:ok, %{:boids_boid.update(boid, %{rules: @escort}) | state: :escorts}}
        _ -> {:ok, boid}
      end
    end

    @impl true
    def handle_cast(:hit, boid), do: {:stop, :normal, boid}
  end

  defmodule Queen do
    @moduledoc "A queen moves slowly, and starts a new drone each 2.5 seconds. Five hits stop it."
    @behaviour :gen_boid

    @impl true
    def init(%{pos: pos, flock: flock}) do
      rules = [
        {{:separation, :rocks}, 3.0, %{radius: 10, groups: [:rocks]}},
        {:wander, 1.0},
        {:cruise, 1.0, %{speed: 5.0}}
      ]

      {:ok,
       %{
         pos: pos,
         group: :queen,
         data: 5,
         perception: 16,
         max_speed: 6,
         rules: rules,
         state: %{flock: flock, steps: 0}
       }}
    end

    @impl true
    def handle_act(%{id: id, pos: pos, state: %{flock: flock, steps: steps} = state} = boid) do
      if rem(steps, 50) == 49 and length(:boids.related_to(flock, id, :guards)) < 12 do
        Queen.drone(flock, id, pos)
      end

      {:ok, %{boid | state: %{state | steps: steps + 1}}}
    end

    @impl true
    def handle_cast(:hit, %{data: 1} = boid), do: {:stop, :normal, boid}
    def handle_cast(:hit, %{data: left} = boid), do: {:noreply, %{boid | data: left - 1}}

    @doc "Start a drone that guards a queen."
    def drone(flock, queen, {x, y}) do
      {:ok, drone} =
        :gen_boid.start(Drone, {x + :rand.uniform() * 4 - 2, y + :rand.uniform() * 4 - 2}, flock: flock)

      :boids.relate(flock, drone, :guards, queen)
    end
  end

  defmodule Ship do
    @moduledoc """
    The ship. A person controls it, or an autopilot. Its state has the
    keys of the person, the direction of the ship, its shield and the
    score. Its data shows them to the page.
    """
    @behaviour :gen_boid

    # The autopilot: stay away from the rocks, and move to the drones.
    @auto [
      {{:separation, :rocks}, 5.0, %{radius: 16, groups: [:rocks]}},
      {:dodge, 3.0, %{radius: 6, horizon: 1.5}},
      {:pursue, 0.8, %{target: {:group, :drones}}},
      {:wander, 0.6},
      {:cruise, 0.6, %{speed: 12.0}}
    ]

    @impl true
    def init(flock) do
      state = %{
        flock: flock,
        keys: %{},
        idle: 1000,
        heading: 0.0,
        fire: false,
        wait: 0,
        safe: 60,
        shield: 3,
        score: 0,
        wrecks: 0
      }

      {:ok,
       %{
         pos: {80, 45},
         group: :ship,
         perception: 34,
         max_speed: 28,
         max_force: 40,
         rules: @auto,
         state: state,
         data: show(state)
       }}
    end

    # The force of the ship with the keys of a person: thrust in its
    # direction, and a small force against its movement.
    def engine(%{vel: vel, state: %{keys: keys, heading: heading}}, _neighbors, _env) do
      thrust = if keys[:thrust], do: 32.0, else: 0.0
      :boids_vec.add(:boids_vec.scale(Game.direction(heading), thrust), :boids_vec.scale(vel, -0.5))
    end

    # Decide: damage from a rock or a drone that touches the ship, then
    # the direction and the trigger, from the keys or from the autopilot.
    @impl true
    def handle_decide(%{neighbors: neighbors, dt: dt}, %{state: state} = boid) do
      threats = Enum.filter(neighbors, &(&1.group in [:rocks, :drones, :queen]))
      state = damage(state, Enum.any?(threats, &(&1.dist <= Game.radius(&1) + 1.2)))
      manual = state.idle < 100

      {heading, fire} =
        if manual do
          turn = if(state.keys[:left], do: 3.5, else: 0.0) - if state.keys[:right], do: 3.5, else: 0.0
          {state.heading + turn * dt, state.keys[:fire] == true}
        else
          aim(state.heading, threats, dt)
        end

      state = %{state | heading: heading, fire: fire, idle: state.idle + 1}
      rules = if manual, do: [{&Ship.engine/3, 1.0}], else: @auto
      {:ok, %{:boids_boid.update(boid, %{rules: rules}) | state: state}}
    end

    # Act: shoot, and show the state to the page.
    @impl true
    def handle_act(%{pos: pos, vel: vel, state: state} = boid) do
      state =
        if state.fire and state.wait == 0 do
          forward = Game.direction(state.heading)

          shot = %{
            pos: :boids_vec.add(pos, :boids_vec.scale(forward, 2.5)),
            vel: :boids_vec.add(:boids_vec.scale(forward, 45.0), vel),
            ship: self()
          }

          {:ok, _} = :gen_boid.start(Shot, shot, flock: state.flock)
          %{state | wait: 5}
        else
          %{state | wait: max(state.wait - 1, 0)}
        end

      {:ok, %{boid | state: state, data: show(state)}}
    end

    @impl true
    def handle_cast({:keys, keys}, %{state: state} = boid),
      do: {:noreply, %{boid | state: %{state | keys: keys, idle: 0}}}

    def handle_cast({:scored, group}, %{state: state} = boid) do
      points = %{rocks: 10, drones: 25, queen: 50}[group]
      {:noreply, %{boid | state: %{state | score: state.score + points}}}
    end

    # A hit removes one part of the shield. The ship is then safe for 3
    # seconds. With no shield, the ship is a wreck: the score starts again.
    defp damage(%{safe: safe} = state, _touched) when safe > 0, do: %{state | safe: safe - 1}
    defp damage(state, false), do: state

    defp damage(%{shield: 1} = state, true),
      do: %{state | shield: 3, score: 0, wrecks: state.wrecks + 1, safe: 60}

    defp damage(state, true), do: %{state | shield: state.shield - 1, safe: 60}

    # The autopilot turns to the nearest target, and shoots when the
    # target is in front of the ship.
    defp aim(heading, [], _dt), do: {heading, false}

    defp aim(heading, [%{offset: {x, y}, dist: dist} | _], dt) do
      error = :math.atan2(y, x) - heading
      error = :math.atan2(:math.sin(error), :math.cos(error))
      {heading + max(min(error, 5.0 * dt), -5.0 * dt), abs(error) < 0.15 and dist < 30}
    end

    defp show(state) do
      %{
        heading: state.heading,
        shield: state.shield,
        score: state.score,
        wrecks: state.wrecks,
        auto: state.idle >= 100,
        thrust: state.keys[:thrust] == true and state.idle < 100,
        safe: state.safe > 0
      }
    end
  end

  # --- The game ----------------------------------------------------------

  @doc "Start the flock of the game: the ship, six rocks, and a queen with its drones."
  def start(tick) do
    {:ok, flock} =
      :boids.start_flock(
        bounds: {{0, 0}, {@width, @height}},
        wrap: true,
        cell_size: 12,
        defaults: %{tick: tick}
      )

    space = :boids.space(flock)
    {:ok, ship} = :gen_boid.start(Ship, space, flock: space)
    scene = %{flock: flock, space: space, ship: ship}
    for _ <- 1..6, do: rock(scene)
    queen(scene)
    scene
  end

  @doc "Keep the game alive: new rocks for the rocks that are gone, and a new queen."
  def direct(%{space: space} = scene) do
    groups = Enum.frequencies_by(:boids.snapshot(space), & &1.group)
    if Map.get(groups, :rocks, 0) < 7, do: rock(scene)
    if Map.get(groups, :queen, 0) == 0, do: queen(scene)
    :ok
  end

  # A large rock at a side of the box, not near the ship.
  defp rock(%{space: space, ship: ship}) do
    {:ok, %{pos: at}} = :boids.lookup(space, ship)
    pos = Enum.random([{:rand.uniform() * @width, 0.0}, {0.0, :rand.uniform() * @height}])

    if :boids_vec.norm(:boids_space.offset(space, at, pos)) > 30 do
      vel = :boids_vec.scale(:boids_vec.random_unit(2), 3.0 + :rand.uniform() * 3.0)
      {:ok, _} = :gen_boid.start(Rock, %{pos: pos, vel: vel, size: 3, flock: space}, flock: space)
    end
  end

  defp queen(%{space: space}) do
    pos = {:rand.uniform() * @width, :rand.uniform() * 20.0}
    {:ok, queen} = :gen_boid.start(Queen, %{pos: pos, flock: space}, flock: space)
    for _ <- 1..7, do: Queen.drone(space, queen, pos)
  end

  @doc "One moment of the game, for the page."
  def frame(%{space: space, ship: ship}, number) do
    rows = :boids.snapshot(space)

    boids =
      Enum.flat_map(rows, fn %{id: id, pos: {x, y}, vel: {vx, vy}, group: group, data: data} ->
        {angle, size} =
          case {group, data} do
            {:ship, %{heading: heading, shield: shield}} -> {heading, shield}
            {:rocks, size} -> {:math.atan2(vy, vx), size}
            {:queen, left} -> {:math.atan2(vy, vx), left}
            _ -> {:math.atan2(vy, vx), 0}
          end

        [
          number(id),
          Float.round(x * 1.0, 1),
          Float.round(y * 1.0, 1),
          Float.round(angle * 1.0, 2),
          Enum.find_index(@kinds, &(&1 == group)),
          size
        ]
      end)

    status =
      case :boids.lookup(space, ship) do
        {:ok, %{data: d}} -> [d.score, d.shield, d.wrecks, flag(d.auto), flag(d.thrust), flag(d.safe)]
        _ -> [0, 0, 0, 1, 0, 0]
      end

    frame = %{n: number, b: boids, s: status}

    # Each second: the relations of the drones, and the number of swarms,
    # from the flock as a graph.
    if rem(number, 20) == 0 do
      drones = for %{id: id, group: :drones} <- rows, do: id
      swarms = :graph.components(:graph.subgraph(:boids.graph(space, 8), drones))
      links = for {from, to, :guards} <- :graph.edges(:boids.relations(space)), do: [number(from), number(to)]
      Map.merge(frame, %{g: length(swarms), l: links})
    else
      frame
    end
  end

  # A small number for the page in place of the process of a boid.
  defp number(id), do: :erlang.phash2(id, 1_000_000)
  defp flag(value), do: if(value, do: 1, else: 0)

  def header(more), do: Map.merge(%{box: [@width, @height], kinds: @kinds}, more)
  def json(term), do: IO.iodata_to_binary(:json.encode(term))

  # --- A run in a file ---------------------------------------------------

  @doc "Make a run of `seconds` with steps of 50 ms, and write it to a file. The autopilot flies the ship."
  def record(file, seconds) do
    scene = start(:manual)

    frames =
      for number <- 1..(seconds * 20) do
        :ok = :boids.step(scene.flock, 0.05)
        if rem(number, 20) == 0, do: direct(scene)
        frame(scene, number)
      end

    run = json(header(%{frames: frames}))

    case Path.extname(file) do
      ".json" -> File.write!(file, run)
      _ -> File.write!(file, document(["<script>window.BOIDS = ", run, "</script>"]))
    end

    IO.puts("#{file}: #{length(frames)} moments, #{div(byte_size(run), 1024)} KB")
  end

  # --- The server --------------------------------------------------------

  @doc "Serve the page, the moments of the game in real time, and the keys of the person."
  def serve(port) do
    scene = start(50)
    spawn_link(fn -> director(scene) end)

    {:ok, listen} =
      :gen_tcp.listen(port, [:binary, packet: :http_bin, active: false, reuseaddr: true, ip: {127, 0, 0, 1}])

    IO.puts("Open http://localhost:#{port} to play. Stop with Ctrl-C.")
    accept(listen, scene)
  end

  defp director(scene) do
    Process.sleep(1000)
    direct(scene)
    director(scene)
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

    with {:ok, {:http_request, method, {:abs_path, path}, _}} <- :gen_tcp.recv(socket, 0, 5000),
         {:ok, length} <- headers(socket, 0) do
      :inet.setopts(socket, packet: :raw)

      case {method, path} do
        {:GET, "/"} ->
          page = document("<script>window.BOIDS = {live: true}</script>")

          :gen_tcp.send(socket, [
            "HTTP/1.1 200 OK\r\ncontent-type: text/html; charset=utf-8\r\ncontent-length: #{byte_size(page)}\r\nconnection: close\r\n\r\n",
            page
          ])

        {:GET, "/events"} ->
          :gen_tcp.send(
            socket,
            "HTTP/1.1 200 OK\r\ncontent-type: text/event-stream\r\ncache-control: no-cache\r\n\r\n"
          )

          :gen_tcp.send(socket, ["event: start\ndata: ", json(header(%{})), "\n\n"])
          events(socket, scene, 1)

        {:POST, "/keys"} when length > 0 and length < 200 ->
          # The keys that the person holds down, as a list of names.
          {:ok, body} = :gen_tcp.recv(socket, length, 5000)

          names =
            for name <- :json.decode(body),
                name in ["left", "right", "thrust", "fire"],
                do: {String.to_atom(name), true}

          :gen_boid.cast(scene.ship, {:keys, Map.new(names)})
          :gen_tcp.send(socket, "HTTP/1.1 204 No Content\r\nconnection: close\r\n\r\n")

        _ ->
          :gen_tcp.send(socket, "HTTP/1.1 404 Not Found\r\ncontent-length: 0\r\nconnection: close\r\n\r\n")
      end
    end

    :gen_tcp.close(socket)
  end

  # Read the headers. The result is the length of the body.
  defp headers(socket, length) do
    case :gen_tcp.recv(socket, 0, 5000) do
      {:ok, :http_eoh} -> {:ok, length}
      {:ok, {:http_header, _, :"Content-Length", _, value}} -> headers(socket, String.to_integer(value))
      {:ok, _header} -> headers(socket, length)
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

  # The page is examples/game.html. It has no <html> and no <body> of
  # its own, so that it is also the page of a published run.
  defp document(data) do
    page = File.read!(Path.join(__DIR__, "game.html"))

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
  [] -> Game.serve(4000)
  ["record", file] -> Game.record(file, 40)
  [port] -> Game.serve(String.to_integer(port))
end
