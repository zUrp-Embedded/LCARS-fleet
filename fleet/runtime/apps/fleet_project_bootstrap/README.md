# fleet_project_bootstrap — core du pod (Ring 1)

**Date** : 2026-05-18
**Dernière révision** : 2026-06-17
**Statut** : ACTIF — chemin PROD câblé (`Phase.Clone`). Scaffold `prepare/3` partiellement mort (conformance-only).
**Dérivé de** : 04_design-notes/ring1/fleet_project_bootstrap.md + session 2026-05-17/18 (rings finalisés)

Cette app fait partie du **core V2** (Ring 1, primitives de pod). Elle prépare le pod_dir vanilla
AVANT spawn. Le code est **implémenté et actif en prod** — ce README documente l'état RÉEL,
contre le code (`lib/fleet/project_bootstrap.ex`, `lib/fleet/project_bootstrap/phase.ex`).

Invariant cardinal (SP positif) : l'agent dans le pod **ne voit aucune trace de la mécanique LCARS**
hors workspace vanilla + plugins. ⚠ Cet invariant n'est PAS testé en hermétique sur le chemin PROD
(il dépend de la vue sandbox bwrap ; le conformance_test couvre `prepare/3` = chemin mort,
false-green démoté F094/F096) → besoin d'un test-intégration sandbox.

## Ce que l'app fait VRAIMENT en prod (`Phase.Clone`)

Le seul chemin câblé en production est `Fleet.ProjectBootstrap.Phase.Clone`, appelé **directement**
par `Fleet.Spawner.Pod` (`maybe_bootstrap_project_workspace`) — **pas** via `prepare/3`.

- **`clone_or_skip/3`** — clone la branche code dans `<pod_dir>/workspace` :
  - `spec.project.repo_path` présent → `git clone --branch <base_branch> [--reference <ref>]`, puis
    pin optionnel sur `base_sha` (épinglage Executor, #596 R1 / F-03), puis `checkout -b feature/<pod_id>-<slug>`.
  - absent (pod permanent / pas de repo) → `mkdir workspace`, branch `nil` (skip).
  - Convention `"workspace"` ré-encodée ici (cycle compile interdit la dép vers `fleet_spawner`) ;
    DOIT rester en sync avec `Fleet.Spawner.@pod_workspace_subdir` (ce module est le PRODUCTEUR,
    `Pod` RECOMPUTE via `pod_workspace_path/1`).
- **`clone_work_doc/2`** — clone la branche DOC orpheline (`spec.project.work_branch`, conv. `work/ops`)
  dans `<pod_dir>/work` : plans, backlog, conventions sur lesquels l'agent s'appuie. Skip si pas de
  `work_branch`/`repo_path` ; FAIL-LOUD si déclarée mais clone échoué (I-CBC).

Auth git : `Fleet.Credentials.ForgeAuth.git_env/0` (token via env hors argv). Identité git posée
en env au lancement par `bwrap_launch.sh` (pas de `git config` mutable — garantie F-01 côté monde
via `Fleet.Pipeline.DeliverableGate.check_identity/3`).

Les autres concerns du bootstrap sont assurés en prod par des chemins **INDÉPENDANTS de `prepare/3`** :
le CLAUDE.md par `do_project` (pod.ex), les mounts/creds par bwrap (adr-f).

## Ce qui est MORT (`prepare/3` + 4 phases non-Clone — conformance-only)

`Fleet.ProjectBootstrap.prepare/3` orchestre 5 sous-phases en pipeline
(ALLOCATE → CLONE → INIT_MIMIC → BIND_CREDENTIALS → PREPARE_MOUNT_BINDS), mais **n'est appelé par
AUCUN chemin prod** — uniquement par le `conformance_test` (scaffold non-câblé). Les 4 phases
hors-Clone ne tournent donc qu'en test :

- **`Allocate.allocate/3`** — alloue `<pod_dir_base>/pod-<id>` (`:pod_dir_base` REQUIS, PB-D2 : défaut
  `/tmp` retiré, contredisait ADR-E).
- **`InitMimic.init_mimic/2`** — rend `templates/claude-md-vanilla.md.eex` → `<workspace>/CLAUDE.md`.
- **`BindCredentials.bind_credentials/2`** — retourne `%{}` (no-op depuis adr-f : creds via claudeDir
  natif bindé par bwrap, plus d'injection d'env OAuth).
- **`PrepareMountBinds.prepare_mount_binds/2`** — calcule les paths plugins à mount-bind RO
  (effectivement bindés en phase LAUNCH par `bwrap_launch.sh`).

## Décisions archi en attente (#596)

1. **Revive-vs-remove de `prepare/3`** — soit on le câble en prod (le spawner appelle `prepare/3`
   au lieu de `Phase.Clone` direct, ré-unifiant l'orchestration), soit on retire `prepare/3` + les 4
   phases non-Clone (scaffold mort). Aujourd'hui le spawner emprunte direct `Clone` → le pipeline
   complet n'a jamais tourné en prod. Décision non prise.
2. **Divergence `pod-<id>` / `pod_<id>` (F-016, dette connue)** — `Allocate.allocate/3` crée
   `pod-<id>` (tiret), alors que `Fleet.Spawner.Pod` crée `pod_<id>` (underscore). Sans conséquence
   tant que `prepare/3` est mort, mais un revive naïf de `prepare/3` allouerait un pod_dir incohérent
   avec la convention du spawner. À réconcilier au moment du revive (côté code — non corrigé ici).

## Frontière vendor

N0 (vendor-agnostic). Aucune dépendance vendor : git + EEx + paths. Dépend vers le bas de
`fleet_credentials` (`ForgeAuth.git_env/0`) et `fleet_cap_profile` (`Fleet.CapProfile`).
Ne PEUT PAS dépendre de `fleet_spawner` (cycle compile) — d'où la ré-encodage de `"workspace"`.
