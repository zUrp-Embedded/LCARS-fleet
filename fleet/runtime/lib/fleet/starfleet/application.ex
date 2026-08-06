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
       * `MCPMonitor` (default `true`) — local `Process.whereis` liveness, no network

  `BootOrchestrator` is NOT a child here: as a mid-boot Task it could
  spawn permanent pods (real claude spend) BEFORE the later domains (pilot/api) are up —
  "post-readiness" would be a promise, not a mechanism. It is TRIGGERED by
  `Fleet.Application` AFTER the root `Supervisor.start_link` returns `{:ok, _}` (the whole
  fleet is provably up), still gated by `:start_boot_orchestrator` (read via `boot_enabled?/2`).

  ## Configuration

  One boolean `:start_*` knob per child (all under `:fleet_starfleet`):
  `:start_drift_monitor`, `:start_shutdown`, `:start_audit_consumer`,
  `:start_mcp_monitor` (default `true`) —
  plus `:start_boot_orchestrator` (default `true`), read by the ROOT post-boot trigger
  (`Fleet.Application`), not by this tree. Tests set a knob to `false` to start that
  child manually via `start_supervised/1`.

  ## Strategy

  `:one_for_one`, `max_restarts: 3`, `max_seconds: 60` — each child is independent;
  the widened restart window (vs OTP's 3/5) is a deliberate choice for blips.

  **Last revised**: 2026-08-03
  """

  use Supervisor

  def start_link(init_arg \\ []) do
    Supervisor.start_link(__MODULE__, init_arg, name: __MODULE__)
  end

  @impl Supervisor
  def init(_init_arg) do
    :ok = Fleet.Starfleet.Gatekeeper.init_schema!()

    # V2 extensions.
    # MCPWatcher REMOVED on 2026-08-03 (BL-6-44): upstream version watch moved to CI
    # (`.gitea/workflows/deps-upstream.yml`). It was OFF by default and had NEVER been enabled
    # anywhere — so the watch did not exist, and the code promising it invited someone to switch it
    # on. Polling a package registry is not a control plane's job: no online consumer, one more
    # network egress from the daemon, and nothing a cron does not do better. MCPMonitor stays ON:
    # purely local (Process.whereis),
    # zero network I/O, consistent with DriftMonitor/AuditConsumer).
    children =
      [] ++
        if(boot_enabled?(:start_drift_monitor, true),
          do: [Fleet.Starfleet.DriftMonitor],
          else: []
        ) ++
        if boot_enabled?(:start_shutdown, true) do
          [Fleet.Starfleet.Shutdown]
        else
          []
        end ++
        if(boot_enabled?(:start_audit_consumer, true),
          do: [Fleet.Starfleet.AuditConsumer],
          else: []
        ) ++
        if(boot_enabled?(:start_mcp_monitor, true),
          do: [Fleet.Starfleet.MCPMonitor],
          else: []
        )

    opts = [
      strategy: :one_for_one,
      max_restarts: 3,
      max_seconds: 60
    ]

    Supervisor.init(children, opts)
  end

  @doc false
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
