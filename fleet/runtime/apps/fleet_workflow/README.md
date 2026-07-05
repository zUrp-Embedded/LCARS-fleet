# fleet_workflow (chantier 12)

**Date** : 2026-05-09
**Dernière révision** : 2026-07-05 (D2 resync contrat : Ring 2 réel, `Application` en table, verdict `{:human_approval, _}` distinct de `{:fail}`, section Configuration, forme test canonique ; C4 — placement + validation-sécurité du payload extraits en `Fleet.Workflow.PayloadGuard`, `Deliverable` = orchestration 3-temps seule ; B-R2 dédup chargé-caché : cache schema du `Loader` délégué à `Fleet.SchemaCache`, autorité Ring 0 ; 2026-07-01 : push borné via Fleet.Credentials.Shell + scan evil-merge `--diff-merges=first-parent` — remédiation Lot C ; doc-rot F-017 antérieur : purge des modules retirés au ②.3/BL-050 — `Executor`, `StageRunner`, `StageSpawner`, `Toposort`, `start_pipeline`, le `Registry` per-run et `count_running/0` ne sont plus documentés)
**Statut** : lib-only (salvage post-moteur-RAM) — qualifier en attente
**Référencé par** : `04_design-notes/fleet_workflow.md`, `STATUS-CHANTIERS.md`

Lib **workflow_map / gate / delivery** (quasi-pure) consommée par le rail forge-state-machine
et les apps du core — Ring 2 (coordination + policy, renumérotation 2026-07-04).

Source : `04_design-notes/fleet_workflow.md`.

## État de l'app (②.3 / BL-050, 2026-06-16)

Le **moteur RAM** (`Fleet.Workflow.Executor` et toute sa pile :
`Registry`/`PodRegistry`/`ExecutorSupervisor`, `StageRunner`, `StageSpawner`,
`Toposort`, `WorkspaceProvisioner`) a été **RETIRÉ**. Il ne reste **aucun process
à superviser** : `Fleet.Workflow.Application.start/2` démarre un `Supervisor`
**vide** (conservé transitoirement — l'app est destinée à devenir une lib-only,
sortie de la clé `mod:` de `mix.exs`, au Bloc C).

`fleet_workflow` n'expose donc **plus** de `start_pipeline/2-3`, de lookup
`Registry` per-pipeline-run, ni de `count_running/0`. Ce qui reste est un jeu de
**fonctions pures (et un seam de boot gatekeeper)** : parsing/normalisation de
workflow_map YAML, évaluation de gates, et publication de livrable.

## Sous-modules

| Module | Rôle (vérifié dans le code) |
|---|---|
| `Fleet.Workflow.Application` | supervisor **vide** (aucun process à superviser — conservé transitoirement, cible lib-only). Pré-enregistre au compile-time les atomes events `workflow_map.*` (cf. § Atom registration) et les expose via `workflow_map_event_atoms/0` |
| `Fleet.Workflow.Loader` | `load!/2` : parse YAML `pipelines/<name>.yaml` via `yaml_elixir`, valide le schema strict (`workflow-map-v2.5.json`, enveloppe `kind/metadata/spec`), puis **normalise** vers la forme interne unique `%{"name", "steps"}`, puis valide le **graphe** via `GraphValidator` (raise au load). Schema résolu caché via `Fleet.SchemaCache` (autorité Ring 0, `:persistent_term`, keyé par path résolu). Fonctions pures ; `opts` (`:workflow_maps_root`, `:schema_path`) pour tests async |
| `Fleet.Workflow.GraphValidator` | `validate/1` : linter de GRAPHE **pur** (`steps` → `:ok \| {:error, {kind, detail}}`) sur les invariants inter-steps que le JSON Schema ne peut pas exprimer (il valide chaque step isolément). Vérifie : `:phantom_edge` (chaque `needs` réfère un step déclaré — anti-arête-fantôme/typo silencieux), `:no_root`/`:multiple_roots` (exactement 1 racine `needs: []`), `:unreachable` (tout step atteignable depuis la racine), `:cycle` (DAG, tri topologique de Kahn — couvre aussi « aucun terminal atteignable », condition équivalente pour ce runtime séquentiel), `:fan_out` (aucun step à ≥2 successeurs ; runtime séquentiel, aligné `WorkflowMapNav`). `describe/1` rend le message lisible par invariant (composé par le Loader dans son raise). Autonome — ne dépend PAS de `WorkflowMapNav` (la dépendance inverse fleet_workflow→fleet_pilot est interdite) |
| `Fleet.Workflow.Gate` | `@callback evaluate/3` — behaviour générique d'évaluation de gate, vendor-extensible compile-time |
| `Fleet.Workflow.Gates` | implémentation du behaviour `Gate`. `evaluate/3` dispatche par type (`:hard \| :soft \| :terminal \| nil`). **Pur** : seul le `soft` retourne `{:dispatch_gatekeeper, info}` (décision d'escalade), il ne spawn rien. `rules` (hard ET terminal) = liste de prédicats string délégués à `Gates.Predicate`. Somme fermée : toute forme inconnue/malformée → `{:fail}` fail-closed (l'éval est TOTALE) |
| `Fleet.Workflow.Gates.Predicate` | `eval?/2` — évaluateur **pur** des rule-strings v2.5 (`"all_tests_pass"`, `"severity_max != critical"`, conjonction `AND`) contre les `outputs` auto-rapportés. Grammaire bornée au corpus canon ; **fail-closed** (fait absent / type incompatible → faux) |
| `Fleet.Workflow.GateBrief` | `build/1` — fonction pure qui construit le **brief markdown** (texte du brief) que le gatekeeper pull via MCP `get_work_item` : contexte + livrable à juger + question + options canon (consommées depuis `GateDecision`) + contrat de sortie `gate-decision-v1.json` |
| `Fleet.Workflow.GateDecision` | `decisions/0` — **AUTORITÉ UNIQUE** du vocabulaire des décisions gatekeeper (`continue`/`abandon`/`redirect`/`escalate_user`/`halt_wait_input`). `GateBrief` (énoncé) et `Fleet.Pilot.StepRunConsumer` (validation fail-closed) consomment cette liste → l'énoncé et la validation ne peuvent plus diverger. Le contrat WIRE `gate-decision-v1.json` reste le miroir JSON (égalité schema ⇔ module verrouillée par test) |
| `Fleet.Workflow.Gatekeeper` | seam de **boot + registration** du gatekeeper permanent (juge unique, pod Type 3, `lifetime_scope: forever`, cap-profile `gatekeeper.yaml`). `ensure_booted/1` (idempotent, config-gated par `:gatekeeper_autoboot`), `pod_id/0` (lecture `:persistent_term` ou override config `:gatekeeper_pod_id`), `reboot/1` (reap du holder survivant + dé-registre + re-boot frais — sert de `respawn_fun` au re-roll `Fleet.Pilot.WakeRecovery` quand le gatekeeper est injoignable, `ensure_booted` seul no-op sur un pod registré-mais-cassé). Seul module non-pur survivant : il appelle `Fleet.CapProfile.load/1` + `Fleet.Spawner.spawn_pod/3` (injectables en test) |
| `Fleet.Workflow.Deliverable` | publication unifiée du livrable d'un pod (modèle O5). **Un seul** module, deux modes choisis par `spec.deliverable_mode` au catalogue : `:payload` (le système écrit les fichiers via `PayloadGuard.apply_files/2` + `Git.commit`) / `:git_native` (l'agent a déjà commité — présence d'un commit vérifiée). Trois temps : CONTENU → gate I-CBC partagée (`DeliverableGate.verify`) → push borné (`Git.push`). Frontière pod↔système : le pod est forge-aveugle, le système choisit la branche cible et pousse |
| `Fleet.Workflow.PayloadGuard` | placement + **validation-sécurité fail-closed** d'un payload de fichiers NON FIABLE dans un workspace (filtre autonome, extrait C4 de `Deliverable`). `apply_files/2` : 2 passes (TOUT validé avant la moindre écriture). Refuse le path-traversal (`{:path_traversal, …}`), le symlink-in-chain (`{:symlink_escape, …}` — `Path.expand` est lexical, `File.write` suivrait le lien hors workspace), **tout composant `.git`** (`{:dotgit_path, …}` — interdit de réécrire `.git/config`/`.git/hooks`), et **tout `.gitattributes` armant `filter=`/`diff=`** (`{:dangerous_gitattributes, …}`). Ferme le vecteur RCE par filtre `clean` : sans cette garde, le `git add` système-side qui suit exécuterait la commande du filtre côté monde (hors bwrap) — le `.gitattributes` IN-TREE n'est PAS désactivable par `-c` (le refus de contenu est le SEUL verrou de ce vecteur). Un `.gitattributes` bénin (sans `filter=`/`diff=`) reste autorisé. Source UNIQUE du placement de livrable |
| `Fleet.Workflow.DeliverableGate` | gate **I-CBC mécanique** du livrable (modèle O5), vérifiée côté monde (Elixir). `verify/4` enchaîne, dans l'ordre : `check_base_ancestor` (F-03, base SHA hors-pod ancêtre de HEAD), `check_identity` (F-01, author+committer ∈ identités autorisées), trailer co-author optionnel, `scan_secrets` (F-02, aucun secret dans le diff `base..HEAD`). Le scan secret + le scan de noms de fichiers utilisent `git log -p --diff-merges=first-parent` : sans cette option, `git log -p` n'émet AUCUN diff pour un commit de MERGE → un secret ou un fichier interdit présent UNIQUEMENT dans l'arbre RÉSOLU d'un evil-merge (absent des deux parents, base toujours ancêtre, auteur légitime) passerait le scan ; l'option fait scanner le delta du merge vs son premier parent (ce que le merge introduit dans la mainline). Ne croit aucune assertion du pod (lit son `.git` read-only) ; premier check raté → `{:error, reason}`, pas de push |
| `Fleet.Workflow.GitRef` | `valid?/1` — **AUTORITÉ UNIQUE** de validation d'un nom de branche/ref git (check-ref-format grosso-modo : tête alphanumérique + `[A-Za-z0-9._/-]`, rejette `..`/espace/leading-`-`). `Git.check_branch` et `Deliverable.check_ref` délèguent ici (chacun gardant sa forme d'erreur typée) — la regex ne vit plus en double |
| `Fleet.Workflow.Git` | mécanisme système-side de publication git pur (data → action) : `add → commit → [push]`. Identité native git (`GIT_AUTHOR_*` ≠ `GIT_COMMITTER_*`, D-04). Fail-closed : `--force` / `--no-verify` **jamais** composés ; neutralisation config (hooks/fsmonitor/sshCommand/diff.external/attributesFile global) sur **`git add`, `git commit` ET `git push`** via la SOURCE UNIQUE `Fleet.Credentials.Shell.git_safe_config_args/0` (le `git add` système-side exécute le filtre `clean` d'un `.gitattributes` du pod = RCE hors-sandbox ; le set ferme les vecteurs config globale/système + hooks, le vecteur in-tree se fermant côté CONTENU dans `Deliverable`). Le `push` réseau est borné par construction via `Fleet.Credentials.Shell` (process-group dédié, tué entier à la deadline mur), remplaçant le patron `Task.async`+`brutal_kill` qui ne tuait que le Task BEAM en laissant fuir le process git porteur du token forge |

## Format pipeline YAML

```yaml
kind: WorkflowMap
metadata:
  name: intensity-low
spec:
  steps:
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
        - report_id
      gate:
        type: hard
        rules:
          - all_tests_pass
```

Enveloppe unique **v2.5** (`kind/metadata/spec.steps`), déballée au load par
`Loader` vers la forme interne `%{"name", "steps"}`. Champs step : `role`
(string, required), `profile` (string, required), `needs` (array string),
`condition` (string), `inputs` (array de descriptifs string, ex. `ticket.body`),
`outputs` (array string), `gate`, `coordHook` (string, deferred ch14). Le
**contenu** de gate (`gate.rules` = liste de prédicats string) est un axe
orthogonal à l'enveloppe — cf. § Types de gates.

## Types de gates

`Fleet.Workflow.Gates.evaluate/3` retourne `:pass`, `{:fail, reason}`,
`{:human_approval, reason}`, ou `{:dispatch_gatekeeper, info}` (PUR — aucun spawn) :

* **`hard`** — pas de bypass. `rules` = liste de prédicats string (tous vrais
  via `Gates.Predicate.eval?/2`). `:pass` / `{:fail, reason}`.
* **`soft`** — jugement LLM délégué au **gatekeeper** (juge unique de la fleet,
  pod permanent work-session). `Gates` retourne `{:dispatch_gatekeeper, %{kind: :soft}}` ;
  le consommateur (rail forge) adresse un brief d'éval au gatekeeper (MCP, via
  `Fleet.TaskQueue`, ciblé par `pod_id`) et collecte la décision. Pas de gatekeeper
  booté → fail-loud. **Seul** le `soft` dispatche au gatekeeper.
* **`terminal`** — `rules` = liste de prédicats string (tous vrais → `:pass`,
  sinon `{:fail}`). `rules` OPTIONNEL (gate `finish`). **`human_approval_required: true`
  → `{:human_approval, reason}`** : un aval HUMAIN est requis — ce n'est PAS un
  échec de gate, c'est une ESCALADE (verdict distinct de `{:fail}` pour que le rail
  `Fleet.Pilot.StepRunConsumer` route directement vers l'arch au lieu de rebondir en
  rework). Fail-closed préservé : le moteur mécanique n'auto-approuve jamais.

`Gates.evaluate/3` ne retourne **jamais** `:retry` : le retry n'est pas une
décision de gate. Le retry borné sur FAIL existe, mais il est piloté par le rail
forge-driven (`Fleet.Pilot.StepRunConsumer`, compteur de rework borné) — hors de
cette lib.

### Décision du gatekeeper (vocab canon)

Schéma `priv/schema/gate-decision-v1.json` : `decision ∈ {continue, abandon,
redirect, escalate_user, halt_wait_input}`. Le consommateur mappe `continue` →
avancer ; le reste (+ inconnu/malformé) → halt fail-closed. Distinct de
`decision-v1.json` (`allow/halt/escalate/retry`, chemin **starfleet/escalade OS**,
jamais projet). Le brief de jugement est rendu par `Fleet.Workflow.GateBrief.build/1`.

## Atom registration (legacy)

`Fleet.Workflow.Application` pré-enregistre encore au compile-time les atomes
`workflow_map.step.completed | workflow_map.completed | workflow_map.failed` via l'attribut
`@workflow_map_event_atoms` (exposé par `workflow_map_event_atoms/0`). Ces events étaient
émis par l'`Executor` retiré et **ne sont plus émis** ; ils restent pré-enregistrés
pour rester cohérents avec la mitigation atom-leak DoS de ch11 (`Bus` utilise
`String.to_existing_atom/1`). Nettoyage prévu au Bloc C.

## Configuration

Knobs réellement lus par le code (tous sous `config :fleet_workflow`) :

| Knob | Default | Rôle |
|---|---|---|
| `:workflow_maps_root` | `priv/canon/workflow_maps` de l'app | racine du catalogue pipelines YAML (`Loader.load!/2`). Posé par `runtime.exs` depuis `LCARS_WORKFLOW_MAPS_ROOT` si présente ; `opts[:workflow_maps_root]` prioritaire (tests async) |
| `:schema_path` | `priv/schema/workflow-map-v2.5.json` de l'app | schema JSON du workflow_map (`Loader`) ; `opts[:schema_path]` prioritaire |
| `:gatekeeper_autoboot` | `true` | gate de `Gatekeeper.ensure_booted/1` ; `config/test.exs` le met à `false` (hermétisme — pas de spawn gatekeeper sauf opt-in) |
| `:gatekeeper_pod_id` | — (nil) | override du `pod_id` gatekeeper, prioritaire sur le registre `:persistent_term` (tests) |
| `:git_push_timeout_ms` | `30_000` | deadline mur du `git push` borné (`Git`, via `Fleet.Credentials.Shell`) |
| `:git_local_timeout_ms` | `30_000` | deadline des commandes git locales (`Git`) |

## Tests

```bash
( cd apps/fleet_workflow && mix test )   # suite complète — PAS `mix test apps/…` depuis la racine (0 test collecté = faux vert)
```

## Dépendances

(déclarées dans `mix.exs`)

* `fleet_cap_profile` (ch1) — résolution cap-profile YAML (boot gatekeeper)
* `fleet_spawner` (ch6) — `Fleet.Spawner.spawn_pod/3` (boot gatekeeper, seam injectable)
* `fleet_credentials` — `Fleet.Credentials.ForgeIdentity` (F-01 : `allowed_emails` = l'humain du brief)
* `fleet_event_router` (ch11) — Bus PubSub (pré-enregistrement des atomes events)
* `fleet_task_queue` (run #5) — broker de briefs (adressage du gatekeeper par `pod_id`)
* `:yaml_elixir`, `:jason`, `:ex_json_schema`
