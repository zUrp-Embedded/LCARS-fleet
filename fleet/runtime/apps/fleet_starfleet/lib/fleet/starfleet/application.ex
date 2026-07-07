defmodule Fleet.Starfleet.Application do
  @moduledoc """
  Application supervisor for `fleet_starfleet`.

  Starts:

    1. Pre-loads the decision schema via
       `Fleet.Starfleet.Gatekeeper.init_schema!/0` (boot fail-fast)
    2. Pre-registers the `starfleet.audit_cat5_*`, `audit.verdict`, `fleet.boot_*`,
       `sdk.upstream_alert` and `mcp.server_crashed` event atoms (compile-time via a
       module attribute, atom-leak DoS mitigation)
    3. Supervises six opt-in children, each gated by a `:start_*` config knob:
       * `DriftMonitor` (default `true`) — GenServer subscriber for pod drift
       * `Shutdown` (default `true`) — coordinated graceful shutdown; INERT for now
         (its systemd ExecStop trigger was removed, awaiting a re-wire onto `fleet_v2 stop`)
       * `AuditConsumer` (default `true`) — audit-verdict NDJSON rail
       * `BootOrchestrator` (default `true`, Task `:transient`) — boots the permanent
         pods then emits `fleet.boot_complete|partial|failed`
       * `MCPWatcher` (default `false`) — HTTP egress to Hex.pm (SDK upstream alert),
         opt-in only where outbound is allowed
       * `MCPMonitor` (default `true`) — local `Process.whereis` liveness, no network

  ## Configuration

  One boolean `:start_*` knob per child (all under `:fleet_starfleet`):
  `:start_drift_monitor`, `:start_shutdown`, `:start_audit_consumer`,
  `:start_boot_orchestrator` (default `true`), `:start_mcp_watcher` (default `false`),
  `:start_mcp_monitor` (default `true`). Tests set a knob to `false` to start that
  child manually via `start_supervised/1`.

  ## Strategy

  `:one_for_one`, `max_restarts: 3`, `max_seconds: 60` — each child is independent;
  the widened restart window (vs OTP's 3/5) is a deliberate choice for blips.
  """

  use Application

  # The atoms Cat5Escalator ACTUALLY emits are
  # `starfleet.audit_cat5_<src>` (cf. events.yaml + cat5_escalator) — the old
  # `audit.cat5.*` (only ever sketched) were vestiges never emitted.
  @starfleet_event_atoms [
    :"starfleet.audit_cat5_pod_drift",
    :"starfleet.audit_cat5_workflow_map_failed",
    :"starfleet.audit_cat5_oauth_refresh_failed",
    :"audit.verdict",
    # BootOrchestrator lifecycle events
    :"fleet.boot_complete",
    :"fleet.boot_partial",
    :"fleet.boot_failed",
    # V2 extensions — MCPWatcher + MCPMonitor
    :"sdk.upstream_alert",
    :"mcp.server_crashed"
  ]

  @impl Application
  def start(_type, _args) do
    :ok = Fleet.Starfleet.Gatekeeper.init_schema!()

    # V2 extensions.
    # MCPWatcher: default OFF (HTTP I/O to Hex.pm — opt-in in prod where outbound
    # is allowed). MCPMonitor: default ON (purely local Process.whereis,
    # zero network I/O, consistent with DriftMonitor/AuditConsumer).
    children =
      [] ++
        if(Application.get_env(:fleet_starfleet, :start_drift_monitor, true),
          do: [Fleet.Starfleet.DriftMonitor],
          else: []
        ) ++
        if Application.get_env(:fleet_starfleet, :start_shutdown, true) do
          # Coordinated graceful shutdown — must stay alive to serve the shutdown
          # RPC. INERT for now: its trigger was removed (the systemd ExecStop it
          # once answered is gone), awaiting a re-wire onto `fleet_v2 stop`.
          [Fleet.Starfleet.Shutdown]
        else
          []
        end ++
        if(Application.get_env(:fleet_starfleet, :start_audit_consumer, true),
          do: [Fleet.Starfleet.AuditConsumer],
          else: []
        ) ++
        if Application.get_env(:fleet_starfleet, :start_boot_orchestrator, true) do
          # Task :transient post-start sequence:
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

    # Restart intensity 3/60 EXPLICIT (event_router/task_queue doctrine — the OTP default 3/5 is too tight for a blip; the window is a deliberate CHOICE).
    opts = [
      strategy: :one_for_one,
      max_restarts: 3,
      max_seconds: 60,
      name: Fleet.Starfleet.Supervisor
    ]

    Supervisor.start_link(children, opts)
  end

  @doc """
  List of the pre-registered event atoms (`starfleet.audit_cat5_*`, `audit.verdict`,
  `fleet.boot_*`, `sdk.upstream_alert`, `mcp.server_crashed`). Part of the
  atom-leak DoS mitigation (Bus `String.to_existing_atom/1`).
  """
  @spec starfleet_event_atoms() :: [atom()]
  def starfleet_event_atoms, do: @starfleet_event_atoms
end
