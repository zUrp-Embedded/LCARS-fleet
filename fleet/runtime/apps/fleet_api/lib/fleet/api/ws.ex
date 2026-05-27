defmodule Fleet.API.WS do
  @moduledoc """
  Cowboy WebSocket handler `:8080/ws` subscribe `Fleet.EventRouter.Bus`
  topic `fleet.events` + filtre per-client topics + heartbeat ping/pong
  30s.

  ## Protocol JSON

  ### Client → Server

      {"action": "subscribe", "topics": ["pipeline.*", "audit.cat5.*"]}

  Topics liste vide = subscribe all (default au connect).

  ### Server → Client

      {"type": "connected"}                   ← initial handshake
      {"type": "subscribed", "topics": [...]} ← ack subscribe
      {"type": "ping"}                        ← heartbeat 30s
      {"type": "event", "event_type": "pipeline.completed", "payload": {...}}
      {"type": "error", "reason": "..."}

  ## Filtre topics

  Pattern simple : exact match OU wildcard suffixe `*` (ex
  `"pipeline.*"` match `"pipeline.completed"`).
  """

  @behaviour :cowboy_websocket

  alias Fleet.EventRouter.Bus

  @heartbeat_ms 30_000

  @impl :cowboy_websocket
  def init(req, _opts) do
    {:cowboy_websocket, req, %{topics: []}, %{idle_timeout: 60_000}}
  end

  @impl :cowboy_websocket
  def websocket_init(state) do
    Bus.subscribe()
    Process.send_after(self(), :heartbeat, @heartbeat_ms)
    {[{:text, ~s|{"type":"connected"}|}], state}
  end

  @impl :cowboy_websocket
  def websocket_handle({:text, msg}, state) do
    case Jason.decode(msg) do
      {:ok, %{"action" => "subscribe", "topics" => topics}} when is_list(topics) ->
        frame = Jason.encode!(%{type: "subscribed", topics: topics})
        {[{:text, frame}], %{state | topics: topics}}

      {:ok, _other} ->
        {[{:text, ~s|{"type":"error","reason":"unknown action"}|}], state}

      {:error, _reason} ->
        {[{:text, ~s|{"type":"error","reason":"invalid_msg"}|}], state}
    end
  end

  def websocket_handle(_other, state), do: {[], state}

  @impl :cowboy_websocket
  def websocket_info({_atom, %{"event_type" => event_type, "payload" => payload}}, state) do
    if topic_matches?(event_type, state.topics) do
      frame =
        Jason.encode!(%{
          type: "event",
          event_type: event_type,
          payload: payload
        })

      {[{:text, frame}], state}
    else
      {[], state}
    end
  end

  def websocket_info(:heartbeat, state) do
    Process.send_after(self(), :heartbeat, @heartbeat_ms)
    {[{:text, ~s|{"type":"ping"}|}], state}
  end

  def websocket_info(_msg, state), do: {[], state}

  @doc """
  Vérifie si `event_type` (string) match au moins un pattern dans
  `topics`. Liste vide = match all (subscribe-all default).

  Patterns : exact match OU wildcard suffixe `*` (ex `"pipeline.*"`
  match `"pipeline.completed"`).
  """
  @spec topic_matches?(String.t(), [String.t()]) :: boolean()
  def topic_matches?(_event_type, []), do: true

  def topic_matches?(event_type, topics) when is_list(topics) do
    Enum.any?(topics, fn pattern ->
      cond do
        pattern == event_type ->
          true

        String.ends_with?(pattern, ".*") ->
          String.starts_with?(event_type, String.trim_trailing(pattern, "*"))

        true ->
          false
      end
    end)
  end
end
