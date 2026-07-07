# fleet_coord

**Date**: 2026-05-10
**Last revision**: 2026-07-05 (contract resync against the code: `Application` in the table, real emitted event names, Configuration section, complete deps, canonical test form; emission pass extracted into `Fleet.Coord.Emitter` (build + broadcast of the canonical event), `Policies` = table only; load-then-cache dedup: coord-policies schema resolved ONCE via `Fleet.SchemaCache` — before: re-read+resolve on EVERY `validate_against_schema!` — and get-or-raise of the table via `SchemaCache.fetch!/2`; 2026-07-04: SoftGate/Hook/HookSpawner removed — LLM gates consolidated on the gatekeeper on the workflow side; coord = pure declarative policies)
**Status**: implemented — qualification pending
**Referenced by**: `04_design-notes/fleet_coord.md`, `STATUS-CHANTIERS.md`

System-side Elixir module: declarative routing table
`{verdict, reason} → {action, escalation_path}` LCARS v2 Ring 2
orchestration. Source: `04_design-notes/fleet_coord.md`
(**CONFORMANCE** profile, mechanism proven by PoC).

**No LLM reasoning logic**: `coord` = pure declarative policies
(target-architecture meta-axiom: a coord that needs LLM reasoning betrays
a flawed design — tighten the workflow/rules, don't enrich the coord). The
LLM judgment of the workflow gates is **consolidated on the gatekeeper**
(single judge), booted on the `fleet_workflow` side (2026-07-04
consolidation) — `coord` no longer carries any soft gate / hook.

## Sub-modules

| Module | Role |
|---|---|
| `Fleet.Coord` | public-API delegator (`handle_decision/2` / `handle_escalation/3`) |
| `Fleet.Coord.Application` | supervisor with `[]` children (minimal tree, umbrella OTP consistency). At boot: `Policies.init_policies!/0` **fail-loud** (absent/malformed/schema-invalid YAML → the boot crashes, never a "green" empty table). No atom pre-registration: the emitted events are interned at compile-time by the literals in `emitter.ex` |
| `Fleet.Coord.Emitter` | EMISSION pass (extracted 2026-07-05): translates a policy match into a canonical `%Fleet.Event{source: :coord}` and broadcasts it — `notify_dashboard` → `coord.notification_routed`, `escalate_human` → `coord.escalation_triggered`, any other action string → `coord.action_dispatched` (extensible without recompile). Best-effort via `Bus.safe_emit/4` (UnregisteredError silent at boot order, malformed event logged ERROR then neutralized); `correlation_id` propagated on every broadcast |
| `Fleet.Coord.Policies` | pure-functions table mapping `{verdict, reason} → {action, escalation_path}`, lookup on a `:persistent_term` cache boot-loaded from `priv/config/coord-policies.yaml`; a match is handed to `Emitter.dispatch_action/4` (emission delegated). **`init_policies!/0` VALIDATES the parsed YAML against `priv/schema/coord-policies-v1.json` (ExJsonSchema) at boot** — a map-but-structurally-invalid coord-policies (mapping without `action`, non-array `escalation_path`, key outside the pattern…) FAIL-LOUD like an absent/unreadable file (before: only "is a map" was checked, the schema validation only ran in test). Structural-only: resolvability of handlers/targets is verified at runtime, not by the schema. Schema `coord-policies-v1.json` resolved ONCE via `Fleet.SchemaCache` (Ring 0 authority — before the dedup: re-read on every call), policies table read via `SchemaCache.fetch!/2` |

> **Removed (2026-07-04)**: `Fleet.Coord.SoftGate` / `Fleet.Coord.Hook` /
> `Fleet.Coord.HookSpawner` (+ its `HookSpawner.NotWiredYet` placeholder —
> distinct from `Fleet.Starfleet.CoordBackend.NotWiredYet`, which still
> exists as the default backend seam). The soft gate and the non-decidable
> terminal are judged by the **gatekeeper** (`Fleet.Workflow.Gates` returns
> `{:dispatch_gatekeeper, info}`; the forge-driven rail
> `Fleet.Pilot.StepRunConsumer` enqueues the eval brief and collects the
> decision — the in-memory (RAM) `Executor` engine is removed).

## Public API

```elixir
# Backend fleet_starfleet (handle_decision + handle_escalation)
:ok = Fleet.Coord.handle_decision(decision, correlation_id)

:ok = Fleet.Coord.handle_escalation(:pod_drift, %{"pod_id" => "p1"}, correlation_id)
```

## Backend wiring (`fleet_starfleet`)

`Fleet.Coord` satisfies the `Fleet.Starfleet.CoordBackend` behaviour **by
convention** (callback shapes `handle_decision/2` + `handle_escalation/3`;
no `@behaviour` declaration — `fleet_coord` has no compile dep on
`fleet_starfleet`, inherent to the topology: the backend is resolved by
config at runtime). Runtime configuration:

```elixir
config :fleet_starfleet, :coord_backend, Fleet.Coord
```

(No more `:fleet_workflow, :coord_backend` — removed 2026-07-04: the
workflow no longer delegates the LLM gate to coord.)

## `priv/config/coord-policies.yaml` format

```yaml
mappings:
  "halt.gatekeeper.refuse":
    action: notify_dashboard
    escalation_path: [dashboard, issue_comment]
  "escalate.pod_drift":
    action: escalate_human
    escalation_path: [dashboard, starfleet_alert]
```

Mapping key `"<verdict>.<reason>"` or `"escalate.<source>"`. Extensible
by PR without recompile (consistent with the ecosystem's declarative-data
pattern).

## Broadcast actions

| Action | Broadcast event (`Fleet.Coord.Emitter`) |
|---|---|
| `notify_dashboard` | `coord.notification_routed` (target `"dashboard"`) |
| `escalate_human` | `coord.escalation_triggered` (target `"operator"`) |
| any other action string | `coord.action_dispatched` (action in the payload — extensible without recompile) |

Events are broadcast via `Fleet.EventRouter.Bus` (`safe_emit/4`,
best-effort) and consumed by `fleet_api` for the live dashboard push (its
WS handler subscribes to the Bus).

## Configuration

| Knob | Default | Role |
|---|---|---|
| `:fleet_coord, :policies_path` | the app's `priv/config/coord-policies.yaml` | path of the policies YAML, loaded fail-loud at boot by `init_policies!/0`. Set by `runtime.exs` from `LCARS_COORD_POLICIES_PATH` when present |

The backend wiring (`config :fleet_starfleet, :coord_backend, Fleet.Coord`)
is set by `runtime.exs` — a `fleet_starfleet` key, not this app's.

## Tests

```bash
( cd apps/fleet_coord && mix test )   # NOT `mix test apps/…` from the root (0 tests collected = false green)
```

## Dependencies

(declared in `mix.exs`)

* `fleet_event_router` — PubSub Bus, action broadcast
* `:yaml_elixir`
* `:ex_json_schema`, `:jason` — validation of the policies YAML against `priv/schema/coord-policies-v1.json` at boot (direct deps, used in lib)

## Vendor boundary

N0 (vendor-agnostic, no inference in this module — pure declarative
policies; the LLM judgment of the gates lives on the `fleet_workflow`
side → gatekeeper, since the 2026-07-04 consolidation).
