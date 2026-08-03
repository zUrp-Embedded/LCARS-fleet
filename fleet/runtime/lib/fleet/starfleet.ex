defmodule Fleet.Starfleet do
  # COMPILED frontier of the domain: deps = the declared inter-domain graph, exports = the
  # MEASURED cross-domain surface (started at [] — only observed, reviewed violations were
  # added). The compiler refuses any violation — no discipline required. Shrinking it is a
  # deliberate API gesture.
  use Boundary,
    deps: [
      Fleet.Slug,
      Fleet.EnvParse,
      Fleet.GitRef,
      Fleet.Layout,
      Fleet.Event,
      # Validated verdict, foundation value (moved down out of Starfleet so Coord can require it): Gatekeeper BUILDS it.
      Fleet.Decision,
      Fleet.SchemaCache,
      Fleet.Shutdown.Quiesce,
      Fleet.EventRouter,
      Fleet.CapProfile,
      Fleet.Spawner,
      Fleet.TaskQueue,
      Fleet.Coord,
      Fleet.MCP,
      # — external wire surface (lib fencing: every reference is declared) —
      Req
    ],
    exports: [Shutdown, CoordBackend]

  @moduledoc """
  ⚠ **This domain is named after a role whose meaning moved, and the name has not caught up yet.**
  `starfleet` was the SYSADMIN role — a sudo agent that kept the box running. What lives here is the
  system-side half of that job: audit, Cat 5 escalation, drift, MCP health, boot orchestration,
  quiesce + drain. Then the role became the fleet-level front desk, and this domain kept a name that
  no longer describes it — it does not reference that role once. Target name: `sysadmin`
  (BL-6-53, deliberately deferred: two of its four surfaces are DATA, not identifiers — the wire
  value `%Fleet.Event{source: :starfleet}` and the interpolated topics `starfleet.audit_cat5_<x>`).

  Read what follows as "the system-side sysadmin function", never as "the starfleet pod".

  System-side module consuming the outputs of arbitration pods
  (gatekeeper + other decision-making roles) on the system side.

  **No pod, no inference in this module** — validation, parsing, audit,
  Cat 5 escalation only.

  ## Sub-modules

    * `Fleet.Starfleet.Application` — the app's supervisor (consumers gated
      by config: test hermeticity)
    * `Fleet.Decision` — validated-output struct (foundation — moved down so Coord can require it without a Starfleet dep)
    * `Fleet.Starfleet.Gatekeeper` — pure functions, decision-JSON
      validation (frozen `{decision, reason, details, chain}` schema)
    * `Fleet.Starfleet.DriftMonitor` — GenServer subscribing to `fleet.events`,
      4 handlers: `workflow_map.failed` + `audit.verdict` (draft producers, live);
      `pod.drift` + `oauth.refresh.failed` (wired but DORMANT — no producer)
    * `Fleet.Starfleet.Cat5Escalator` — pure functions, Cat 5 escalation:
      canonical broadcast `starfleet.audit_cat5_<source>` + `CoordBackend` delegation
    * `Fleet.Starfleet.AuditLog` — pure functions, fail-safe non-bang `File.write`
      wrapper, rotated NDJSON (default `~/.lcars/log/fleet-starfleet.jsonl`,
      knob `:audit_log_path`)
    * `Fleet.Starfleet.CoordBackend` — seam wrapping `Fleet.Coord`
      (default `NotWiredYet`)
    * `Fleet.Starfleet.AuditConsumer` — Bus consumer of the AUDIT rail
      (lifecycle + security, log prefix `AUDIT <event.type>`)
    * `Fleet.Starfleet.BootOrchestrator` — post-readiness orchestrator (fire-and-forget
      Task triggered via `boot_orchestrate/0` by the root AFTER full boot;
      emits `fleet.boot_complete`/`boot_partial`/`boot_failed`)
    * `Fleet.Starfleet.Shutdown` (+ behaviour `Shutdown.Dispatcher`,
      `NoOpDispatcher`, `AggregateDispatcher`) — quiesce + bounded drain of the BEAM
    * `Fleet.Starfleet.MCPMonitor` — passive health check of the pod-facing
      MCP substrate (`Fleet.MCP.PodSocketSupervisor`)
    * `Fleet.Starfleet.PeriodicCheck` — shared plumbing for the periodic
      checks (`MCPMonitor`)

  ## Vendor boundary

  N0 (vendor-agnostic, no direct SDK call).

  **Last revised**: 2026-08-04
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
    if Fleet.Starfleet.Application.boot_enabled?(:start_boot_orchestrator, true) do
      {:ok, _task} = Task.start(Fleet.Starfleet.BootOrchestrator, :run, [[]])
      :ok
    else
      :ok
    end
  end
end
