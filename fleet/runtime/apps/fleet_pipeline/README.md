# fleet_pipeline (chantier 12)

**Date** : 2026-05-09
**Dernière révision** : 2026-06-05 (R3 — Loader-normalizer v2.5/U1, inputs v2.5, évaluateur de prédicats Gates)
**Statut** : impl att-1 — qualifier en attente
**Référencé par** : `04_design-notes/fleet_pipeline.md`, `STATUS-CHANTIERS.md`

Exécuteur générique de pipelines YAML déclaratifs (Ring 2 — orchestration).
Source : `04_design-notes/fleet_pipeline.md` (Régime 1, PoC-π1
PROVEN 2026-05-09, profil **CONFORMANCE**).

## Sous-modules

| Module | Rôle |
|---|---|
| `Fleet.Pipeline.Loader` | parse YAML `pipelines/<name>.yaml`, valide schema strict (`pipeline-v1.json` flat OU `pipeline-v2.5.json` enveloppe, détecté par présence `spec`) puis **normalise** (U1) vers la forme interne unique `%{"name", "stages"}` — en aval tout est format-agnostique |
| `Fleet.Pipeline.Toposort` | tri topologique DAG des stages selon `needs` (Kahn's algorithm + cycle detection) |
| `Fleet.Pipeline.Executor` | GenServer per-pipeline-run, state machine + collect events PubSub, dispatch gates, broadcast `pipeline.{stage.completed,completed,failed}` |
| `Fleet.Pipeline.Gates` | dispatch gate par type (`:hard \| :soft \| :terminal \| nil`) ; rules v1 map OU v2.5 string |
| `Fleet.Pipeline.Gates.Predicate` | évaluateur pur des rule-strings v2.5 (`"all_tests_pass"`, `"severity_max != critical"`, conjonction `AND`) contre les outputs, fail-closed |
| `Fleet.Pipeline.Gate` | behaviour `evaluate/3` extensible compile-time |
| `Fleet.Pipeline.StageRunner` | résolution inputs (v1 `{from_stage,key}` depuis prior outputs OU v2.5 descriptifs string) + spawn pod via `StageSpawner` |
| `Fleet.Pipeline.StageSpawner` | seam wrap `Fleet.Spawner.spawn_pod/3` (ch6 PROMOTED) |
| `Fleet.Pipeline.CoordBackend` | seam wrap `Fleet.Coord` (ch14 deferred — default `NotWiredYet`) |

## Public API

```elixir
{:ok, pipeline_id} =
  Fleet.Pipeline.start_pipeline("intensity-low", %{ticket_id: "fleet/lcars#42"})

# Lookup Executor pid via Registry
[{pid, _}] = Registry.lookup(Fleet.Pipeline.Registry, pipeline_id)
```

## Format pipeline YAML

```yaml
name: intensity-low
version: 1
stages:
  scout:
    role: scout
    profile: empty
    outputs:
      - report_id
  archive:
    role: archiviste
    profile: empty
    needs: [scout]
    inputs:
      - from_stage: scout
        key: report_id
    gate:
      type: hard
      rule:
        status: ok
```

Champs stage : `role` (string, required), `profile` (string, required),
`needs` (array string), `condition` (string), `inputs`, `outputs`
(array string), `gate`, `coordHook` (string, deferred ch14). Deux
formats acceptés (détectés au load, normalisés ensuite) : **flat v1**
(`name/version/stages` top-level) et **enveloppe v2.5**
(`kind/metadata/spec.stages`). En v2.5, `inputs` = array de descriptifs
string (`ticket.body`) et `gate.rules` = array de prédicats string ; en
v1, `inputs` = array `{from_stage, key}` et `gate.rule(s)` = maps.

## Types de gates

* **`hard`** — pas de bypass. v1 `rule` map (`Gates.Hard.matches?/2`,
  subset match) OU v2.5 `rules` strings (tous les prédicats vrais via
  `Gates.Predicate`). `:pass` / `{:fail, reason}`.
* **`soft`** — délégué `CoordBackend.invoke_soft_gate/4` (LLM one-shot
  retry N rounds, ch14 deferred).
* **`terminal`** — v1 `rules` maps (`required: true|false` ; toutes match
  → `:pass` ; required mismatch → `{:fail}` ; non-required mismatch →
  fallback gatekeeper + `:retry`). v2.5 `rules` strings → tous vrais →
  `:pass`. `rules` est OPTIONNEL (gate `finish`). **`human_approval_required:
  true` → HALT fail-closed `{:fail}`** : le moteur mécanique n'auto-approuve
  jamais un gate humain (human-in-loop non câblé). L'orchestration severity
  (`fallback_invoke_gatekeeper`, `on_*_severity`) reste hors-scope.

## Atom registration

Les events `pipeline.stage.completed | pipeline.completed |
pipeline.failed` sont pré-enregistrés au compile-time via
l'attribut `@pipeline_event_atoms` de `Fleet.Pipeline.Application`.
Cohérent ch11 M1 atom-leak DoS mitigation (`Bus` côté ch11 utilise
`String.to_existing_atom/1`).

## Tests

```bash
mix test apps/fleet_pipeline
# 2 doctests + 28 tests, 0 failures
```

## Dépendances

* `fleet_cap_profile` (ch1) — résolution cap-profile YAML
* `fleet_spawner` (ch6) — spawn pod via `StageSpawner.Default`
* `fleet_task_queue` (run #5) — broker de mandats. `StageRunner` **enqueue** le mandat ciblé `pod_id`
  (`push_task_for_pod`, fail-soft : enqueue `{:error}` → kill du pod one-shot, pas de crash Executor) ;
  le pod le **pull** via MCP `get_task` ; complétion = `%Fleet.Event{task_completed}` (event-driven).
* `fleet_event_router` (ch11) — Bus PubSub events stages
* `fleet_coord` (ch14) — deferred via `CoordBackend.NotWiredYet`
* `:yaml_elixir`, `:jason`, `:ex_json_schema`
