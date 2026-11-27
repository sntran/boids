defmodule Boids.Cluster do
  @moduledoc """
  Nodes for the tests of a world on several nodes.

  The nodes need no epmd: the port of a node is in its name (`Epmd`). The
  test controls each node through its standard input and output, so the
  node of the test is not a part of the cluster.
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

  @doc "Start `count` nodes that are connected, with the application boids. The result is a list of `{peer, node}`."
  def start(count) do
    paths = Enum.flat_map(:code.get_path(), &[~c"-pa", &1])

    nodes =
      for _ <- 1..count do
        port = free_port()

        args =
          [
            ~c"-start_epmd",
            ~c"false",
            ~c"-epmd_module",
            ~c"Elixir.Boids.Cluster.Epmd",
            ~c"-setcookie",
            ~c"boids"
          ] ++
            [~c"-kernel", ~c"inet_dist_listen_min", ~c"#{port}", ~c"inet_dist_listen_max", ~c"#{port}"] ++
            paths

        options = %{
          name: ~c"b#{port}",
          host: ~c"127.0.0.1",
          longnames: true,
          connection: :standard_io,
          args: args
        }

        {:ok, peer, node} = :peer.start_link(options)
        {:ok, _} = :peer.call(peer, :application, :ensure_all_started, [:boids])
        {peer, node}
      end

    [{first, _} | rest] = nodes
    for {_peer, node} <- rest, do: true = :peer.call(first, :net_kernel, :connect_node, [node])
    nodes
  end

  def stop(nodes), do: for({peer, _node} <- nodes, do: :peer.stop(peer))

  @doc "Call a function on a node."
  def call(peer, module, function, args), do: :peer.call(peer, module, function, args, 10_000)

  defp free_port do
    {:ok, socket} = :gen_tcp.listen(0, ip: {127, 0, 0, 1})
    {:ok, port} = :inet.port(socket)
    :gen_tcp.close(socket)
    port
  end
end
