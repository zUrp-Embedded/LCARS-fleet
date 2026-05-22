# fleet_starfleet (chantier 13)

**Date** : 2026-05-10
**Dernière révision** : 2026-05-22
**Statut** : impl att-1 — qualifier en attente
**Référencé par** : `04_design-notes/fleet_starfleet.md`, `STATUS-CHANTIERS.md`

Module système-side consommateur des outputs des pods d'arbitrage
(gatekeeper + autres rôles décisionnels) côté core LCARS Ring 2.
Source : `04_design-notes/fleet_starfleet.md` (Régime 1, profil
**CONFORMANCE**, PoC-π3 PROVEN + PoC-10).

**Pas de pod, pas d'inférence dans ce module** — validation, parsing,
audit, escalade Cat 5 seulement.

## Sous-modules

| Module | Rôle |
|---|---|
| `Fleet.Starfleet.Decision` | struct sortie validate `{decision, reason, details, chain}` |
| `Fleet.Starfleet.Gatekeeper` | pure functions validation JSON décision (PoC-π3 figé) + schema strict `priv/schema/decision-v1.json` `ex_json_schema` au load fail-fast + cache schema `:persistent_term` |
| `Fleet.Starfleet.DriftMonitor` | GenServer subscribe `fleet.events`, 4 handlers (`pod_drift`, `pipeline.failed`, `oauth.refresh.failed`, `audit.verdict`) |
| `Fleet.Starfleet.Cat5Escalator` | pure functions `escalate/2` → log `AuditLog` + broadcast `audit.cat5.<source>` + délégation `CoordBackend` ch14 |
| `Fleet.Starfleet.AuditLog` | wrapper `File.write/3` non-bang fail-safe sur `/var/log/fleet-starfleet.jsonl` (root:adm 640) |
| `Fleet.Starfleet.CoordBackend` | seam wrap `Fleet.Coord` ch14 (default `NotWiredYet` cohérent canon §0 #1) |

## Public API

```elixir
{:ok, %Fleet.Starfleet.Decision{decision: "halt", reason: "r", details: %{}, chain: []}} =
  Fleet.Starfleet.Gatekeeper.validate(~s|{"decision":"halt","reason":"r","details":{}}|)

:ok = Fleet.Starfleet.Cat5Escalator.escalate(:pod_drift, %{"pod_id" => "p1", "drift_count" => 3})

:ok = Fleet.Starfleet.AuditLog.write(%{"source" => "test", "action" => "boot"})
```

## Schema décision (PoC-π3 figé)

```json
{
  "decision": "allow|halt|escalate|retry",
  "reason": "string non-vide",
  "details": {},
  "chain": ["string", ...]
}
```

`reason`, `decision`, `details` requis. `chain` optionnel (default `[]`).

## Events handlés (DriftMonitor)

| event_type | trigger Cat 5 |
|---|---|
| `pod_drift` | si `drift_count >= 3` |
| `pipeline.failed` | inconditionnel |
| `oauth.refresh.failed` | inconditionnel |
| `audit.verdict` | `Gatekeeper.validate` puis `CoordBackend.handle_decision` |

## Atom registration

Les events `audit.cat5.{pod_drift,pipeline_failed,oauth_refresh_failed}` +
`audit.verdict` sont pré-enregistrés compile-time via l'attribut
`@starfleet_event_atoms` de `Fleet.Starfleet.Application`. Cohérent
ch11 M1 atom-leak DoS mitigation.

## Schema cache `:persistent_term`

Schema `decision-v1.json` chargé une fois au boot via
`Fleet.Starfleet.Gatekeeper.init_schema!/0` (appelé par
`Application.start/2`) puis persisté sous la clé
`{Fleet.Starfleet.Gatekeeper, :decision_schema}`. Pattern cohérent
ch9 ETS read-only / ch11 schema cache.

## Tests

```bash
mix test apps/fleet_starfleet
# 1 doctest + 22 tests, 0 failures
```

## Dépendances

* `fleet_event_router` (ch11 PROMOTED) — Bus PubSub events
* `fleet_coord` (ch14 deferred) — derrière `CoordBackend.NotWiredYet`
* `:jason`, `:ex_json_schema`

## Frontière vendor

N0 (vendor-agnostic, pas d'inférence ni d'appel SDK direct).
