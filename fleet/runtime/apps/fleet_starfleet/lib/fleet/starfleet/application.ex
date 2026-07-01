defmodule Fleet.Starfleet.Application do
  @moduledoc """
  Application supervisor `fleet_starfleet`.

  Démarre :

    1. Pré-charge schema décision via
       `Fleet.Starfleet.Gatekeeper.init_schema!/0` (boot fail-fast)
    2. Pré-enregistre atomes events `starfleet.audit_cat5_*` et `audit.verdict`
       (compile-time via attribut, cohérent ch11 M1 atom-leak DoS)
    3. Démarre `Fleet.Starfleet.DriftMonitor` GenServer subscriber
       (opt-in via `:start_drift_monitor`, default `true` en prod)

  ## Configuration

    * `:fleet_starfleet, :start_drift_monitor` — booléen (default
      `true`). Tests peuvent set à `false` pour démarrer le monitor
      manuellement via `start_supervised/1`.

  ## Stratégie

  `:one_for_one` — DriftMonitor est seul, autonome, restart `:permanent`.
  """

  use Application

  # R09 : les atomes RÉELLEMENT émis par Cat5Escalator sont
  # `starfleet.audit_cat5_<src>` (cf. events.yaml + cat5_escalator) — les anciens
  # `audit.cat5.*` (pointillés) étaient des vestiges jamais émis.
  @starfleet_event_atoms [
    :"starfleet.audit_cat5_pod_drift",
    :"starfleet.audit_cat5_workflow_map_failed",
    :"starfleet.audit_cat5_oauth_refresh_failed",
    :"audit.verdict",
    # B10/#583 Sprint 1 — events lifecycle BootOrchestrator
    :"fleet.boot_complete",
    :"fleet.boot_partial",
    :"fleet.boot_failed",
    # BL-021 chantier 8 — Extensions V2 MCPWatcher + MCPMonitor
    :"sdk.upstream_alert",
    :"mcp.server_crashed"
  ]

  @impl Application
  def start(_type, _args) do
    :ok = Fleet.Starfleet.Gatekeeper.init_schema!()

    # BL-021 chantier 8 — Extensions V2 (DN 13).
    # MCPWatcher : default OFF (HTTP I/O Hex.pm — opt-in en prod où l'outbound
    # est autorisé). MCPMonitor : default ON (purement local Process.whereis,
    # zéro I/O réseau, cohérent avec DriftMonitor/AuditConsumer).
    children =
      [] ++
        if(Application.get_env(:fleet_starfleet, :start_drift_monitor, true),
          do: [Fleet.Starfleet.DriftMonitor],
          else: []
        ) ++
        if Application.get_env(:fleet_starfleet, :start_shutdown, true) do
          # Grace shutdown coordonné — doit être vivant pour le RPC
          # ExecStop systemd (DN ring0/lcars-fleet_service).
          [Fleet.Starfleet.Shutdown]
        else
          []
        end ++
        if(Application.get_env(:fleet_starfleet, :start_audit_consumer, true),
          do: [Fleet.Starfleet.AuditConsumer],
          else: []
        ) ++
        if Application.get_env(:fleet_starfleet, :start_boot_orchestrator, true) do
          # B10/#583 Sprint 1 — Task :transient post-start sequence
          # boot_permanent_pods + emit fleet.boot_complete|partial|failed.
          [
            %{
              id: Fleet.Starfleet.BootOrchestrator,
              start: {Fleet.Starfleet.BootOrchestrator, :start_link, [[]]},
              restart: :transient,
              type: :worker
            }
          ]
        else
          []
        end ++
        if(Application.get_env(:fleet_starfleet, :start_mcp_watcher, false),
          do: [Fleet.Starfleet.MCPWatcher],
          else: []
        ) ++
        if(Application.get_env(:fleet_starfleet, :start_mcp_monitor, true),
          do: [Fleet.Starfleet.MCPMonitor],
          else: []
        )

    opts = [strategy: :one_for_one, name: Fleet.Starfleet.Supervisor]
    Supervisor.start_link(children, opts)
  end

  @doc """
  Liste des atomes events `audit.*` pré-enregistrés. Cohérent ch11
  M1 atom-leak DoS mitigation (Bus `String.to_existing_atom/1`).
  """
  @spec starfleet_event_atoms() :: [atom()]
  def starfleet_event_atoms, do: @starfleet_event_atoms
end
