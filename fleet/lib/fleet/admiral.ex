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
      Fleet.EventRouter,
      Fleet.CapProfile,
      Fleet.Spawner,
      Fleet.TaskQueue,
      Fleet.Toolchain,
      Fleet.Forge,
      Fleet.MCP,
      # — external wire surface (lib fencing: every reference is declared) —
      Req
    ],
    exports: [Shutdown]

  @moduledoc """
  Le domaine SYSADMIN de la boîte, côté système : audit, MCP health, boot orchestration,
  quiesce + drain, et le rail d'outillage. Il porte le nom de sa fonction depuis le 2026-08-19
  ([BL-6-103], successeur du [BL-6-53] retiré) — il s'est appelé `Fleet.Starfleet` d'après un rôle
  dont le sens avait bougé (l'ex-rôle sysadmin devenu front desk), une homonymie que le domaine ne
  référençait pas une seule fois. Renommage en deux commits : mécanique, puis la valeur wire
  `source: :admiral` (le dernier datum) dans le sien.

  Read what follows as "the system-side sysadmin function", never as "the starfleet pod".

  **No pod, no inference, no automatic ACTION in this module** — the system detects, logs and
  tickets (`error_system`, the admiral inbox); a human treats, off-box.
  What an incident deserves is declared in `events.yaml` (`gate: immediate | recurrence`).

  ## Sub-modules

    * `Fleet.Admiral.Application` — the app's supervisor (consumers gated
      by config: test hermeticity)
    * `Fleet.Admiral.AuditConsumer` — Bus consumer of the AUDIT rail
      (lifecycle + security, log prefix `AUDIT <event.type>`)
    * `Fleet.Admiral.ToolchainReconciler` — le déclencheur du rail d'outillage
      (comparaison head↔SHA appliqué sur `PeriodicCheck` ; le seul geste privilégié du rail)
    * `Fleet.Admiral.BootOrchestrator` — post-readiness orchestrator (fire-and-forget
      Task triggered via `boot_orchestrate/0` by the root AFTER full boot;
      emits `fleet.boot_complete`/`boot_partial`/`boot_failed`)
    * `Fleet.Admiral.Shutdown` (+ behaviour `Shutdown.Dispatcher`,
      `NoOpDispatcher`, `AggregateDispatcher`) — quiesce + bounded drain of the BEAM
    * `Fleet.Admiral.MCPMonitor` — passive health check of the pod-facing
      MCP substrate (`Fleet.MCP.PodSocketSupervisor`)
    * `Fleet.Admiral.PeriodicCheck` — shared plumbing for the periodic
      checks (`MCPMonitor`)

  ## Vendor boundary

  N0 (vendor-agnostic, no direct SDK call).
  """

  @doc """
  Post-boot trigger of the `BootOrchestrator` (spawn of the permanent pods = REAL claude
  spend) — called by `Fleet.Application` AFTER the root `Supervisor.start_link` returned
  `{:ok, _}` ("post-readiness" made mechanical; an aborted boot spawns nothing).
  THE domain owns its gate (`:start_boot_orchestrator`, strict-boolean via `boot_enabled?/2` —
  `false` in test → hermetic) and its trigger; the root only says "now". `Task.start`
  non-linked: `run/1` never exits abnormally (its "never crashes the daemon" contract), and
  the resurrection rail for permanents is `PermanentWarden`, not a restart of this Task.
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
