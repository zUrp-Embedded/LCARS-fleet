# fleet_coord (chantier 14)

**Date** : 2026-05-10
**Dernière révision** : 2026-05-10
**Statut** : impl att-1 — qualifier en attente
**Référencé par** : `design-notes/promoted/fleet_coord.md`, `STATUS-CHANTIERS.md`

Module Elixir système-side : table de routage déclarative
`{verdict, reason} → {action, escalation_path}` LCARS v2 Ring 2
orchestration. Source : `design-notes/promoted/fleet_coord.md`
(Régime 1, profil **CONFORMANCE**, PoC-π3 PROVEN).

**Aucune logique de raisonnement LLM dans Policies** (méta-axiome
architecture-cible §L441). Soft gate + Hook délèguent LLM via
spawn pod jetable cap-profile dédié.

## Sous-modules

| Module | Rôle |
|---|---|
| `Fleet.Coord` | delegator API publique |
| `Fleet.Coord.Policies` | pure functions table mapping `{verdict, reason} → {action, escalation_path}` lookup `:persistent_term` cache boot-loaded `priv/config/coord-policies.yaml` + broadcast events `coord.action.*` / `coord.notify.dashboard` / `coord.escalate.human` |
| `Fleet.Coord.SoftGate` | pure functions `invoke_soft_gate/4` spawn pod LLM one-shot via `SpawnerBackend` retry max N rounds (PoC-π2 fire-mode) |
| `Fleet.Coord.Hook` | pure functions `invoke_hook/2` spawn pod fire-mode coordHook (PoC-π2) — MVP `:before_next` |
| `Fleet.Coord.SpawnerBackend` | seam wrap `Fleet.Spawner.spawn_pod/3` (default `:not_wired_yet`, ch7 EXTRACT JSON deferred) |

## Public API

```elixir
# ch13 callers (handle_decision + handle_escalation)
:ok = Fleet.Coord.handle_decision(%Fleet.Starfleet.Decision{
  decision: "halt", reason: "gatekeeper.refuse", details: %{}, chain: []
})

:ok = Fleet.Coord.handle_escalation(:pod_drift, %{"pod_id" => "p1", "drift_count" => 3})

# ch12 callers (invoke_soft_gate + invoke_hook)
:pass | {:fail, reason} = Fleet.Coord.invoke_soft_gate(stage, outputs, ctx, max_rounds: 3)

:continue | {:halt, reason} = Fleet.Coord.invoke_hook(:before_next, ctx)
```

## Wiring backends ch12 + ch13

`Fleet.Coord` satisfait les behaviours `Fleet.Pipeline.CoordBackend`
(`invoke_soft_gate/4` + `invoke_hook/2`) et `Fleet.Starfleet.CoordBackend`
(`handle_decision/1` + `handle_escalation/2`). Configuration runtime :

```elixir
config :fleet_pipeline, :coord_backend, Fleet.Coord
config :fleet_starfleet, :coord_backend, Fleet.Coord
```

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
* `fleet_spawner` (ch6 PROMOTED) — derrière `SpawnerBackend.Default`
  (note : default actuel `:not_wired_yet` — wiring ch7 EXTRACT JSON
  pour récupérer outputs structurés du pod jetable)
* `:yaml_elixir`

## Frontière vendor

N0 (vendor-agnostic, pas d'inférence dans ce module — soft gate +
hook délèguent LLM via spawn pod cap-profile dédié, frontière N1
isolée chantier 5 `claude_launch.sh`).
