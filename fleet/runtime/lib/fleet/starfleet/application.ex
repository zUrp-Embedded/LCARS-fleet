defmodule Fleet.Starfleet.Application do
  @moduledoc """
  Domain supervisor (the module keeps the historical `Application` name — zero reference churn).

  Supervisor for the starfleet domain.

  Starts:

    1. Pre-loads the decision schema via
       `Fleet.Starfleet.Gatekeeper.init_schema!/0` (boot fail-fast)
    2. Pre-registers the `starfleet.audit_cat5_*`, `audit.verdict`, `fleet.boot_*`,
       `sdk.upstream_alert` and `mcp.server_crashed` event atoms (compile-time via a
       module attribute, atom-leak DoS mitigation)
    3. Supervises five opt-in children, each gated by a `:start_*` config knob:
       * `DriftMonitor` (default `true`) — GenServer subscriber for pod drift
       * `Shutdown` (default `true`) — coordinated graceful shutdown; invoked by
         `bin/fleet_v2 stop` (cmd_stop RPCs `Shutdown.begin` then `:init.stop()`)
       * `AuditConsumer` (default `true`) — audit-verdict NDJSON rail
       * `MCPWatcher` (default `false`) — HTTP egress to Hex.pm (SDK upstream alert),
         opt-in only where outbound is allowed
       * `MCPMonitor` (default `true`) — local `Process.whereis` liveness, no network

  `BootOrchestrator` is NOT a child here: as a mid-boot Task it could
  spawn permanent pods (real claude spend) BEFORE the later domains (pilot/api) are up —
  "post-readiness" would be a promise, not a mechanism. It is TRIGGERED by
  `Fleet.Application` AFTER the root `Supervisor.start_link` returns `{:ok, _}` (the whole
  fleet is provably up), still gated by `:start_boot_orchestrator` (read via `boot_enabled?/2`).

  ## Configuration

  One boolean `:start_*` knob per child (all under `:fleet_starfleet`):
  `:start_drift_monitor`, `:start_shutdown`, `:start_audit_consumer`,
  `:start_mcp_watcher` (default `false`), `:start_mcp_monitor` (default `true`) —
  plus `:start_boot_orchestrator` (default `true`), read by the ROOT post-boot trigger
  (`Fleet.Application`), not by this tree. Tests set a knob to `false` to start that
  child manually via `start_supervised/1`.

  ## Strategy

  `:one_for_one`, `max_restarts: 3`, `max_seconds: 60` — each child is independent;
  the widened restart window (vs OTP's 3/5) is a deliberate choice for blips.

  **Last revised**: 2026-07-21
  """

  use Supervisor

  def start_link(init_arg \\ []) do
    Supervisor.start_link(__MODULE__, init_arg, name: __MODULE__)
  end

  @impl Supervisor
  def init(_init_arg) do
    :ok = Fleet.Starfleet.Gatekeeper.init_schema!()

    # V2 extensions.
    # MCPWatcher: default OFF (HTTP I/O to Hex.pm — opt-in in prod where outbound
    # is allowed). MCPMonitor: default ON (purely local Process.whereis,
    # zero network I/O, consistent with DriftMonitor/AuditConsumer).
    children =
      [] ++
        if(boot_enabled?(:start_drift_monitor, true),
          do: [Fleet.Starfleet.DriftMonitor],
          else: []
        ) ++
        if boot_enabled?(:start_shutdown, true) do
          # Coordinated graceful shutdown — must stay alive to serve the shutdown
          # RPC issued by `bin/fleet_v2 stop` (cmd_stop → `Shutdown.begin` then `:init.stop()`).
          [Fleet.Starfleet.Shutdown]
        else
          []
        end ++
        if(boot_enabled?(:start_audit_consumer, true),
          do: [Fleet.Starfleet.AuditConsumer],
          else: []
        ) ++
        if(boot_enabled?(:start_mcp_watcher, false),
          do: [Fleet.Starfleet.MCPWatcher],
          else: []
        ) ++
        if(boot_enabled?(:start_mcp_monitor, true),
          do: [Fleet.Starfleet.MCPMonitor],
          else: []
        )

    # Restart intensity 3/60 EXPLICIT (event_router/task_queue doctrine — the OTP default 3/5 is too tight for a blip; the window is a deliberate CHOICE).
    opts = [
      strategy: :one_for_one,
      max_restarts: 3,
      max_seconds: 60
    ]

    Supervisor.init(children, opts)
  end

  @doc false
  # Boot-topology knob → STRICT boolean. A `:start_*` config governs the supervision tree; reading it with
  # a bare `if Application.get_env(...)` (truthiness) means a malformed value silently changes the topology:
  # a string `"false"` or `0` is TRUTHY → the child starts anyway; a stray `nil` is falsy → the child is
  # skipped even when its default is `true`. So we PARSE at the boundary: a boolean is honoured, absence
  # yields the (boolean) default, and any non-boolean value FAILS LOUD at boot (fail-closed — a containment/
  # topology knob must never be interpreted, and a boot on a malformed config must crash visibly, not drift).
  @spec boot_enabled?(atom(), boolean()) :: boolean()
  def boot_enabled?(key, default) when is_atom(key) and is_boolean(default) do
    case Application.get_env(:fleet_starfleet, key, default) do
      v when is_boolean(v) ->
        v

      other ->
        raise ArgumentError,
              "Fleet.Starfleet boot knob #{inspect(key)} must be a boolean, got #{inspect(other)} — a " <>
                "malformed boot config must not silently change the supervision topology (fail-closed at boot)"
    end
  end
end
