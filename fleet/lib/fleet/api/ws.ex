defmodule Fleet.API.WS do
  @moduledoc """
  WebSocket projection of `Fleet.EventRouter.Bus` at `/ws`.

  Clients subscribe with `{"action":"subscribe","topics":[...]}`. Empty
  topics match all events; patterns are exact or use a trailing `*` wildcard.
  The handler rejects non-string topics, bounds inbound frames to 64 KiB,
  keeps passive clients alive with control pings, and degrades non-JSON event
  payloads to an inspected `_raw` value.
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
