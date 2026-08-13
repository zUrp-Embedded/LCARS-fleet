# Fleet.Starfleet — domain card

**Date**: 2026-07-13
**Last revised**: 2026-08-13
**Status**: active — system-side audit/validation, N0
**Referenced by**: —

System-side audit/validation domain, N0 — consumes the outputs of the
arbitration pods (gatekeeper + other decision roles) on the LCARS core side.
**No pod, no inference here** — validation, parsing, audit, Cat 5 escalation only.

**This file is a map, not the contract.** Each module owns its contract in its own
`@moduledoc` — read those (`h Fleet.Starfleet` in IEx, or `lib/`). Nothing here is
restated, only pointed at.

## Modules
- `Fleet.Starfleet` — domain façade + `use Boundary` declaration; carries `boot_orchestrate/0` (triggered post-boot by the root). NOT a pure/empty namespace.
- `Fleet.Starfleet.Application` — `:one_for_one` supervisor (3/60); boot fail-fast schema load + compile-time event-atom pre-registration + five `:start_*`-gated children (BootOrchestrator is NOT one: triggered post-boot by the root via `Fleet.Starfleet.boot_orchestrate/0`)
- `Fleet.Starfleet.Gatekeeper` — pure decision-JSON validation against the frozen `decision-v1.json` schema (boot-loaded into the foundation `Fleet.SchemaCache`)
- `Fleet.Decision` — the validated `{decision, reason, details, chain}` output struct (foundation: moved out of Starfleet — Coord cannot name a Starfleet type without a cycle)
- `Fleet.Starfleet.DriftMonitor` — Bus subscriber routing 3 event types to Cat 5 / coord (`audit.verdict`, `workflow_map.failed` have live/draft producers; `pod.drift` is dormant — handler wired + tested, no producer emits, condition of end written in `events.yaml`)
- `Fleet.Starfleet.Cat5Escalator` — pure functions: audit-log write + canonical `starfleet.audit_cat5_<source>` broadcast + coord delegation
- `Fleet.Starfleet.AuditConsumer` — Bus consumer of the AUDIT rail (lifecycle + security, log-only)
- `Fleet.Starfleet.AuditLog` — fail-safe NDJSON writer with threshold rotation
- `Fleet.Starfleet.BootOrchestrator` — post-readiness orchestrator (fire-and-forget Task, triggered by the root AFTER full boot): boots permanent pods, emits `fleet.boot_*`, never crashes the daemon
- `Fleet.Starfleet.CoordBackend` (+ `NotWiredYet`) — behaviour seam over `Fleet.Coord`; `resolved/0` = single source of the wired backend
- `Fleet.Starfleet.Shutdown` (+ `Shutdown.Dispatcher` behaviour, `NoOpDispatcher`, `AggregateDispatcher`) — coordinated grace-drain (invoked by `bin/fleet_v2 stop`); `configured_dispatcher/0` = single source, `AggregateDispatcher` = fail-closed prod in-flight count
- `Fleet.Starfleet.MCPMonitor` / `MCPWatcher` (+ shared `PeriodicCheck`) — the two periodic GenServers: local MCP-substrate liveness and Hex.pm SDK version drift

## Config & deps
- Child gating (`:fleet_starfleet`) read by `Application` — `:start_drift_monitor`, `:start_shutdown`, `:start_audit_consumer`, `:start_boot_orchestrator`, `:start_mcp_monitor` (default `true`), `:start_mcp_watcher` (default `false`, outbound HTTP); all forced `false` in `test.exs`.
- Backend seams — `:coord_backend` (read via `CoordBackend.resolved/0`), `:shutdown_dispatcher` (read via `Shutdown.configured_dispatcher/0`), `:completion_inflight_fun` (CI-02 drain: in-flight completion offloads, wired to a Pilot fn since Starfleet ∌ Pilot), `:task_queue_mod` (test-only stub for the drain's `list_active` count); prod values set by `runtime.exs`.
- Params, each read by its owning module (defaults in the `@moduledoc`) — `:decision_schema_path`, `:audit_log_path` / `:audit_log_max_bytes`, `:mcp_monitor_check_interval_ms` / `:mcp_monitor_target`, `:mcp_watcher_check_interval_ms` / `:mcp_watcher_package` / `:mcp_watcher_upstream_fetcher`.
- Deps: declared in `Fleet.Starfleet`'s `use Boundary` (compile-enforced) — incl. `Fleet.Coord` and `Fleet.TaskQueue`, which ARE compile deps (`AggregateDispatcher` calls `Fleet.TaskQueue.list_active/0` directly; never a module-in-variable/`apply` detour). The completion count crosses to `Fleet.Pilot` (NOT a dep) as a runtime fun via `:completion_inflight_fun`. The runtime seams are the injected backends above (`:coord_backend`, `:shutdown_dispatcher`, `:completion_inflight_fun`, `:task_queue_mod` test-only) — not Coord/TaskQueue.
