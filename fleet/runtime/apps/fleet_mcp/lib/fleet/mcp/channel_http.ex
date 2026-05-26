defmodule Fleet.MCP.ChannelHTTP do
  @moduledoc """
  Endpoint HTTP custom pour push channel notifications LCARS → pod claude
  long-lived (mode `claude --remote-control` + `fleet_mcp_stdio_bridge.py`).

  ## Pourquoi un endpoint HTTP custom

  Le protocol MCP standard côté ExMCP server (`Fleet.MCP.PodTools`) est
  request/response (tool call). Les **notifications server-initiated**
  (`notifications/claude/channel` — vendor natif claude REPL, cf. reverse
  `#5b_channels-structuredio.md`) demandent un canal push asymétrique.

  Ce module expose 2 routes minimum :

    * `POST /internal/channels/notify` — fleet enqueue une notif par pod_id
    * `GET /channels/:pod_id/poll?timeout=<sec>` — bridge.py long-poll
      pour récupérer les notifs en attente (max 30s, sleep si vide)

  Le bridge.py forward chaque notif récupérée à stdout au format vendor
  `notifications/claude/channel` que claude REPL interprète nativement
  (enqueue prompt priority:next, isMeta:true).

  ## État

  ETS table `:fleet_mcp_channel_queue` (set) : `pod_id → :queue` de notifs.
  Démarrée par `Fleet.MCP.ChannelHTTP.init/0` au boot du listener.
  Fan-out = direct (1 pod_id = 1 queue, pas de broadcast cross-pod).

  ## Plug.Router

  Listener démarré par `Fleet.MCP.Supervisor` si `:channel_http_port`
  configuré (config_driven, off par défaut tests).
  """

  use Plug.Router

  alias Plug.Conn

  @ets_table :fleet_mcp_channel_queue
  @default_poll_timeout_ms 30_000
  @poll_check_interval_ms 100

  plug(:match)
  plug(Plug.Parsers, parsers: [:json], pass: ["application/json"], json_decoder: Jason)
  plug(:dispatch)

  # ============================================================
  # Routes
  # ============================================================

  post "/internal/channels/notify" do
    case conn.body_params do
      %{"pod_id" => pod_id, "content" => content} = body
      when is_binary(pod_id) and is_binary(content) ->
        meta = Map.get(body, "meta", %{})
        :ok = enqueue(pod_id, %{"content" => content, "meta" => meta})

        conn
        |> Conn.put_resp_content_type("application/json")
        |> Conn.send_resp(200, Jason.encode!(%{"ok" => true}))

      _ ->
        conn
        |> Conn.put_resp_content_type("application/json")
        |> Conn.send_resp(
          400,
          Jason.encode!(%{"ok" => false, "error" => "pod_id + content required"})
        )
    end
  end

  get "/channels/:pod_id/poll" do
    timeout_ms =
      case conn.params["timeout"] do
        s when is_binary(s) ->
          case Integer.parse(s) do
            {n, _} when n > 0 and n <= 60 -> n * 1000
            _ -> @default_poll_timeout_ms
          end

        _ ->
          @default_poll_timeout_ms
      end

    notifications = wait_for_notifications(pod_id, timeout_ms)

    conn
    |> Conn.put_resp_content_type("application/json")
    |> Conn.send_resp(200, Jason.encode!(%{"ok" => true, "notifications" => notifications}))
  end

  match _ do
    Conn.send_resp(conn, 404, "")
  end

  # ============================================================
  # Public API (used by Bridge / tests)
  # ============================================================

  @doc """
  Boot-time : crée l'ETS table (idempotent). Appelée par
  `Fleet.MCP.ChannelHTTP.Supervisor` ou via `start_link/1` enfant supervisor.
  """
  @spec ensure_table() :: :ok
  def ensure_table do
    case :ets.whereis(@ets_table) do
      :undefined ->
        :ets.new(@ets_table, [:set, :public, :named_table, read_concurrency: true])
        :ok

      _ ->
        :ok
    end
  end

  @doc """
  Enqueue une notification pour `pod_id`. Pure côté API (effet ETS).
  """
  @spec enqueue(String.t(), map()) :: :ok
  def enqueue(pod_id, notification) when is_binary(pod_id) and is_map(notification) do
    ensure_table()

    current_queue =
      case :ets.lookup(@ets_table, pod_id) do
        [{^pod_id, queue}] -> queue
        [] -> :queue.new()
      end

    new_queue = :queue.in(notification, current_queue)
    :ets.insert(@ets_table, {pod_id, new_queue})
    :ok
  end

  @doc """
  Dépile toutes les notifications en attente pour `pod_id`. Retourne `[]`
  si vide.
  """
  @spec drain(String.t()) :: [map()]
  def drain(pod_id) when is_binary(pod_id) do
    ensure_table()

    case :ets.lookup(@ets_table, pod_id) do
      [{^pod_id, queue}] ->
        :ets.insert(@ets_table, {pod_id, :queue.new()})
        :queue.to_list(queue)

      [] ->
        []
    end
  end

  # ============================================================
  # Internals — long-poll
  # ============================================================

  defp wait_for_notifications(pod_id, timeout_ms) do
    deadline = System.monotonic_time(:millisecond) + timeout_ms
    poll_loop(pod_id, deadline)
  end

  defp poll_loop(pod_id, deadline) do
    case drain(pod_id) do
      [] ->
        remaining = deadline - System.monotonic_time(:millisecond)

        if remaining > 0 do
          Process.sleep(min(@poll_check_interval_ms, remaining))
          poll_loop(pod_id, deadline)
        else
          []
        end

      notifs ->
        notifs
    end
  end
end
