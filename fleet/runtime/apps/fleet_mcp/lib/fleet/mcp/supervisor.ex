defmodule Fleet.MCP.Supervisor do
  @moduledoc """
  Superviseur racine `fleet_mcp` : démarre le serveur MCP système-side et,
  optionnellement, le listener pod-facing.

  Stratégie `:one_for_one`, `max_restarts: 3`, `max_seconds: 60`.
  Enfants :
    - `Fleet.MCP.Server` (garde de boot : refuse côté pod ; ex-husk channels
      retiré) ;
    - `Fleet.MCP.PodTools` (HTTP transport pour `get_task`/`submit_result`)
      démarré SSI `:pod_facing_port` configuré.

  `Fleet.MCP.Bridge` RETIRÉ : pont PubSub↔channels
  mort (re-broadcast vers 0 subscriber, les channels push `fleet-control.*` ayant
  été retirés ; `mcp_to_pubsub` demi-implémenté ; config purgée). Le
  drive pod-facing vit dans `PodTools` (pull `get_task`/`submit_result`), PAS dans
  un push channel. ⚠ "bridge" est homonyme : le pont **stdio→HTTP**
  (`bin/fleet_mcp_stdio_bridge.py`, tests `bridge_*`) est VIVANT (transport drive),
  rien à voir avec ce `Fleet.MCP.Bridge` PubSub mort.

  Purge des channels push : retrait `ChannelHTTP.QueueOwner`,
  `PushDispatcher`, et l'enfant `channel_http_children` (Plug.Cowboy long-poll
  push channel). PoC Channel Anthropic KO (4 itérations) →
  drive ré-implémenté via tools MCP pull (`get_task`/`submit_result`) +
  kick send-keys.

  Containment : si `boot_environment == :pod`,
  `Fleet.MCP.Server.start_link/1` renvoie `{:error, :forbidden_in_pod}` →
  l'enfant échoue → ce superviseur échoue → `fleet_mcp` ne boote pas dans
  un pod. Comportement voulu (serveur système-side, hors bwrap).
  Phoenix.PubSub `Fleet.PubSub` est démarré par `fleet_event_router`
  — dépendance umbrella, non démarré ici (pas de double-start).
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

  # Serveur MCP pod-facing CENTRAL (PodTools en transport :http + TaskQueue).
  # Démarré SSI `:pod_facing_port` est configuré (deploy host-side). nil → [] : aucun listener
  # (défaut ; tests et apps qui n'en ont pas besoin restent inchangés). Les pods s'y connectent via
  # le pont stdio (http://localhost:<port>/mcp). TaskQueue = état partagé (résultats corrélés pod_id).
  @doc """
  Child specs du listener pod-facing (public pour le test de bind : l'option `:host`
  passée à PodTools porte l'`:ip` d'écoute — loopback par défaut, compatible pods).
  Retourne `[]` quand `:pod_facing_port` n'est pas configuré.
  """
  def pod_facing_children(opts) do
    case pod_facing_port(opts) do
      nil ->
        []

      port ->
        ref = Keyword.get(opts, :pod_facing_ranch_ref, :fleet_mcp_pod_facing)

        # Bind loopback par défaut. Le transport HTTP ExMCP dérive l'ip d'écoute de
        # son option `:host` (ExMCP.Server.Transport.parse_host/1, qui accepte un
        # tuple IP tel quel) — on lui passe donc l'ip calculée par la source unique
        # Fleet.EventRouter.BindAddress. Loopback est COMPATIBLE avec les pods : ils
        # joignent le MCP via le pont stdio→HTTP sur http://127.0.0.1:<port>/mcp
        # (cf. LCARS_FLEET_MCP_URL, bin/fleet_mcp_stdio_bridge.py) — même hôte, donc
        # loopback ne casse rien. Exposition publique (rare) = LCARS_BIND_HOST.
        ip = Fleet.EventRouter.BindAddress.ip()

        # Le broker (Fleet.TaskQueue.Server) est démarré par l'app fleet_task_queue,
        # pas ici : fleet_mcp sert la queue, ne la possède pas.
        [
          Supervisor.child_spec(
            {Fleet.MCP.PodTools, [transport: :http, host: ip, port: port, ranch_ref: ref]},
            id: Fleet.MCP.PodTools
          )
        ]
    end
  end

  defp pod_facing_port(opts) do
    Keyword.get(opts, :pod_facing_port) || Application.get_env(:fleet_mcp, :pod_facing_port)
  end
end
