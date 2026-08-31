defmodule Fleet.Admiral.Application do
  @moduledoc """
  Domain supervisor (the module keeps the historical `Application` name — zero reference churn).

  Supervisor for the admiral domain.

  Starts:

  ⚠ NOTHING IS PRE-REGISTERED HERE, and no schema is pre-loaded either. A reader chasing the
  atom-leak mitigation must go to `Fleet.EventRouter.Catalog`, which holds it and says so: "this
  function is the ONLY source of pre-registered event atoms". The atoms come from `events.yaml`
  through it.

  What this supervisor does is start the opt-in children, each gated by a `:start_*` config knob:
       * `Shutdown` (default `true`) — coordinated graceful shutdown; invoked by
         `bin/fleet_v2 stop` (cmd_stop RPCs `Shutdown.begin` then `:init.stop()`)
       * `AuditConsumer` (default `true`) — consumer du Bus, log AUDIT (cycle de vie + securite)
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

  @spec start_link(term()) :: Supervisor.on_start()
  def start_link(init_arg \\ []) do
    Supervisor.start_link(__MODULE__, init_arg, name: __MODULE__)
  end

  @impl Supervisor
  def init(_init_arg) do
    # V2 extensions.
    # NO UPSTREAM-VERSION WATCH HERE (BL-6-44): it lives in CI
    # (`.gitea/workflows/deps-upstream.yml`). Polling a package registry is not a control plane's
    # job — no online consumer, one more network egress from the daemon, and nothing a cron does
    # not do better — and a watch shipped OFF by default does not exist while inviting someone to
    # switch it on. MCPMonitor stays ON:
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
