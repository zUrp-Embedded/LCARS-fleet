defmodule Fleet.Admiral.Application do
  @moduledoc """
  Domain supervisor (the module keeps the historical `Application` name — zero reference churn).

  Supervisor for the admiral domain.

  Starts:

    1. (retiré 2026-08-19, brouette — le pré-chargement du schéma de décision est parti avec
       `Gatekeeper`/`decision-v1.json` : le validateur gardait une chaîne sans acte)
    2. ⚠ NOTHING IS PRE-REGISTERED HERE, and this step used to claim it was. It read
       "pre-registers … event atoms (compile-time via a module attribute, atom-leak DoS
       mitigation)" — there is no such attribute in this module, nor anywhere under
       `admiral/`. The atoms come from `events.yaml` through
       `Fleet.EventRouter.Catalog`, which says so itself: "this function is the ONLY
       source of pre-registered event atoms". A reader chasing the atom-leak mitigation
       here found a sentence instead of a mechanism.
       (`sdk.upstream_alert` was also named in that list — removed 2026-08-14, cf. 6-016:
       it was `MCPWatcher`'s declared half, and the module left on 2026-08-03.)
    3. Supervises the opt-in children, each gated by a `:start_*` config knob:
       * `Shutdown` (default `true`) — coordinated graceful shutdown; invoked by
         `bin/fleet_v2 stop` (cmd_stop RPCs `Shutdown.begin` then `:init.stop()`)
       * `AuditConsumer` (default `true`) — audit-verdict NDJSON rail
       * `MCPMonitor` (default `true`) — local `Process.whereis` liveness, no network
       * `ToolchainReconciler` (default `true`) — le rail d'outillage (head↔SHA, `PeriodicCheck`)

  `BootOrchestrator` is NOT a child here: as a mid-boot Task it could
  spawn permanent pods (real claude spend) BEFORE the later domains (pilot/api) are up —
  "post-readiness" would be a promise, not a mechanism. It is TRIGGERED by
  `Fleet.Application` AFTER the root `Supervisor.start_link` returns `{:ok, _}` (the whole
  fleet is provably up), still gated by `:start_boot_orchestrator` (read via `boot_enabled?/2`).

  ## Configuration

  One boolean `:admiral_start_*` knob per child (all under `:lcars_fleet`):
  `:start_shutdown`, `:start_audit_consumer`,
  `:start_mcp_monitor`, `:start_toolchain_reconciler` (default `true`) —
  plus `:start_boot_orchestrator` (default `true`), read by the ROOT post-boot trigger
  (`Fleet.Application`), not by this tree. Tests set a knob to `false` to start that
  child manually via `start_supervised/1`.

  ## Strategy

  `:one_for_one`, `max_restarts: 3`, `max_seconds: 60` — each child is independent;
  the widened restart window (vs OTP's 3/5) is a deliberate choice for blips.
  """

  use Supervisor

  def start_link(init_arg \\ []) do
    Supervisor.start_link(__MODULE__, init_arg, name: __MODULE__)
  end

  @impl Supervisor
  def init(_init_arg) do
    # V2 extensions.
    # MCPWatcher REMOVED on 2026-08-03 (BL-6-44): upstream version watch moved to CI
    # (`.gitea/workflows/deps-upstream.yml`). It was OFF by default and had NEVER been enabled
    # anywhere — so the watch did not exist, and the code promising it invited someone to switch it
    # on. Polling a package registry is not a control plane's job: no online consumer, one more
    # network egress from the daemon, and nothing a cron does not do better. MCPMonitor stays ON:
    # purely local (Process.whereis),
    # zero network I/O, consistent with AuditConsumer).
    children =
      [] ++
        if boot_enabled?(:admiral_start_shutdown, true) do
          [Fleet.Admiral.Shutdown]
        else
          []
        end ++
        if(boot_enabled?(:admiral_start_audit_consumer, true),
          do: [Fleet.Admiral.AuditConsumer],
          else: []
        ) ++
        if(boot_enabled?(:admiral_start_mcp_monitor, true),
          do: [Fleet.Admiral.MCPMonitor],
          else: []
        ) ++
        if(boot_enabled?(:admiral_start_toolchain_reconciler, true),
          do: [Fleet.Admiral.ToolchainReconciler],
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
    case Application.get_env(:lcars_fleet, key, default) do
      v when is_boolean(v) ->
        v

      other ->
        raise ArgumentError,
              "Fleet.Admiral boot knob #{inspect(key)} must be a boolean, got #{inspect(other)} — a " <>
                "malformed boot config must not silently change the supervision topology (fail-closed at boot)"
    end
  end
end
