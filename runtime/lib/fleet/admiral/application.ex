defmodule Fleet.Admiral.Application do
  @moduledoc """
  Supervisor started by Fleet.Application, not a separate OTP application.
  Each child has a strict boolean admiral_start_* setting, default true.
  Event atom registration belongs to EventRouter.Catalog.

  BootOrchestrator is triggered separately through Admiral.boot_orchestrate after
  root startup, gated by admiral_start_boot_orchestrator. Disabling Shutdown removes
  the coordinated drain server; this topology alone does not establish readiness.
  """

  use Supervisor

  @spec start_link(term()) :: Supervisor.on_start()
  def start_link(init_arg \\ []) do
    Supervisor.start_link(__MODULE__, init_arg, name: __MODULE__)
  end

  @impl Supervisor
  def init(_init_arg) do
    # NO UPSTREAM-VERSION WATCH HERE (BL-6-44): polling a package registry is not a control
    # plane's job — no online consumer, one more network egress, and nothing a cron does better.
    # MCPMonitor checks local process presence (Process.whereis) without polling an external
    # service.
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
