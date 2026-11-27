defmodule Boids.Cluster do
  @moduledoc """
  Nodes for the tests of a world on several nodes.

  The nodes need no epmd: the port of a node is in its name (`Epmd`). The
  test controls each node through its standard input and output, so the
  node of the test is not a part of the cluster.

  When the tests measure the coverage, each node measures it too, and
  gives its numbers to the node of the test when it stops.
  """

  defmodule Epmd do
    @moduledoc "The module `-epmd_module` of the nodes: the name b9101 listens on the port 9101."

    def start_link, do: :ignore
    def register_node(name, port), do: register_node(name, port, :inet)
    def register_node(_name, _port, _family), do: {:ok, :rand.uniform(1_000_000)}
    def port_please(name, _host), do: {:port, port(name), 6}
    def port_please(name, host, _timeout), do: port_please(name, host)
    def listen_port_please(name, _host), do: {:ok, port(name)}
    def address_please(_name, host, family), do: :inet.getaddr(host, family)
    def names(_host), do: {:error, :address}

    defp port(name) do
      name |> to_string() |> String.replace(~r/\D/, "") |> String.to_integer()
    end
  end

  defmodule Sink do
    @moduledoc "A handler of the logger of a node, which keeps the texts of the errors of boids for a test."

    def log(%{level: :error, msg: {:string, text}, meta: %{domain: [:boids | _]}}, _config), do: keep(text)

    def log(%{level: :error, msg: {format, args}, meta: %{domain: [:boids | _]}}, _config) when is_list(args),
      do: keep(:io_lib.format(format, args))

    def log(_event, _config), do: :ok

    @doc "The texts of the errors, the first one first."
    def texts, do: Enum.reverse(:persistent_term.get(__MODULE__, []))

    defp keep(text),
      do:
        :persistent_term.put(__MODULE__, [IO.chardata_to_string(text) | :persistent_term.get(__MODULE__, [])])
  end

  @doc """
  Start `count` nodes that are connected, with the application boids.
  The result is a list of `{peer, node}`. With `split: true`, a node
  makes no connection by itself, so a test can end the connection of
  two nodes (`split/2`) and make it again (`heal/2`).
  """
  def start(count, options \\ []) do
    Enum.reduce(1..count, [], fn _, nodes -> nodes ++ [add(nodes, options)] end)
  end

  @doc "Start one more node, with a connection to the nodes of the list. The result is `{peer, node}`."
  def add(nodes, options \\ []) do
    paths = Enum.flat_map(:code.get_path(), &[~c"-pa", &1])
    port = free_port()
    # With a split, Erlang writes a warning for each connection that it
    # ends: the log of such a node has only the errors.
    never =
      if options[:split],
        do: [~c"-kernel", ~c"dist_auto_connect", ~c"never", ~c"-kernel", ~c"logger_level", ~c"error"],
        else: []

    args =
      [~c"-start_epmd", ~c"false", ~c"-epmd_module", ~c"Elixir.Boids.Cluster.Epmd", ~c"-setcookie", ~c"boids"] ++
        [~c"-kernel", ~c"inet_dist_listen_min", ~c"#{port}", ~c"inet_dist_listen_max", ~c"#{port}"] ++
        never ++ paths

    options = %{
      name: ~c"b#{port}",
      host: ~c"127.0.0.1",
      longnames: true,
      connection: :standard_io,
      args: args
    }

    # No link: the process of a test that starts a node can stop before the node.
    {:ok, peer, node} = :peer.start(options)
    if cover?(), do: cover(peer)
    {:ok, _} = call(peer, :application, :ensure_all_started, [:boids])
    :ok = call(peer, :logger, :add_handler, [:boids_sink, Sink, %{}])
    for {_peer, other} <- nodes, do: true = call(peer, :net_kernel, :connect_node, [other])
    {peer, node}
  end

  @doc "Stop nodes. A node that is stopped already is not an error."
  def stop(nodes) do
    for {peer, node} <- nodes, Process.alive?(peer) do
      if cover?() do
        file = Path.join(System.tmp_dir!(), "boids-#{node}.coverdata")
        :ok = call(peer, :cover, :export, [String.to_charlist(file)])
        # The module cover is of the application tools, which is there only with the coverage.
        :ok = apply(:cover, :import, [String.to_charlist(file)])
        File.rm(file)
      end

      :peer.stop(peer)
    end

    :ok
  end

  @doc "End the connection of two nodes of `start(count, split: true)`."
  def split({a, _na}, {_b, nb}), do: call(a, :erlang, :disconnect_node, [nb])

  @doc "Make the connection of two nodes again."
  def heal({a, _na}, {_b, nb}), do: call(a, :net_kernel, :connect_node, [nb])

  @doc "The texts of the errors that boids wrote to the log of a node."
  def errors(peer), do: call(peer, Sink, :texts, [])

  @doc "Call a function on a node."
  def call(peer, module, function, args), do: :peer.call(peer, module, function, args, 20_000)

  defp cover?, do: Process.whereis(:cover_server) != nil

  # Measure the coverage of the Erlang modules of the library on a node.
  defp cover(peer) do
    {:ok, _} = call(peer, :cover, :start, [])

    for module <- Application.spec(:boids, :modules),
        not String.starts_with?(Atom.to_string(module), "Elixir.") do
      beam = Path.join([:code.lib_dir(:boids), "ebin", "#{module}.beam"])
      {:ok, ^module} = call(peer, :cover, :compile_beam, [String.to_charlist(beam)])
    end
  end

  defp free_port do
    {:ok, socket} = :gen_tcp.listen(0, ip: {127, 0, 0, 1})
    {:ok, port} = :inet.port(socket)
    :gen_tcp.close(socket)
    port
  end
end
