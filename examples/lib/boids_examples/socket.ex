defmodule BoidsExamples.Socket do
  @moduledoc """
  The WebSocket of a scene. The messages are JSON.

  The server sends `{"start": HEADER}` when a scene starts, then
  `{"m": MOMENT}` at each tick, or `{"error": TEXT}`. The page sends
  `{"keys": [NAME]}` for the keys that are down (the game), `{"scene":
  DEFINITION}` to start a scene of its own (the playground), or
  `{"pick": N}`, `{"order": [NAME]}` and `{"go": true}` (the flight).
  """
  @behaviour :cowboy_websocket

  # The scenes that are not games. A game is found by its slug
  # (BoidsExamples.Game.find/1).
  @scenes %{
    "flock" => BoidsExamples.Scenes.Flock,
    "playground" => BoidsExamples.Scenes.Playground
  }

  @impl true
  def init(request, _options) do
    name = :cowboy_req.binding(:scene, request)
    {:cowboy_websocket, request, name, %{idle_timeout: 120_000, max_frame_size: 32_768}}
  end

  @impl true
  def websocket_init(name) do
    case Map.get(@scenes, name) || BoidsExamples.Game.find(name) do
      nil ->
        {[{:close, 1008, "no such scene"}], nil}

      module ->
        if BoidsExamples.Scene.waits?(module) do
          # The scene waits for the definition of the visitor.
          {[], %{module: module, scene: nil, number: 0}}
        else
          start(%{module: module, scene: nil, number: 0}, nil)
        end
    end
  end

  @impl true
  def websocket_handle({:text, text}, %{module: module, scene: scene} = state) do
    case decode(text) do
      %{"scene" => definition} ->
        if BoidsExamples.Scene.waits?(module), do: start(state, definition), else: {[], state}

      %{} = message when scene != nil ->
        :ok = BoidsExamples.Scene.input(scene, message)
        {[], state}

      _ ->
        {[], state}
    end
  end

  def websocket_handle(_frame, state), do: {[], state}

  @impl true
  def websocket_info({:tick, token}, %{scene: %{guard: token} = scene, number: number} = state) do
    Process.send_after(self(), {:tick, token}, BoidsExamples.Scene.tick())
    {[text(%{m: BoidsExamples.Scene.frame(scene, number + 1)})], %{state | number: number + 1}}
  end

  def websocket_info(_message, state), do: {[], state}

  # Start the scene of this socket, in place of the scene before.
  defp start(%{module: module, scene: before} = state, definition) do
    if before, do: BoidsExamples.Scene.stop(before)

    case BoidsExamples.Scene.start(module, definition) do
      {:ok, scene} ->
        # The ticks of a scene before this one have another token.
        send(self(), {:tick, scene.guard})
        {[text(%{start: BoidsExamples.Scene.header(scene)})], %{state | scene: scene, number: 0}}

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
