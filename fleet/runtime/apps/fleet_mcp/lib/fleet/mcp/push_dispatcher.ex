defmodule Fleet.MCP.PushDispatcher do
  @moduledoc """
  U4 — Subscriber Bus `pod.brief.push` → enqueue ChannelHTTP.

  Le pod (Ring 1) broadcaste `pod.brief.push {pod_id, content, meta}` sur
  le Bus quand il veut pousser une tâche à son claude REPL long-lived. CE
  dispatcher (Ring 4, fleet_mcp) consomme et appelle
  `Fleet.MCP.ChannelHTTP.enqueue/2`. Le bridge.py côté pod long-poll
  l'endpoint HTTP, récupère la notif, l'émet sur stdout au format vendor
  natif `notifications/claude/channel`, le REPL claude l'enqueue avec
  `priority:next, isMeta:true`.

  **Iron Law tenue** : pod.ex ne tape PAS fleet_mcp en direct (pas de
  Ring 1 → Ring 4 hard coupling). Le couplage passe par le Bus
  (event_router, Ring 0). PushDispatcher est le seul module à toucher
  ChannelHTTP côté event-driven, gardant la frontière propre.

  ## Démarrage

  Démarré inconditionnellement par `Fleet.MCP.Supervisor` — l'ETS table
  (via `QueueOwner`) existe toujours, l'enqueue est cheap (insert ETS),
  donc pas de gate config (le no-op = bridge.py pas démarré côté pod →
  notif reste queued, pas de fuite).
  """

  use GenServer

  require Logger

  alias Fleet.EventRouter.Bus
  alias Fleet.MCP.ChannelHTTP

  @spec start_link(keyword()) :: GenServer.on_start()
  def start_link(opts \\ []) do
    GenServer.start_link(__MODULE__, opts, name: Keyword.get(opts, :name, __MODULE__))
  end

  @impl GenServer
  def init(_opts) do
    :ok = Bus.subscribe()
    {:ok, %{}}
  end

  # Event canonique : `{:"pod.brief.push", event_map}` où event_map a la
  # forme Bus standard avec `payload: %{"pod_id" => _, "content" => _,
  # "meta" => _}`. Extraction défensive (manque pod_id ou content → log + skip).
  @impl GenServer
  def handle_info({:"pod.brief.push", %{"payload" => payload} = _event}, state)
      when is_map(payload) do
    case payload do
      %{"pod_id" => pod_id, "content" => content} = p
      when is_binary(pod_id) and pod_id != "" and is_binary(content) and content != "" ->
        meta = Map.get(p, "meta", %{})
        :ok = ChannelHTTP.enqueue(pod_id, %{"content" => content, "meta" => meta})

        Logger.debug("PushDispatcher enqueue pod_id=#{pod_id} content_len=#{byte_size(content)}")

      bad ->
        Logger.warning(
          "PushDispatcher payload invalide (pod_id+content requis non-vides) : #{inspect(bad)}"
        )
    end

    {:noreply, state}
  end

  # Autres events Bus → ignore silencieux (pattern shared topic).
  def handle_info(_other, state), do: {:noreply, state}
end
