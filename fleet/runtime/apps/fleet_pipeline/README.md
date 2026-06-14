# fleet_pipeline (chantier 12)

**Date** : 2026-05-09
**Dernière révision** : 2026-06-14 (R4 D5 — `count_running/0` + gate `:quiescing` sur `start_pipeline/3` (drain shutdown) ; R4 — gate inférentielle = mandat MCP au gatekeeper permanent (Type 3), vocab canon, `Fleet.Pipeline.Gatekeeper` boot/registration ; R3 — Loader-normalizer v2.5/U1, prédicats Gates)
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
| `Fleet.Pipeline.Executor` | GenServer per-pipeline-run, state machine + collect events PubSub, dispatch gates, broadcast `pipeline.{stage.completed,completed,failed}` ; gate inférentielle → mandat MCP au gatekeeper, `:awaiting_gate` (corrélation `correlation_id`) |
| `Fleet.Pipeline.Gates` | dispatch gate par type (`:hard \| :soft \| :terminal \| nil`) ; rules v1 map OU v2.5 string ; PUR (`{:dispatch_gatekeeper, info}` pour l'inférentiel, aucun spawn) |
| `Fleet.Pipeline.Gates.Predicate` | évaluateur pur des rule-strings v2.5 (`"all_tests_pass"`, `"severity_max != critical"`, conjonction `AND`) contre les outputs, fail-closed |
| `Fleet.Pipeline.Gatekeeper` | boot + registration du **gatekeeper permanent** (Type 3, `forever`, work-session) à l'activation pipeline ; `pod_id/0` (registry `:persistent_term` / override config) lu par l'Executor |
| `Fleet.Pipeline.GateBrief` | construit le **brief d'éval** (texte du mandat MCP) que le gatekeeper pull via `get_task` : contexte + livrable à juger + question + options canon + contrat `gate-decision-v1.json` (pur) |
| `Fleet.Pipeline.Gate` | behaviour `evaluate/3` extensible compile-time |
| `Fleet.Pipeline.StageRunner` | résolution inputs (v1 `{from_stage,key}` depuis prior outputs OU v2.5 descriptifs string) + spawn pod via `StageSpawner` |
| `Fleet.Pipeline.StageSpawner` | seam wrap `Fleet.Spawner.spawn_pod/3` (ch6 PROMOTED) |

## Public API

```elixir
{:ok, pipeline_id} =
  Fleet.Pipeline.start_pipeline("intensity-low", %{ticket_id: "fleet/lcars#42"})
# {:error, :quiescing} si un drain de shutdown est en cours (chokepoint
# top-level — Fleet.Shutdown.Quiesce ; le travail interne d'un pipeline en
# vol n'est PAS gaté)

# Lookup Executor pid via Registry
[{pid, _}] = Registry.lookup(Fleet.Pipeline.Registry, pipeline_id)

# Nombre de pipelines en cours (consommé par l'agrégateur d'in-flight du drain)
n = Fleet.Pipeline.count_running()
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
* **`soft`** — jugement LLM délégué au **gatekeeper** (juge unique, pod
  permanent work-session). `Gates` retourne `{:dispatch_gatekeeper, info}` ;
  l'Executor **enqueue un mandat d'éval** au gatekeeper (MCP, via TaskQueue,
  adressé par `gatekeeper_pod_id`) et attend `task_queue.task_completed`
  (corrélation `correlation_id`). **Pas de retry/rounds** (retry n'est pas une
  décision de gate). Pas de gatekeeper booté → fail-loud.
* **`terminal`** — v1 `rules` maps (`required: true|false` ; toutes match
  → `:pass` ; required mismatch → `{:fail}` ; non-required mismatch →
  **même dispatch gatekeeper** que `soft`). v2.5 `rules` strings → tous vrais →
  `:pass`. `rules` OPTIONNEL (gate `finish`). **`human_approval_required: true`
  → HALT fail-closed `{:fail}`** (le moteur mécanique n'auto-approuve jamais).

### F150 — retry borné système-side sur FAIL hard-gate

Un `{:fail}` hard-gate (livrable déterministe rejeté, ex. tests rouges) ne tue
**plus** le pipeline au 1er coup. Le **système** (l'Executor — JAMAIS le pod : un
agent s'acharnerait à l'infini) tient un compteur per-stage (`retry_counts` dans
son state) et **RETRY le stage** (re-dispatch d'un pod frais via `do_run_stage`,
la `reason` du FAIL injectée dans le `mandate_context` → l'eng refait en sachant
quoi corriger) tant que `n < stage_max_retries` (config `:fleet_pipeline,
:stage_max_retries`, défaut **3**).

Au seuil, le système **n'abandonne ni ne loope** : il **INTERCEPTE** et confie au
gatekeeper un mandat de **DIAGNOSTIC** (`dispatch_gatekeeper_diagnosis`, distinct
d'une éval de gate) — *« le mandat est-il mal construit (→ `redirect` renvoi arch)
ou un autre problème (→ `escalate_user`/`abandon`) ? »*. La décision revient par le
**même chemin** que les gates (`handle_gate_decision`, vocab `gate-decision-v1`).
La borne EST le garde-fou contre le re-spawn-en-boucle que `Gates` craignait. Le
mécanisme est **générique** (role-agnostic) même si seul l'eng le déclenche
aujourd'hui.

**Séparation fonction→owner (invariant doctrinal — généalogie GATE-D1 / overload-gatekeeper).**
F150 *exemplifie* la redistribution : la **boucle** (compte/retry/route) vit dans la
**machine** (Executor = orchestration) ; le **gatekeeper** n'entre qu'au seuil, en
exception, pour **juger** (verdict du vocab fermé) ; **arch** reçoit le re-cadrage
(`redirect`). Un rejet **soft-gate** (jugement gatekeeper) NE pilote PAS la boucle
(il garde sa sémantique halt) — sinon on redonne au gatekeeper du contrôle
d'orchestration = la 6ᵉ responsabilité qui a déclenché les ~12 itérations de girouette.
**Ce n'est pas un fork ouvert : c'est verrouillé par doctrine.** (cf. commentaire
load-bearing dans `executor.ex` ; BACKLOG §10 « gatekeeper redistribué ».)

### Décision du gatekeeper (vocab canon)

Schéma `priv/schema/gate-decision-v1.json` : `decision ∈ {continue, abandon,
redirect, escalate_user, halt_wait_input}`. L'Executor mappe `continue` → stage
suivant ; le reste (+ inconnu/malformé) → `pipeline.failed` (halt, fail-closed).
Distinct de `decision-v1.json` (`allow/halt/escalate/retry`, chemin
**starfleet/escalade OS**, jamais projet). Le gatekeeper est un pod permanent
booté à l'activation pipeline (`Fleet.Pipeline.Gatekeeper`, Type 3, `forever`).

## Atom registration

Les events `pipeline.stage.completed | pipeline.completed |
pipeline.failed` sont pré-enregistrés au compile-time via
l'attribut `@pipeline_event_atoms` de `Fleet.Pipeline.Application`.
Cohérent ch11 M1 atom-leak DoS mitigation (`Bus` côté ch11 utilise
`String.to_existing_atom/1`).

## Tests

```bash
mix test apps/fleet_pipeline   # suite complète (cf. sortie ; r1_seam exclus par défaut)
mix test apps/fleet_pipeline --only r1_seam   # filet anti-régression coutures
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
