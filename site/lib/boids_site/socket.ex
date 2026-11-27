defmodule BoidsSite.Socket do
  @moduledoc """
  The WebSocket of a scene. The messages are JSON.

  The server sends `{"start": HEADER}` when a scene starts, then
  `{"m": MOMENT}` at each tick, or `{"error": TEXT}`. The page sends
  `{"keys": [NAME]}` for the keys that are down (the game), or
  `{"scene": DEFINITION}` to start a scene of its own (the playground).
  """
  @behaviour :cowboy_websocket

  @scenes %{
    "flock" => BoidsSite.Scenes.Flock,
    "game" => BoidsSite.Scenes.Game,
    "playground" => BoidsSite.Scenes.Playground
  }

  @impl true
  def init(request, _options) do
    name = :cowboy_req.binding(:scene, request)
    {:cowboy_websocket, request, name, %{idle_timeout: 120_000, max_frame_size: 32_768}}
  end

  @impl true
  def websocket_init(name) do
    case @scenes do
      # The playground waits for the definition of the visitor.
      %{^name => BoidsSite.Scenes.Playground = module} -> {[], %{module: module, scene: nil, number: 0}}
      %{^name => module} -> start(%{module: module, scene: nil, number: 0}, nil)
      _ -> {[{:close, 1008, "no such scene"}], nil}
    end
  end

  @impl true
  def websocket_handle({:text, text}, %{module: module, scene: scene} = state) do
    case decode(text) do
      %{"scene" => definition} when module == BoidsSite.Scenes.Playground ->
        start(state, definition)

      %{} = message when scene != nil ->
        :ok = BoidsSite.Scene.input(scene, message)
        {[], state}

      _ ->
        {[], state}
    end
  end

  def websocket_handle(_frame, state), do: {[], state}

  @impl true
  def websocket_info({:tick, token}, %{scene: %{guard: token} = scene, number: number} = state) do
    Process.send_after(self(), {:tick, token}, BoidsSite.Scene.tick())
    {[text(%{m: BoidsSite.Scene.frame(scene, number + 1)})], %{state | number: number + 1}}
  end

  def websocket_info(_message, state), do: {[], state}

  # Start the scene of this socket, in place of the scene before.
  defp start(%{module: module, scene: before} = state, definition) do
    if before, do: BoidsSite.Scene.stop(before)

    case BoidsSite.Scene.start(module, definition) do
      {:ok, scene} ->
        # The ticks of a scene before this one have another token.
        send(self(), {:tick, scene.guard})
        {[text(%{start: BoidsSite.Scene.header(scene)})], %{state | scene: scene, number: 0}}

      {:error, reason} ->
        {[text(%{error: reason})], %{state | scene: nil}}
    end
  end

  defp decode(text) do
    :json.decode(text)
  catch
    _, _ -> nil
  end

  defp text(term), do: {:text, :json.encode(term)}
end
