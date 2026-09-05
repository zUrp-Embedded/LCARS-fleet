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
      # — external wire surface (lib fencing: every reference is declared) —
      Req
    ],
    exports: [Shutdown]

  @moduledoc """
  Le domaine SYSADMIN de la boîte, côté système : audit, MCP health, boot orchestration,
  quiesce + drain, et le rail d'outillage. Il porte le nom de sa FONCTION et non celui d'un rôle
  ([BL-6-103]) : un domaine nommé d'après un rôle suit le sens de ce rôle quand il bouge, alors même
  qu'il ne le référence pas une seule fois.

  **No pod, no inference, no automatic ACTION in this module** — the system detects, logs and
  tickets (`error_system`, the admiral inbox); a human treats, off-box.
  What an incident deserves is declared in `events.yaml` (`gate: immediate | recurrence`).

  ## Sub-modules

  The index lives in the domain's map (`lib/fleet/admiral/README.md`), where a new module costs one
  line. Duplicating it here would be a second copy of one fact, and the copy that goes stale is
  always the one nobody edits.

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
