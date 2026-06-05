# fleet_coord (chantier 14)

**Date** : 2026-05-10
**Dernière révision** : 2026-06-05 (R06 — retrait SoftGate/Hook/HookSpawner : gates LLM consolidées sur le gatekeeper côté pipeline ; coord = policies déclaratives pures)
**Statut** : impl att-1 — qualifier en attente
**Référencé par** : `04_design-notes/fleet_coord.md`, `STATUS-CHANTIERS.md`

Module Elixir système-side : table de routage déclarative
`{verdict, reason} → {action, escalation_path}` LCARS v2 Ring 2
orchestration. Source : `04_design-notes/fleet_coord.md`
(Régime 1, profil **CONFORMANCE**, PoC-π3 PROVEN).

**Aucune logique de raisonnement LLM** : `coord` = policies déclaratives
pures (méta-axiome architecture-cible §L441). Le jugement LLM des gates
pipeline est **consolidé sur le gatekeeper** (juge unique), spawné côté
`fleet_pipeline` (R06) — `coord` ne porte plus de soft gate / hook.

## Sous-modules

| Module | Rôle |
|---|---|
| `Fleet.Coord` | delegator API publique (`handle_decision` / `handle_escalation`) |
| `Fleet.Coord.Policies` | pure functions table mapping `{verdict, reason} → {action, escalation_path}` lookup `:persistent_term` cache boot-loaded `priv/config/coord-policies.yaml` + broadcast events `coord.action.*` / `coord.notify.dashboard` / `coord.escalate.human` |

> **Retiré (R06)** : `Fleet.Coord.SoftGate` / `Fleet.Coord.Hook` /
> `Fleet.Coord.HookSpawner` (+ `NotWiredYet`). Le soft gate et le terminal
> non-tranchable sont jugés par le **gatekeeper** (`Fleet.Pipeline.Gates`
> retourne `{:dispatch_gatekeeper, info}`, l'Executor spawn + ré-évalue).

## Public API

```elixir
# Backend fleet_starfleet (handle_decision + handle_escalation)
:ok = Fleet.Coord.handle_decision(decision, correlation_id)

:ok = Fleet.Coord.handle_escalation(:pod_drift, %{"pod_id" => "p1"}, correlation_id)
```

## Wiring backend ch13

`Fleet.Coord` satisfait le behaviour `Fleet.Starfleet.CoordBackend`
(`handle_decision/2` + `handle_escalation/3`). Configuration runtime :

```elixir
config :fleet_starfleet, :coord_backend, Fleet.Coord
```

(Plus de `:fleet_pipeline, :coord_backend` — supprimé en R06 : le pipeline
ne délègue plus la gate LLM à coord.)

## Format `priv/config/coord-policies.yaml`

```yaml
mappings:
  "halt.gatekeeper.refuse":
    action: notify_dashboard
    escalation_path: [dashboard, ticket_comment]
  "escalate.pod_drift":
    action: escalate_human
    escalation_path: [dashboard, starfleet_alert]
```

Mapping key `"<verdict>.<reason>"` ou `"escalate.<source>"`. Extensible
PR sans recompile (cohérent pattern data déclaratif écosystème).

## Actions broadcastées

| Action | Event broadcastée |
|---|---|
| `notify_dashboard` | `coord.notify.dashboard` |
| `escalate_human` | `coord.escalate.human` |
| autres | `coord.action.<action>` |

Les events sont broadcastés via `Fleet.EventRouter.Bus` (ch11 PROMOTED),
consommés par `fleet_api` (ch15) pour push dashboard live.

## Tests

```bash
mix test apps/fleet_coord
# 24 tests, 0 failures
```

## Dépendances

* `fleet_event_router` (ch11 PROMOTED) — Bus PubSub broadcast actions
* `:yaml_elixir`

## Frontière vendor

N0 (vendor-agnostic, pas d'inférence dans ce module — policies
déclaratives pures ; le jugement LLM des gates est côté `fleet_pipeline`
→ gatekeeper, R06).
