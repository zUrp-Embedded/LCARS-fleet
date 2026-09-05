defmodule Fleet.Admiral.Application do
  @moduledoc """
  Supervisor of the admiral domain. The name `Application` is the supervisor's, not an OTP app's —
  this tree is started by `Fleet.Application`, the one OTP callback.

  ⚠ NOTHING IS PRE-REGISTERED HERE, and no schema is pre-loaded either. A reader chasing the
  atom-leak mitigation must go to `Fleet.EventRouter.Catalog`, which holds it and says so: "this
  function is the ONLY source of pre-registered event atoms". The atoms come from `events.yaml`
  through it.

  What it starts is the opt-in children of `init/1`, each behind its own
  `:lcars_fleet, :admiral_start_*` boolean (default `true`, `false` in test — hermeticity; a test
  that needs one starts it with `start_supervised/1`). The list is the code below, and the domain's
  map names what each child is for.

  ⚠ `Shutdown` is one of them, and its absence is not inert: `bin/fleet stop` RPCs
  `Shutdown.begin` before `:init.stop()`, so a container that disabled it stops WITHOUT draining.

  `BootOrchestrator` is NOT a child here: as a mid-boot Task it could
  spawn permanent pods (real claude spend) BEFORE the later domains (pilot/api) are up —
  "post-readiness" would be a promise, not a mechanism. It is TRIGGERED by
  `Fleet.Application` AFTER the root `Supervisor.start_link` returns `{:ok, _}` (the whole
  fleet is provably up), still gated by `:start_boot_orchestrator` (read via `boot_enabled?/2`).

  ⚠ `:admiral_start_boot_orchestrator` EXISTS but is NOT read here: the ROOT reads it, post-boot.
  A knob named like the four above, honoured by another module, is the one an operator will look
  for in this tree.

  ## Strategy

  `:one_for_one` — each child is independent. The restart window is deliberately WIDER than OTP's
  default: these children tolerate blips, and a stricter window would take the domain down for one.
  """

  use Supervisor

  @spec start_link(term()) :: Supervisor.on_start()
  def start_link(init_arg \\ []) do
    Supervisor.start_link(__MODULE__, init_arg, name: __MODULE__)
  end

  @impl Supervisor
  def init(_init_arg) do
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
