# fleet_coord (chantier 14)

**Date** : 2026-05-10
**Dernière révision** : 2026-07-05 (D2 resync contrat : `Application` en table, noms d'events émis réels, section Configuration, deps complètes, forme test canonique ; C4 — passe d'émission extraite en `Fleet.Coord.Emitter` (construction + broadcast de l'event canon), `Policies` = table seule ; B-R2 dédup chargé-caché : schema coord-policies résolu UNE fois via `Fleet.SchemaCache` — avant : re-read+resolve à CHAQUE `validate_against_schema!` — et get-or-raise de la table via `SchemaCache.fetch!/2` ; 2026-07-04 : R06 — retrait SoftGate/Hook/HookSpawner : gates LLM consolidées sur le gatekeeper côté pipeline ; coord = policies déclaratives pures)
**Statut** : impl att-1 — qualifier en attente
**Référencé par** : `04_design-notes/fleet_coord.md`, `STATUS-CHANTIERS.md`

Module Elixir système-side : table de routage déclarative
`{verdict, reason} → {action, escalation_path}` LCARS v2 Ring 2
orchestration. Source : `04_design-notes/fleet_coord.md`
(Régime 1, profil **CONFORMANCE**, PoC-π3 PROVEN).

**Aucune logique de raisonnement LLM** : `coord` = policies déclaratives
pures (méta-axiome architecture-cible §L441). Le jugement LLM des gates
pipeline est **consolidé sur le gatekeeper** (juge unique), spawné côté
`fleet_workflow` (R06) — `coord` ne porte plus de soft gate / hook.

## Sous-modules

| Module | Rôle |
|---|---|
| `Fleet.Coord` | delegator API publique (`handle_decision/2` / `handle_escalation/3`) |
| `Fleet.Coord.Application` | supervisor à children `[]` (tree minimal, cohérence umbrella OTP). Au boot : `Policies.init_policies!/0` **fail-loud** (YAML absent/malformé/schema-invalide → le boot crash, jamais une table vide « verte »). Aucun pré-enregistrement d'atomes : les events émis sont internés au compile-time par les littéraux de `emitter.ex` |
| `Fleet.Coord.Emitter` | passe d'ÉMISSION (extraite C4) : traduit un match de policy en `%Fleet.Event{source: :coord}` canon et le broadcaste — `notify_dashboard` → `coord.notification_routed`, `escalate_human` → `coord.escalation_triggered`, autre action string → `coord.action_dispatched` (extensible sans recompile). Best-effort via `Bus.safe_emit/4` (UnregisteredError silencieux au boot order, event malformé loggé ERROR puis neutralisé) ; `correlation_id` propagé sur chaque broadcast |
| `Fleet.Coord.Policies` | pure functions table mapping `{verdict, reason} → {action, escalation_path}` lookup `:persistent_term` cache boot-loaded `priv/config/coord-policies.yaml` ; un match est passé à `Emitter.dispatch_action/4` (émission déléguée). **`init_policies!/0` VALIDE le YAML parsé contre `priv/schema/coord-policies-v1.json` (ExJsonSchema) au boot** — un coord-policies map-mais-structurellement-invalide (mapping sans `action`, `escalation_path` non-array, clé hors pattern…) FAIL-LOUD comme un fichier absent/illisible (avant : seul « est une map » était vérifié, la validation schema ne tournait qu'en test). Structural-only : résolvabilité des handlers/cibles vérifiée au runtime, pas au schema. Schema `coord-policies-v1.json` résolu UNE fois via `Fleet.SchemaCache` (autorité Ring 0 — avant B-R2 : re-read à chaque appel), table policies lue via `SchemaCache.fetch!/2` |

> **Retiré (R06)** : `Fleet.Coord.SoftGate` / `Fleet.Coord.Hook` /
> `Fleet.Coord.HookSpawner` (+ `NotWiredYet`). Le soft gate et le terminal
> non-tranchable sont jugés par le **gatekeeper** (`Fleet.Workflow.Gates`
> retourne `{:dispatch_gatekeeper, info}` ; le rail forge-driven
> `Fleet.Pilot.StepRunConsumer` enqueue le brief d'éval et collecte la décision
> — le moteur RAM `Executor` est retiré).

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

(Plus de `:fleet_workflow, :coord_backend` — supprimé en R06 : le pipeline
ne délègue plus la gate LLM à coord.)

## Format `priv/config/coord-policies.yaml`

```yaml
mappings:
  "halt.gatekeeper.refuse":
    action: notify_dashboard
    escalation_path: [dashboard, issue_comment]
  "escalate.pod_drift":
    action: escalate_human
    escalation_path: [dashboard, starfleet_alert]
```

Mapping key `"<verdict>.<reason>"` ou `"escalate.<source>"`. Extensible
PR sans recompile (cohérent pattern data déclaratif écosystème).

## Actions broadcastées

| Action | Event broadcasté (`Fleet.Coord.Emitter`) |
|---|---|
| `notify_dashboard` | `coord.notification_routed` (target `"dashboard"`) |
| `escalate_human` | `coord.escalation_triggered` (target `"operator"`) |
| autre action string | `coord.action_dispatched` (action en payload — extensible sans recompile) |

Les events sont broadcastés via `Fleet.EventRouter.Bus` (`safe_emit/4`,
best-effort), consommés par `fleet_api` (ch15) pour push dashboard live.

## Configuration

| Knob | Default | Rôle |
|---|---|---|
| `:fleet_coord, :policies_path` | `priv/config/coord-policies.yaml` de l'app | chemin du YAML policies, chargé fail-loud au boot par `init_policies!/0`. Posé par `runtime.exs` depuis `LCARS_COORD_POLICIES_PATH` si présente |

Le wiring backend (`config :fleet_starfleet, :coord_backend, Fleet.Coord`)
est posé par `runtime.exs` — clé de `fleet_starfleet`, pas de cette app.

## Tests

```bash
( cd apps/fleet_coord && mix test )   # PAS `mix test apps/…` depuis la racine (0 test collecté = faux vert)
```

## Dépendances

(déclarées dans `mix.exs`)

* `fleet_event_router` (ch11 PROMOTED) — Bus PubSub broadcast actions
* `:yaml_elixir`
* `:ex_json_schema`, `:jason` — validation du YAML policies contre `priv/schema/coord-policies-v1.json` au boot (deps directes, usage en lib)

## Frontière vendor

N0 (vendor-agnostic, pas d'inférence dans ce module — policies
déclaratives pures ; le jugement LLM des gates est côté `fleet_workflow`
→ gatekeeper, R06).
