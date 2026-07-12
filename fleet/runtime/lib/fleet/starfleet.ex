defmodule Fleet.Starfleet do
  # Z4 migration (2026-07-12) — frontière COMPILÉE du domaine : deps = graphe ex-umbrella
  # régularisé (successeur mécanique du verrou topologie, D-19), exports: :all = 1ʳᵉ passe
  # (serrage par façade en Z4b). Le compilateur refuse toute violation — plus de discipline.
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
      Fleet.Coord,
      Fleet.MCP,
      # — surface wire externe (fencing Z4b : chaque référence est déclarée) —
      Req
    ],
    exports: :all
  @moduledoc """
  System-side module consuming the outputs of arbitration pods
  (gatekeeper + other decision-making roles) on the LCARS core Ring 2 side.

  **No pod, no inference in this module** — validation, parsing, audit,
  Cat 5 escalation only.

  ## Sub-modules

    * `Fleet.Starfleet.Application` — the app's supervisor (consumers gated
      by config: test hermeticity)
    * `Fleet.Starfleet.Decision` — validated-output struct
    * `Fleet.Starfleet.Gatekeeper` — pure functions, decision-JSON
      validation (frozen `{decision, reason, details, chain}` schema)
    * `Fleet.Starfleet.DriftMonitor` — GenServer subscribing to `fleet.events`,
      4 handlers (`pod.drift`, `workflow_map.failed`, `oauth.refresh.failed`,
      `audit.verdict`)
    * `Fleet.Starfleet.Cat5Escalator` — pure functions, Cat 5 escalation:
      canonical broadcast `starfleet.audit_cat5_<source>` + `CoordBackend` delegation
    * `Fleet.Starfleet.AuditLog` — pure functions, fail-safe non-bang `File.write`
      wrapper, rotated NDJSON (default `~/.lcars/log/fleet-starfleet.jsonl`,
      knob `:audit_log_path`)
    * `Fleet.Starfleet.CoordBackend` — seam wrapping `Fleet.Coord`
      (default `NotWiredYet`)
    * `Fleet.Starfleet.AuditConsumer` — Bus consumer of the AUDIT rail
      (lifecycle + security, log prefix `AUDIT <event.type>`)
    * `Fleet.Starfleet.BootOrchestrator` — post-readiness orchestrator
      (`:transient` Task, emits `fleet.boot_complete`/`boot_partial`/`boot_failed`)
    * `Fleet.Starfleet.Shutdown` (+ behaviour `Shutdown.Dispatcher`,
      `NoOpDispatcher`, `AggregateDispatcher`) — quiesce + bounded drain of the BEAM
    * `Fleet.Starfleet.MCPMonitor` — passive health check of the pod-facing
      MCP substrate (`Fleet.MCP.PodSocketSupervisor`)
    * `Fleet.Starfleet.MCPWatcher` — passive cron: upstream version drift
      of the Elixir MCP SDK on Hex.pm
    * `Fleet.Starfleet.PeriodicCheck` — shared plumbing for the periodic
      checks (`MCPMonitor`, `MCPWatcher`)

  ## Vendor boundary

  N0 (vendor-agnostic, no direct SDK call).
  """
end
