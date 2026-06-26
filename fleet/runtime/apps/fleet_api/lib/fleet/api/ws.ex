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
        # Le WS est no-auth : un client envoie n'importe quoi. Un topic non-string passerait l'ACK
        # puis crasherait `topic_matches?` en aval (`String.ends_with?(123, ".*")`) au 1er event —
        # vecteur de crash non authentifié. On valide donc à l'ADMISSION que CHAQUE topic est une
        # string ; sinon rejet net, état INCHANGÉ (pas d'ACK, pas de subscribe).
        if Enum.all?(topics, &is_binary/1) do
          frame = Jason.encode!(%{type: "subscribed", topics: topics})
          {[{:text, frame}], %{state | topics: topics}}
        else
          {[{:text, ~s|{"type":"error","reason":"topics must be strings"}|}], state}
        end

      {:ok, _other} ->
        {[{:text, ~s|{"type":"error","reason":"unknown action"}|}], state}

      {:error, _reason} ->
        {[{:text, ~s|{"type":"error","reason":"invalid_msg"}|}], state}
    end
  end

  def websocket_handle(_other, state), do: {[], state}

  # Schéma événementiel UNIQUE : on ne reçoit que la struct canon `%Fleet.Event{}`
  # (pas de tuple `{atom, %{"event_type" => ...}}`) — les producteurs émettent la
  # struct, les subscribers la reçoivent directement, une seule forme sur le bus.
  # `event_type` (string, forme dot) dérivé de `type` (atom) pour le filtre topics
  # + le wire JSON client.
  @impl :cowboy_websocket
  def websocket_info(%Fleet.Event{type: type, payload: payload}, state) do
    event_type = Atom.to_string(type)

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
