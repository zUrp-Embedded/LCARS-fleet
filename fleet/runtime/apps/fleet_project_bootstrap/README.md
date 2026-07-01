# fleet_project_bootstrap — core du pod (Ring 1)

**Date** : 2026-05-18
**Dernière révision** : 2026-07-01
**Statut** : ACTIF — chemin PROD câblé (`Phase.Clone`). Orchestrateur mort `prepare/3` + 4 phases non-Clone RETIRÉS.
**Dérivé de** : 04_design-notes/ring1/fleet_project_bootstrap.md + session 2026-05-17/18 (rings finalisés)

Cette app fait partie du **core V2** (Ring 1, primitives de pod). Elle prépare le workspace du pod
AVANT spawn. Le code est **implémenté et actif en prod** — ce README documente l'état RÉEL,
contre le code (`lib/fleet/project_bootstrap/phase.ex`).

Invariant cardinal (SP positif) : l'agent dans le pod **ne voit aucune trace de la mécanique LCARS**
hors workspace vanilla + plugins. ⚠ Cet invariant n'est PAS testé en hermétique sur le chemin PROD
(il dépend de la vue sandbox bwrap) → besoin d'un test-intégration sandbox.

## Ce que l'app fait VRAIMENT en prod (`Phase.Clone`)

Le seul chemin câblé en production est `Fleet.ProjectBootstrap.Phase.Clone`, appelé **directement**
par `Fleet.Spawner.Pod` (`maybe_bootstrap_project_workspace` au spawn, `reset_in_place` au re-brief).

- **`clone_or_skip/3`** — clone la branche code dans `<pod_dir>/workspace` :
  - `spec.project.repo_path` présent → `git clone --branch <base_branch> [--reference <ref>]`, puis
    pin optionnel sur `base_sha` (épinglage par le rail forge-driven), puis `checkout -b feature/<slug>`.
  - absent (pod permanent / pas de repo) → `mkdir workspace`, branch `nil` (skip).
  - `rm_rf` du `workspace/` résiduel avant clone (idempotence du re-dispatch déterministe : un
    prédécesseur mort ne wedge pas le re-dispatch sur `clone_failed`).
  - Convention `"workspace"` ré-encodée ici (cycle compile interdit la dép vers `fleet_spawner`) ;
    DOIT rester en sync avec `Fleet.Spawner.@pod_workspace_subdir` (ce module est le PRODUCTEUR,
    `Pod` RECOMPUTE via `pod_workspace_path/1`).
- **`clone_work_doc/2`** — clone la branche DOC orpheline (`spec.project.work_branch`, conv. `work/ops`)
  dans `<pod_dir>/work` : plans, backlog, conventions sur lesquels l'agent s'appuie. Skip si pas de
  `work_branch`/`repo_path` ; FAIL-LOUD si déclarée mais clone échoué. `rm_rf` du `work/` résiduel avant
  clone (parité idempotence avec `clone_or_skip`).
- **`reset_in_place/3`** — reset COLD IN-PLACE du `workspace` d'un pod RÉSIDENT (pipe slot-freeze) pour le
  issue suivant, SANS `rm_rf` (le `ws` est bind-monté dans le sandbox bwrap VIVANT — le supprimer
  casserait le mount). Reset `--hard` sur le `base_sha` du NOUVEAU issue (REQUIS — fail-loud
  `{:reset_failed, :no_base_sha}` sinon) + `clean -fdx` + `checkout -B feature/<slug>`.

Auth git : `Fleet.Credentials.ForgeAuth.git_env/0` (token via env hors argv, `GIT_TERMINAL_PROMPT=0`).
Identité git posée en env au lancement par `bwrap_launch.sh` (pas de `git config` mutable — garantie
côté monde via `Fleet.Pipeline.DeliverableGate.check_identity/3`).

**Git BORNÉ par construction** : clone/fetch/checkout/reset passent par `Fleet.Credentials.Shell.git/2`
(deadline + SIGKILL du process OS à l'expiration) — un git réseau qui pend (ou qui prompterait sans TTY)
est tué dans la deadline et rend `{:clone_failed|:reset_failed, {:git_timeout|:git_exit, _}}` au lieu de
figer le `Fleet.Spawner.Pod` (GenServer) → plus de pod zombie. La deadline du clone réseau est calibrable
via l'opt `:git_timeout_ms` de `clone_or_skip/3`.

Les autres concerns du bootstrap sont assurés en prod par des chemins **INDÉPENDANTS de `Phase.Clone`** :
le CLAUDE.md par `do_project` (pod.ex), les mounts/creds par bwrap (adr-f).

## Code mort RETIRÉ (orchestrateur `prepare/3` + 4 phases non-Clone)

L'orchestrateur `Fleet.ProjectBootstrap.prepare/3` (pipeline ALLOCATE → CLONE → INIT_MIMIC →
BIND_CREDENTIALS → PREPARE_MOUNT_BINDS) et les 4 phases non-Clone (`Allocate`, `InitMimic`,
`BindCredentials`, `PrepareMountBinds`) n'étaient câblés par AUCUN chemin prod (le spawner empruntait
direct `Phase.Clone`) — uniquement par un `conformance_test` (false-green démoté). Ils ont été **RETIRÉS**
(décision revive-vs-remove tranchée = remove). Leurs concerns sont assurés ailleurs : CLAUDE.md par
`do_project` (pod.ex), creds/mounts par `bwrap_launch.sh` (adr-f). La divergence de convention pod_dir
`pod-<id>` (ancien `Allocate`) vs `pod_<id>` (spawner) disparaît avec le retrait.

## Frontière vendor

N0 (vendor-agnostic). Aucune dépendance vendor : git + EEx + paths. Dépend vers le bas de
`fleet_credentials` (`ForgeAuth.git_env/0` ET `Fleet.Credentials.Shell.git/2` pour le git borné) et
`fleet_cap_profile` (`Fleet.CapProfile`). Ne PEUT PAS dépendre de `fleet_spawner` (cycle compile) —
d'où la ré-encodage de `"workspace"`.
