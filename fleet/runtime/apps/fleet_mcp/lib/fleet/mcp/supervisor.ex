defmodule Fleet.MCP.Supervisor do
  @moduledoc """
  Superviseur racine `fleet_mcp` : démarre le serveur MCP système-side et le
  substrat des sockets pod-facing.

  Stratégie `:one_for_one`, `max_restarts: 3`, `max_seconds: 60`.
  Enfants :
    - `Fleet.MCP.Server` (garde de boot : refuse côté pod) ;
    - `Fleet.MCP.PodSocketRegistry` (Registry unique, clé = `pod_id` → accepteur) ;
    - `Fleet.MCP.ConnectionTaskSupervisor` (Task.Supervisor : un worker par connexion
      acceptée, pour que `serve` ne tourne plus inline dans l'accepteur) ;
    - `Fleet.MCP.PodSocketSupervisor` (DynamicSupervisor des accepteurs de socket
      AF_UNIX per-pod) — démarré inconditionnellement host-side (rien n'est créé
      tant qu'aucun pod n'est provisionné).

  Transport pod-facing = une **socket AF_UNIX par pod** (l'identité EST le canal,
  cf. `Fleet.MCP.PodSocketAcceptor`). L'ex-transport HTTP loopback partagé
  (`PodTools` en `transport: :http`, Plug.Cowboy/Ranch, `:pod_facing_port`) est
  RETIRÉ : il était partagé par tous les pods, donc le `pod_id` y était devinable
  (d'où l'ancienne capability). La socket per-pod ferme ce trou par construction.

  `Fleet.MCP.Bridge` (pont PubSub↔channels) reste RETIRÉ (husk mort). ⚠ "bridge"
  est homonyme : le pont **stdio→socket** (`bin/fleet_mcp_stdio_bridge.py`) est
  VIVANT (transport drive), rien à voir avec ce `Fleet.MCP.Bridge` PubSub mort.

  Containment : si `boot_environment == :pod`, `Fleet.MCP.Server.start_link/1`
  renvoie `{:error, :forbidden_in_pod}` → l'enfant échoue → ce superviseur échoue
  → `fleet_mcp` ne boote pas dans un pod (serveur système-side, hors bwrap).
  Phoenix.PubSub `Fleet.PubSub` est démarré par `fleet_event_router` (dépendance
  umbrella), non démarré ici (pas de double-start).
  """

  use Supervisor

  @spec start_link(keyword()) :: Supervisor.on_start()
  def start_link(opts \\ []) do
    Supervisor.start_link(__MODULE__, opts, name: __MODULE__)
  end

  @impl Supervisor
  def init(opts) do
    children = [
      {Fleet.MCP.Server, opts},
      # Registry de résolution `pod_id → accepteur` (noms `:via`), démarré AVANT le
      # DynamicSupervisor qui s'y enregistre.
      {Registry, keys: :unique, name: Fleet.MCP.PodSocketRegistry},
      # Workers de connexion : chaque connexion acceptée sur une socket pod est servie dans SA propre
      # Task (cf. `Fleet.MCP.PodSocketAcceptor`). Démarré AVANT le DynamicSupervisor des accepteurs
      # (qui y `start_child` dès qu'une connexion arrive). Sans lui, l'accepteur servait chaque connexion
      # inline et en série → un handler lent (ex. appel forge qui pend) gelait tout le pod (connexions
      # suivantes jamais servies → readline timeout). Une Task par connexion = un handler lent n'affecte
      # que sa connexion. `restart: :temporary` (défaut Task.Supervisor) : une connexion qui crash meurt
      # seule, sans redémarrage.
      {Task.Supervisor, name: Fleet.MCP.ConnectionTaskSupervisor},
      Fleet.MCP.PodSocketSupervisor
    ]

    Supervisor.init(children,
      strategy: :one_for_one,
      max_restarts: 3,
      max_seconds: 60
    )
  end

  @doc """
  État LIVE du substrat pod-facing — `{state, detail}` pour la readiness
  (anti-vert-creux). Sonde le PROCESS réel (le DynamicSupervisor d'accepteurs
  `Fleet.MCP.PodSocketSupervisor` tourne-t-il ?), pas un knob de config :

    * `:operational` — le DynamicSupervisor d'accepteurs est vivant (host-side) ;
      `detail.sockets` = nombre d'accepteurs (= sockets pod) actifs.
    * `:degraded`    — le DynamicSupervisor est absent/mort (devrait tourner
      host-side mais ne tourne pas — vert-creux évité).
  """
  @spec pod_facing_status() :: {:operational | :degraded, map()}
  def pod_facing_status do
    if acceptor_supervisor_alive?() do
      {:operational, %{acceptor_supervisor: true, sockets: active_sockets()}}
    else
      {:degraded, %{acceptor_supervisor: false, note: "PodSocketSupervisor non vivant"}}
    end
  end

  defp acceptor_supervisor_alive? do
    case Process.whereis(Fleet.MCP.PodSocketSupervisor) do
      pid when is_pid(pid) -> Process.alive?(pid)
      _ -> false
    end
  end

  defp active_sockets do
    %{active: active} = DynamicSupervisor.count_children(Fleet.MCP.PodSocketSupervisor)
    active
  rescue
    _ -> 0
  catch
    :exit, _ -> 0
  end
end
