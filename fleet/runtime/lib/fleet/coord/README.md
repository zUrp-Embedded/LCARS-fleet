# Fleet.Coord — domain card

**Date**: 2026-07-13
**Last revised**: 2026-08-01
**Status**: active — declarative verdict→action coordination
**Referenced by**: —

Declarative coordination (pod primitive): a `{verdict, reason} → {action, escalation_path}`
routing table, no LLM reasoning.

**This file is a map, not the contract.** Each module owns its contract in its own
`@moduledoc` — read those (`h Fleet.Coord` in IEx, or `lib/`). Nothing here is restated,
only pointed at.

## Modules

- `Fleet.Coord` — public-API delegator (`handle_decision/2`, `handle_escalation/3`); the domain entry point
- `Fleet.Coord.Policies` — the routing table (`:persistent_term`, boot-loaded + schema-validated fail-loud)
- `Fleet.Coord.Emitter` — turns a table match into a canonical `%Fleet.Event{source: :coord}` and broadcasts it
- `Fleet.Coord.Application` — `[]`-children supervisor (boot runs `Policies.init_policies!/0` only)

## Config & deps

- Knob `:fleet_coord, :policies_path` — read by `Policies`, set by `runtime.exs` from `LCARS_COORD_POLICIES_PATH`.
- Policies data: `priv/catalogue/coord/config/coord-policies.yaml` (format documented in `Fleet.Coord.Policies`).
- Deps: the facade's `use Boundary` declaration (`lib/fleet/coord.ex`).
