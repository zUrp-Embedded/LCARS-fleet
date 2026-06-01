# fleet_pipeline (chantier 12)

**Date** : 2026-05-09
**Dernière révision** : 2026-06-02
**Statut** : impl att-1 — qualifier en attente
**Référencé par** : `04_design-notes/fleet_pipeline.md`, `STATUS-CHANTIERS.md`

Exécuteur générique de pipelines YAML déclaratifs (Ring 2 — orchestration).
Source : `04_design-notes/fleet_pipeline.md` (Régime 1, PoC-π1
PROVEN 2026-05-09, profil **CONFORMANCE**).

## Sous-modules

| Module | Rôle |
|---|---|
| `Fleet.Pipeline.Loader` | parse YAML `pipelines/<name>.yaml` + valide schema strict `priv/schema/pipeline-v1.json` (`ex_json_schema`) au load fail-fast |
| `Fleet.Pipeline.Toposort` | tri topologique DAG des stages selon `needs` (Kahn's algorithm + cycle detection) |
| `Fleet.Pipeline.Executor` | GenServer per-pipeline-run, state machine + collect events PubSub, dispatch gates, broadcast `pipeline.{stage.completed,completed,failed}` |
| `Fleet.Pipeline.Gates` | dispatch gate par type (`:hard \| :soft \| :terminal \| nil`) |
| `Fleet.Pipeline.Gate` | behaviour `evaluate/3` extensible compile-time |
| `Fleet.Pipeline.StageRunner` | résolution inputs depuis prior outputs + spawn pod via `StageSpawner` |
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
`needs` (array string), `condition` (string), `inputs` (array
`{from_stage, key}`), `outputs` (array string), `gate`
(`{type: hard|soft|terminal, rule|rules|max_rounds}`),
`coordHook` (string, deferred ch14).

## Types de gates

* **`hard`** — règle déclarative `Fleet.Pipeline.Gates.Hard.matches?/2`
  (map subset match récursif). `:pass` / `{:fail, reason}`.
* **`soft`** — délégué `CoordBackend.invoke_soft_gate/4` (LLM one-shot
  retry N rounds, ch14 deferred).
* **`terminal`** — règles déclaratives (`required: true|false`). Toutes
  match → `:pass`. Required mismatch → `{:fail, _}`. Non-required
  mismatch → fallback gatekeeper cap-profile via `StageSpawner` +
  `:retry`.

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
