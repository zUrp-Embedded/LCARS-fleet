defmodule Fleet.MCP.Supervisor do
  @moduledoc """
  Superviseur racine `fleet_mcp` (DN ring4/fleet_mcp.md §"Contrat
  technique" `Fleet.MCP.Supervisor` + §Lifecycle).

  Stratégie `:one_for_one`, `max_restarts: 3`, `max_seconds: 60` (DN).
  Enfants :
    - `Fleet.MCP.Server` (registry/lifecycle opaque) ;
    - `Fleet.MCP.PodTools` (HTTP transport pour `get_task`/`submit_result`)
      démarré SSI `:pod_facing_port` configuré.

  Z7.3 (MCP-D1, 2026-06-10) — `Fleet.MCP.Bridge` RETIRÉ : pont PubSub↔channels
  mort (re-broadcast vers 0 subscriber, les channels push `fleet-control.*` ayant
  été retirés au chantier 7 ; `mcp_to_pubsub` demi-implémenté ; config purgée). Le
  drive pod-facing vit dans `PodTools` (pull `get_task`/`submit_result`), PAS dans
  un push channel. ⚠ "bridge" est homonyme : le pont **stdio→HTTP**
  (`bin/fleet_mcp_stdio_bridge.py`, tests `bridge_*`) est VIVANT (transport drive),
  rien à voir avec ce `Fleet.MCP.Bridge` PubSub mort.

  BL-021 chantier 7 — purge ADR-G C5.1 : retrait `ChannelHTTP.QueueOwner`,
  `PushDispatcher`, et l'enfant `channel_http_children` (Plug.Cowboy long-poll
  push channel). PoC Channel Anthropic KO 4 itérations 2026-05-27 →
  drive ré-implémenté via tools MCP pull (`get_task`/`submit_result`) +
  kick send-keys.

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
        {Fleet.MCP.Server, opts}
      ] ++ pod_facing_children(opts)

    Supervisor.init(children,
      strategy: :one_for_one,
      max_restarts: 3,
      max_seconds: 60
    )
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
