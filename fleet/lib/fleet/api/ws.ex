defmodule Fleet.API.WS do
  @moduledoc """
  WebSocket projection of `Fleet.EventRouter.Bus` at `/ws`.

  ⚠ **NOT SERVED BY DEFAULT since 2026-08-14** — the route is behind `:api_serve_ws` (default
  `false`, see `Fleet.API.Application.ws_route/0`). The module is intact and its tests run: the
  switch is a REVERSIBLE cut, not a removal, because "nobody consumes it" is a measurement on this
  repo at that instant. Flip the config to bring it back — and re-read the section below first.

  Clients subscribe with `{"action":"subscribe","topics":[...]}`. Empty
  topics match all events; patterns are exact or use a trailing `*` wildcard.
  The handler rejects non-string topics, bounds inbound frames to 64 KiB,
  keeps passive clients alive with control pings, and degrades non-JSON event
  payloads to an inspected `_raw` value.

  ## WHAT THIS PUBLISHES, and it is not observability metadata

  No authentication, by design (`fleet/CLAUDE.md`: *`api` REST/WS no-auth by design*) — the
  security boundary is network isolation, and listeners bind loopback unless an operator says
  otherwise. What that posture was written for is not what travels here. MEASURED contents of the
  single `fleet.events` subject a client with `topics: []` receives IN FULL:

    * `work_item.completed` — a pod's complete result payload;
    * `pod.completed` — result, workspace paths, `base_sha`, repo and role;
    * `wake.failed` — **a capture of the pod's tmux screen**.

  A screen capture is not a metric: whatever a pod had on screen at that moment is in it. An
  operator who sets `LCARS_BIND_HOST` is told they are exposing listeners; they are not told this
  one republishes pod screens, which is why it is written here and at the knob.

  ⚠ A pod CANNOT reach this endpoint, contrary to what an audit assumed: `bin/bwrap_launch.sh`
  runs every canon pod under `--unshare-all` (its own network namespace, so the host's loopback is
  not its loopback), egress is a per-pod CONNECT proxy on AF_UNIX with a hostname allowlist, and
  `containment: none` is refused by `SpawnAdmission`. The reachable set is the host's local
  processes — plus the network, if an operator exposed it.
  """

  @behaviour :cowboy_websocket

  alias Fleet.EventRouter.Bus

  @heartbeat_ms 30_000

  @impl :cowboy_websocket
  def init(req, _opts) do
    {:cowboy_websocket, req, %{topics: []}, %{idle_timeout: 60_000, max_frame_size: 65_536}}
  end

  @impl :cowboy_websocket
  def websocket_init(state) do
    :ok = Bus.subscribe()
    Process.send_after(self(), :heartbeat, @heartbeat_ms)
    {[{:text, ~s|{"type":"connected"}|}], state}
  end

  @impl :cowboy_websocket
  def websocket_handle({:text, msg}, state) do
    case Jason.decode(msg) do
      {:ok, %{"action" => "subscribe", "topics" => topics}} when is_list(topics) ->
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

  @impl :cowboy_websocket
  def websocket_info(%Fleet.Event{type: type, payload: payload}, state) do
    event_type = Atom.to_string(type)

    if topic_matches?(event_type, state.topics) do
      {[{:text, encode_event(event_type, payload)}], state}
    else
      {[], state}
    end
  end

  def websocket_info(:heartbeat, state) do
    Process.send_after(self(), :heartbeat, @heartbeat_ms)
    {[{:ping, <<>>}], state}
  end

  def websocket_info(_msg, state), do: {[], state}

  defp encode_event(event_type, payload) do
    Jason.encode!(%{type: "event", event_type: event_type, payload: payload})
  rescue
    _e ->
      Jason.encode!(%{
        type: "event",
        event_type: event_type,
        payload: %{"_raw" => inspect(payload)}
      })
  end

  @doc """
  Matches an event type against exact or trailing-wildcard topics. An empty
  list matches all events.
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
