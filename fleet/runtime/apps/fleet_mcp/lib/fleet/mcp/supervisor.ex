defmodule Fleet.MCP.Supervisor do
  @moduledoc """
  Superviseur racine `fleet_mcp` (DN ring4/fleet_mcp.md §"Contrat
  technique" `Fleet.MCP.Supervisor` + §Lifecycle).

  Stratégie `:one_for_one`, `max_restarts: 3`, `max_seconds: 60` (DN).
  Enfants : `Fleet.MCP.Server` (registry/lifecycle opaque) +
  `Fleet.MCP.Bridge` (pont Phoenix.PubSub ↔ MCP channels). Les channels
  (`FleetControl`/`FleetForge`/`Schema`) sont des modules purs/behaviours
  — **aucun process** (Iron Law), pas d'enfant.

  Conformance ADR-C (DN D7-bis) : si `boot_environment == :pod`,
  `Fleet.MCP.Server.start_link/1` renvoie `{:error, :forbidden_in_pod}` →
  l'enfant échoue → ce superviseur échoue → `fleet_mcp` ne boote pas dans
  un pod. Comportement voulu (substrat système-side hors-bwrap).
  Phoenix.PubSub `Fleet.PubSub` est démarré par `fleet_event_router`
  (chantier 11) — dépendance umbrella, non démarré ici (pas de double-start).
  """

  use Supervisor

  @spec start_link(keyword()) :: Supervisor.on_start()
  def start_link(opts \\ []) do
    Supervisor.start_link(__MODULE__, opts, name: __MODULE__)
  end

  @impl Supervisor
  def init(opts) do
    children =
      [
        {Fleet.MCP.Server, opts},
        {Fleet.MCP.Bridge, opts},
        # U2 — ETS owner pour channel queue (toujours démarré, indépendant
        # du listener HTTP : la table doit exister pour tests + enqueue
        # API directe par fleet_pilot).
        {Fleet.MCP.ChannelHTTP.QueueOwner, opts},
        # U4 — PushDispatcher subscribe Bus `pod.brief.push` → enqueue
        # ChannelHTTP. Sans config gate : ETS table toujours là, enqueue
        # cheap, bridge.py côté pod drainera quand il poll.
        {Fleet.MCP.PushDispatcher, opts}
      ] ++ pod_facing_children(opts) ++ channel_http_children(opts)

    Supervisor.init(children,
      strategy: :one_for_one,
      max_restarts: 3,
      max_seconds: 60
    )
  end

  # U2 — endpoint HTTP custom pour push channel notifications (vers
  # bridge.py côté pod en long-poll). Démarré SSI `:channel_http_port`
  # configuré. ETS queue lazy-initialized par ChannelHTTP.ensure_table/0
  # (pas de GenServer owner — POC scope, race write acceptable 1 writer
  # fleet_pilot + 1 reader par pod).
  defp channel_http_children(opts) do
    case channel_http_port(opts) do
      nil ->
        []

      port ->
        [
          {Plug.Cowboy,
           scheme: :http,
           plug: Fleet.MCP.ChannelHTTP,
           options: [port: port, ref: :fleet_mcp_channel_http]}
        ]
    end
  end

  defp channel_http_port(opts) do
    Keyword.get(opts, :channel_http_port) ||
      Application.get_env(:fleet_mcp, :channel_http_port)
  end

  # R-CORE.comm Ring 4 — serveur MCP pod-facing CENTRAL (PodTools en transport :http + TaskQueue).
  # Démarré SSI `:pod_facing_port` est configuré (deploy host-side). nil → [] : aucun listener
  # (défaut ; tests et apps qui n'en ont pas besoin restent inchangés). Les pods s'y connectent via
  # le pont stdio (http://localhost:<port>/mcp). TaskQueue = état partagé (résultats corrélés pod_id).
  defp pod_facing_children(opts) do
    case pod_facing_port(opts) do
      nil ->
        []

      port ->
        ref = Keyword.get(opts, :pod_facing_ranch_ref, :fleet_mcp_pod_facing)

        # Le broker (Fleet.TaskQueue.Server) est démarré par l'app fleet_task_queue,
        # pas ici (ADR-G : fleet_mcp sert la queue, ne la possède pas).
        [
          Supervisor.child_spec(
            {Fleet.MCP.PodTools, [transport: :http, port: port, ranch_ref: ref]},
            id: Fleet.MCP.PodTools
          )
        ]
    end
  end

  defp pod_facing_port(opts) do
    Keyword.get(opts, :pod_facing_port) || Application.get_env(:fleet_mcp, :pod_facing_port)
  end
end
