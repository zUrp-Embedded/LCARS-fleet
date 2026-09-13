defmodule Fleet.Admiral do
  use Boundary,
    deps: [
      Fleet.Slug,
      Fleet.EnvParse,
      Fleet.GitRef,
      Fleet.Layout,
      Fleet.Event,
      Fleet.SchemaCache,
      Fleet.Shutdown.Quiesce,
      Fleet.PeriodicCheck,
      Fleet.EventRouter,
      Fleet.CapProfile,
      Fleet.Spawner,
      Fleet.TaskQueue,
      Fleet.Toolchain,
      Fleet.Forge,
      Fleet.MCP,
      Req
    ],
    exports: [Shutdown]

  @moduledoc """
  System administration boundary: boot orchestration, audit logging, MCP substrate
  monitoring, shutdown and toolchain reconciliation. Incident policy is declared in
  events.yaml; the domain map is lib/fleet/admiral/README.md. No direct vendor SDK.
  """

  @doc """
  Starts an unlinked, unsupervised BootOrchestrator task when the strict boolean
  :admiral_start_boot_orchestrator permits it. Fleet.Application calls this after
  root supervisor startup; that ordering is a caller responsibility, not checked here.
  Permanent boot can launch paid sessions; PermanentWarden owns subsequent recovery.
  """
  @spec boot_orchestrate() :: :ok
  def boot_orchestrate do
    if Fleet.Admiral.Application.boot_enabled?(:admiral_start_boot_orchestrator, true) do
      {:ok, _task} = Task.start(Fleet.Admiral.BootOrchestrator, :run, [[]])
      :ok
    else
      :ok
    end
  end
end
