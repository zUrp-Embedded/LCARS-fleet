# fleet_starfleet

**Date**: 2026-05-10
**Last revision**: 2026-07-05 (periodic-GenServer dedup: `MCPMonitor`/`MCPWatcher` plumbing → shared functions `Fleet.Starfleet.PeriodicCheck` (no macro), each twin keeps its init/do_check/reply shape; load-then-cache dedup: `Gatekeeper.init_schema!/0` + get-or-raise delegated to `Fleet.SchemaCache`, Ring 0 authority; 2026-07-02: Bus re-subscribe-after-restart contract test — a killed event consumer re-subscribes via `init/1` and receives the following events; `Shutdown` + real backend `AggregateDispatcher` wired in prod, `:shutdown_dispatcher` seam; contract↔code resync: complete sub-modules (`Application`, `AuditConsumer`, `BootOrchestrator`, behaviours), real `in_flight_count` (non-permanents + pending, no more in-RAM workflow runs), complete knob catalog, event atoms up to date)
**Status**: implemented — qualification pending
**Referenced by**: `04_design-notes/fleet_starfleet.md`, `STATUS-CHANTIERS.md`

System-side module consuming the outputs of the arbitration pods
(gatekeeper + other decision-making roles) on the LCARS core side, Ring 2.
Source: `04_design-notes/fleet_starfleet.md` (**CONFORMANCE**
profile, validation pattern proven by PoC).

**No pod, no inference in this module** — validation, parsing,
audit, Cat 5 escalation only.

## Sub-modules

| Module | Role |
|---|---|
| `Fleet.Starfleet.Application` | `:one_for_one` supervisor (explicit 3/60 intensity) — `Gatekeeper.init_schema!/0` fail-fast at boot, pre-registers the event atoms (`starfleet_event_atoms/0`, cf. Atom registration), starts the children gated by the `start_*` knobs (cf. Configuration) |
| `Fleet.Starfleet.Decision` | validate output struct `{decision, reason, details, chain}` |
| `Fleet.Starfleet.Gatekeeper` | pure functions validating the decision JSON (PoC-frozen) + strict schema `priv/schema/decision-v1.json` `ex_json_schema` fail-fast at load + schema cache via `Fleet.SchemaCache` (Ring 0 authority, `:persistent_term`) |
| `Fleet.Starfleet.DriftMonitor` | GenServer subscribed to `fleet.events`, 4 handlers (`pod.drift`, `workflow_map.failed`, `oauth.refresh.failed`, `audit.verdict`) — cf. Handled events. Test seams `name:` / `subscribe: false` |
| `Fleet.Starfleet.AuditConsumer` | GenServer subscribed to `fleet.events`, **selective** audit-grade logging (log only, no runtime side effect): pod lifecycle `pod.completed`/`pod.failed`, boot `fleet.boot_complete\|partial\|failed`, task-queue `work_item.*`/`state.corrupt`, V2 extensions `sdk.upstream_alert`/`mcp.server_crashed`, `pod.drift` (dormant, 0 producer). Test seam `subscribe: false` |
| `Fleet.Starfleet.BootOrchestrator` | post-readiness `:transient` Task — `Fleet.Spawner.PermanentBoot.boot_permanent_pods/0` (gated by `auto_boot_enabled?/0`, env `LCARS_BOOT_PERMANENT_AT_START`) then emits `fleet.boot_complete\|partial\|failed` (best-effort via `Bus.safe_emit`). NEVER crashes the daemon: rescue → `fleet.boot_failed`, degraded mode |
| `Fleet.Starfleet.Cat5Escalator` | pure functions `escalate/3` (source, payload, correlation_id) → `AuditLog` write + canonical broadcast `starfleet.audit_cat5_<source>` + `CoordBackend.handle_escalation/3` delegation (routing miss → `Logger.warning`, never silently swallowed). The 3 sources are wired end to end but **dormant** (input events have no live producer) |
| `Fleet.Starfleet.AuditLog` | fail-safe non-bang `File.write/3` wrapper over `~/.lcars/log/fleet-starfleet.jsonl` (NDJSON append, default path via `Fleet.Layout.state_dir()`). **Threshold rotation** (`:audit_log_max_bytes`, default 10 MB) → 1 `.1` backup: the local audit is a forensics convenience, the durable one = the forge |
| `Fleet.Starfleet.CoordBackend` | behaviour seam wrapping `Fleet.Coord` (`handle_decision/2`, `handle_escalation/3` — explicit correlation_id). `resolved/0` = **single source** of the resolved backend (config + default) read by `Cat5Escalator`/`DriftMonitor` — no default reduplicated per call site |
| `Fleet.Starfleet.CoordBackend.NotWiredYet` | default backend (consistent with the deny-by-default + fail-safe canon) — debug log + `:ok`, audit-only escalation as long as coord is not wired (prod: `runtime.exs` sets `Fleet.Coord`) |
| `Fleet.Starfleet.MCPMonitor` | periodic GenServer (60s) — passive health check of the pod-facing MCP substrate (target `{:supervised, Fleet.MCP.Supervisor, Fleet.MCP.PodSocketSupervisor}` via `which_children`, or a named atom); `:ok → :crashed` transition → broadcast `mcp.server_crashed` (recovery = log only) |
| `Fleet.Starfleet.MCPWatcher` | periodic GenServer (weekly) — version drift of the local MCP SDK (`ex_mcp`) vs Hex.pm; mismatch → broadcast `sdk.upstream_alert` (injectable fetcher `:mcp_watcher_upstream_fetcher`) |
| `Fleet.Starfleet.PeriodicCheck` | SHARED plumbing of the two twins above: `start_link(module, opts)` (named GenServer), `schedule/2` (recursive send_after), `tick/3` (handle_info body), `check_now/3` (sync test hook). Functions, no `use` macro; each twin keeps its `init/1`, its `do_check/1` and the shape of its reply. Do NOT generalize beyond these 2 modules |
| `Fleet.Starfleet.Shutdown` | coordinated grace-shutdown GenServer (`begin/1`, `drain_in_flight/1`) — ring0 design-note `lcars-fleet_service`. Historical trigger (systemd `ExecStop`) removed 2026-06-16, to be re-wired onto `fleet_v2 stop` (graceful-shutdown backlog) — **INERT** until then (no caller invokes `begin/1`); the drain logic itself stays valid. `:shutdown_dispatcher` seam (behaviour `Shutdown.Dispatcher`). `configured_dispatcher/0` = **single source** of the resolved backend (config + canonical default `NoOpDispatcher`), read at `init` AND by readiness (`fleet_api`) — no second default to keep aligned |
| `Fleet.Starfleet.Shutdown.Dispatcher` | seam behaviour (`refuse_new_jobs/1`, `in_flight_count/0`) — IS the drain abstraction (no `Fleet.Dispatcher` god-module, user decision 2026-06-05) |
| `Fleet.Starfleet.Shutdown.NoOpDispatcher` | test/fallback default backend — immediate drain, 0 in-flight (honestly-degraded, documented, not a Goodhart) |
| `Fleet.Starfleet.Shutdown.AggregateDispatcher` | **real** backend (wired prod runtime.exs) — `in_flight_count` = live **non-permanent** pods (`Spawner.list_pods` filtered by `PermanentBoot.permanent?/1` — Type 1/3 residents don't count, otherwise the drain is unreachable) + `:pending` work items (`TaskQueue.list_pending` via `apply`, only if the app is running — no layering inversion). No more RAM workflow-run counting (the `Fleet.Workflow.Executor` engine is deleted). **Fail-CLOSED**: count unreachable (restart mid-quiesce) → sentinel > 0, the drain waits out its timeout instead of wrongly concluding "empty". `refuse_new_jobs` activates `Fleet.Shutdown.Quiesce` |

(`Fleet.Starfleet` itself = head moduledoc of the namespace, no code.)

## Public API

```elixir
{:ok, %Fleet.Starfleet.Decision{decision: "halt", reason: "r", details: %{}, chain: []}} =
  Fleet.Starfleet.Gatekeeper.validate(~s|{"decision":"halt","reason":"r","details":{}}|)

# explicit correlation_id (3rd argument, nil outside a work item)
:ok = Fleet.Starfleet.Cat5Escalator.escalate(:pod_drift, %{"pod_id" => "p1", "drift_count" => 3}, nil)

:ok = Fleet.Starfleet.AuditLog.write(%{"source" => "test", "action" => "boot"})
```

## Decision schema (PoC-frozen)

```json
{
  "decision": "allow|halt|escalate|retry",
  "reason": "non-empty string",
  "details": {},
  "chain": ["string", ...]
}
```

`reason`, `decision`, `details` required. `chain` optional (default `[]`).

## Handled events (DriftMonitor)

| event_type | Cat 5 trigger |
|---|---|
| `pod.drift` | if `drift_count >= 3` — dormant: intended emitter (pod-side IPC filter) never implemented, 0 producer |
| `workflow_map.failed` | unconditional — dormant: historical producer (in-RAM engine `Fleet.Workflow.Executor`) removed |
| `oauth.refresh.failed` | unconditional — dormant: no wired producer |
| `audit.verdict` | `Gatekeeper.validate` then `CoordBackend.handle_decision/2`; unrouted verdict → `Logger.warning` (not silently dropped) |

The 3 Cat 5 paths are wired end to end (DriftMonitor → Cat5Escalator →
broadcast + coord) but dormant as long as no producer emits their input events.

## Atom registration

Event atoms pre-registered at compile time via the
`@starfleet_event_atoms` attribute of `Fleet.Starfleet.Application`
(exposed as `starfleet_event_atoms/0`):

* `starfleet.audit_cat5_{pod_drift,workflow_map_failed,oauth_refresh_failed}` — Cat 5 escalations (the old sketched `audit.cat5.*` were vestiges never emitted)
* `audit.verdict`
* `fleet.boot_{complete,partial,failed}` — BootOrchestrator lifecycle
* `sdk.upstream_alert`, `mcp.server_crashed` — V2 extensions (MCPWatcher/MCPMonitor)

Consistent with the event_router atom-leak DoS mitigation (Bus `String.to_existing_atom/1`).

## `:persistent_term` schema cache

Schema `decision-v1.json` loaded once at boot via
`Fleet.Starfleet.Gatekeeper.init_schema!/0` (called by
`Application.start/2`), delegated to the Ring 0 authority `Fleet.SchemaCache`
(`fleet_event_router` — load-then-cache dedup), key
`{Fleet.Starfleet.Gatekeeper, :decision_schema}`. Read via
`SchemaCache.fetch!/2` (actionable raise if not loaded).

## Configuration (`:fleet_starfleet` knobs)

### Supervisor children gating

All set to `false` by `config/test.exs` (hermeticity: Bus subscribers,
`fleet.boot_*` emits, timers and the global drain would pollute async tests —
dedicated tests instantiate manually with isolated opts).

| Key | Default | Gated child |
|---|---|---|
| `:start_drift_monitor` | `true` | `DriftMonitor` |
| `:start_shutdown` | `true` | `Shutdown` |
| `:start_audit_consumer` | `true` | `AuditConsumer` |
| `:start_boot_orchestrator` | `true` | `BootOrchestrator` |
| `:start_mcp_monitor` | `true` | `MCPMonitor` (purely local, zero network I/O) |
| `:start_mcp_watcher` | `false` | `MCPWatcher` — **opt-in** (outbound HTTP to Hex.pm, enable where outbound is allowed) |

### Backends (seams)

| Key | Default | Role |
|---|---|---|
| `:coord_backend` | `CoordBackend.NotWiredYet` — prod (`runtime.exs`): `Fleet.Coord` | decision/escalation backend, read via `CoordBackend.resolved/0` |
| `:shutdown_dispatcher` | `Shutdown.NoOpDispatcher` — prod (`runtime.exs`): `Shutdown.AggregateDispatcher` | drain backend, read via `Shutdown.configured_dispatcher/0` |
| `:spawner_mod` | `Fleet.Spawner` | **test-only** seam (stub a `list_pods` that raises/exits) — prod never sets this key |

### Parameters

| Key | Default | Role |
|---|---|---|
| `:decision_schema_path` | `priv/schema/decision-v1.json` (via `:code.priv_dir`) | decision JSON schema (Gatekeeper) |
| `:audit_log_path` | `Fleet.Layout.state_dir()/log/fleet-starfleet.jsonl` (≈ `~/.lcars/log/…`) — env `LCARS_STARFLEET_AUDIT_LOG` mapped by `runtime.exs` | Cat 5 audit NDJSON log |
| `:audit_log_max_bytes` | `10 * 1024 * 1024` (10 MB) | rotation threshold (1 `.1` backup) |
| `:mcp_monitor_check_interval_ms` | `60_000` | MCP health-check period |
| `:mcp_monitor_target` | `{:supervised, Fleet.MCP.Supervisor, Fleet.MCP.PodSocketSupervisor}` | liveness target (`{:supervised, sup, child_id}` or a named atom) |
| `:mcp_watcher_check_interval_ms` | `:timer.hours(168)` (weekly) | SDK version-check period |
| `:mcp_watcher_package` | `"ex_mcp"` | watched Hex.pm package |
| `:mcp_watcher_upstream_fetcher` | `nil` (→ Hex.pm API fetch via Req) | injectable fetcher (deterministic tests) |

## Tests

```bash
( cd apps/fleet_starfleet && mix test )
# 1 doctest + 57 tests, 0 failures
```

## Dependencies

* `fleet_event_router` — events PubSub Bus + `Fleet.SchemaCache` (Ring 0 load-then-cache authority)
* `fleet_cap_profile` — `Fleet.Layout.state_dir()` (default audit-log path)
* `fleet_spawner` — `PermanentBoot` (BootOrchestrator, permanent-pod filter of the drain) + `list_pods` (AggregateDispatcher); no cycle (spawner ⊀ starfleet verified)
* `:jason`, `:ex_json_schema`, `:req` (MCPWatcher — Hex.pm fetch)

**Not** mix dependencies, wired otherwise:

* `fleet_coord` — backend set at runtime by config (`runtime.exs` → `:coord_backend, Fleet.Coord`), default `NotWiredYet`
* `fleet_task_queue` — `list_pending` read via `apply` (module in a variable, no compile-time dep — no layering inversion), only if the app is actually running

## Vendor boundary

N0 (vendor-agnostic, no inference and no direct SDK call).
