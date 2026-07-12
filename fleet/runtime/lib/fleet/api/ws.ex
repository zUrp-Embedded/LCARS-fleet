defmodule Fleet.API.WS do
  @moduledoc """
  Cowboy WebSocket handler `:<port>/ws` (per-human port, bin/fleet_v2) subscribes `Fleet.EventRouter.Bus`
  topic `fleet.events` + per-client topic filter + 30s ping/pong
  heartbeat.

  ## JSON protocol

  ### Client → Server

      {"action": "subscribe", "topics": ["workflow_map.*", "audit.cat5.*"]}

  Empty topics list = subscribe all (default at connect).

  ### Server → Client

      {"type": "connected"}                   ← initial handshake
      {"type": "subscribed", "topics": [...]} ← subscribe ack
      {"type": "ping"}                        ← 30s heartbeat
      {"type": "event", "event_type": "workflow_map.completed", "payload": {...}}
      {"type": "error", "reason": "..."}

  ## Topic filter

  Simple pattern: exact match OR `*` suffix wildcard (e.g.
  `"workflow_map.*"` matches `"workflow_map.completed"`).
  """

  @behaviour :cowboy_websocket

  alias Fleet.EventRouter.Bus

  @heartbeat_ms 30_000

  @impl :cowboy_websocket
  def init(req, _opts) do
    # max_frame_size (E4): Cowboy default = infinity — an arbitrarily large client frame
    # would be buffered then decoded by Jason. 64 KiB >> the biggest legitimate message (subscribe).
    {:cowboy_websocket, req, %{topics: []}, %{idle_timeout: 60_000, max_frame_size: 65_536}}
  end

  @impl :cowboy_websocket
  def websocket_init(state) do
    # E5: fail-loud — a deaf-subscribed WS would send a dead stream to the client without error.
    :ok = Bus.subscribe()
    Process.send_after(self(), :heartbeat, @heartbeat_ms)
    {[{:text, ~s|{"type":"connected"}|}], state}
  end

  @impl :cowboy_websocket
  def websocket_handle({:text, msg}, state) do
    case Jason.decode(msg) do
      {:ok, %{"action" => "subscribe", "topics" => topics}} when is_list(topics) ->
        # The WS is no-auth: a client sends anything. A non-string topic would pass the ACK
        # then crash `topic_matches?` downstream (`String.ends_with?(123, ".*")`) on the 1st event —
        # an unauthenticated crash vector. So we validate at ADMISSION that EACH topic is a
        # string; otherwise a clean reject, state UNCHANGED (no ACK, no subscribe).
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

  # SINGLE event schema: we only receive the canonical struct `%Fleet.Event{}`
  # (no `{atom, %{"event_type" => ...}}` tuple) — producers emit the
  # struct, subscribers receive it directly, a single form on the bus.
  # `event_type` (string, dot form) derived from `type` (atom) for the topic filter
  # + the client JSON wire.
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
  Checks whether `event_type` (string) matches at least one pattern in
  `topics`. Empty list = match all (subscribe-all default).

  Patterns: exact match OR `*` suffix wildcard (e.g. `"workflow_map.*"`
  matches `"workflow_map.completed"`).
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
