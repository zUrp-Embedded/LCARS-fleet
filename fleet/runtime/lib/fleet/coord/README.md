# fleet_coord

**Date** : 2026-07-13
**Dernière révision** : 2026-07-12 (en-tête déclaratif LCARS ajouté — uniformisation acte3 vague A ; carte co-localisée `lib/fleet/<dom>/` depuis le collapse)
**Statut** : actif — coordination déclarative verdict→action (Ring 2)
**Référencé par** : `04_design-notes/fleet_coord.md`

Declarative coordination (Ring 2): a `{verdict, reason} → {action, escalation_path}`
routing table, no LLM reasoning.

**This file is a map, not the contract.** Each module owns its contract in its own
`@moduledoc` — read those (`h Fleet.Coord` in IEx, or `lib/`). Nothing here is restated,
only pointed at.

## Modules

- `Fleet.Coord` — public-API delegator (`handle_decision/2`, `handle_escalation/3`); the app entry point
- `Fleet.Coord.Policies` — the routing table (`:persistent_term`, boot-loaded + schema-validated fail-loud)
- `Fleet.Coord.Emitter` — turns a table match into a canonical `%Fleet.Event{source: :coord}` and broadcasts it
- `Fleet.Coord.Application` — `[]`-children supervisor (boot runs `Policies.init_policies!/0` only)

## Config & deps

- Knob `:fleet_coord, :policies_path` — read by `Policies`, set by `runtime.exs` from `LCARS_COORD_POLICIES_PATH`.
- Policies data: `priv/coord/config/coord-policies.yaml` (format documented in `Fleet.Coord.Policies`).
- Deps: see `mix.exs`.
