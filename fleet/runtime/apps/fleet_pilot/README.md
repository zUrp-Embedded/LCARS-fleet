# fleet_pilot

**Date** : 2026-05-26
**Dernière révision** : 2026-06-16 (+ ProjectOnboard — onboarding dual-worktree Rail 1)
**Statut** : actif — service d'auto-orchestration tickets Gitea (ring 1 client du core).
**Référencé par** : `beyond_#4/01_architecture/topologie-ring.md` §Élagage

Service d'auto-orchestration tickets Gitea (M-033 backlog, doctrine
`beyond_#4/01_architecture/topologie-ring.md` §"Élagage" : **client du
core ring 1, pas core**).

Reçoit les events `gitea.*` du Bus (`Fleet.EventRouter.Bus`), filtre via
catalogue déclaratif `priv/config/forge-routing.yaml` (axes
`type:` × `state:` × `assignee`), puis invoke `Fleet.Pipeline.start_pipeline/2`
avec le ticket_id + le brief (issue.body) comme `ask`.

Idempotence inter-restart : label Gitea `lcars-dispatched` ajouté côté
forge avant invocation (lock atomique). Le poller reconciliateur
(brique 2, future) respectera ce label pour catch-up post-crash.

## Mode stage (forge-state-machine — A2/A3, actif)

Le mode **stage** (la forge EST la machine à états : ticket **assigné** à l'humain owner, non
verrouillé → spawn le rôle **PRODUCTEUR** ; l'**assignee = l'humain**, point fixe — DN §1)
double puis remplace le dispatch legacy ci-dessus. Activé par `:stage_dispatch?` + `:poll_repo` ;
le legacy par `:start_dispatcher` — **mutuellement exclusifs** (garde `Application`
`guard_no_duplicate_poller!`, F054 ; legacy `AutoDispatcher` retiré à F-09). Submodules :

- `Fleet.Pilot.StageDispatcher` — `decide/2` (issue assignée non verrouillée → `{:spawn, role, profile}`
  où `role` = **rôle producteur invariant** `:producer_role`, défaut `engineer` — pas un marqueur
  par-ticket, DN §1) + `dispatch_issue/2` (ordre canonique label-verrou → comment → pod). Les **juges**
  sont dispatchés PR-driven via `dispatch_review/2` (②.1d, **PR = machine à états**, DN §1.4-1.5,
  sans branch-protection — LCARS agrège, interim) : reviewers en attente → spawn le prochain juge (un à
  un, sérialisé par le verrou PR ; clone la **feature-branch** pour voir le diff) ; round terminé +
  verdict agrégé `:changes_requested` → rework du producteur ; `:approved` → **merge FF scellé
  `:gatekeeper_role`** (comment de fin honnête + close via `Closes #N`).
- `Fleet.Pilot.Poller` — scanne le repo, dispatche les issues assignées → spawn producteur (+ Entry legacy sur `type:`, FALL).
- `Fleet.Pilot.Labels` — vocabulaire wire-protocol (source unique) : **uniquement** ce qui n'est pas
  dérivable de l'état forge — verrous `lcars-in-flight`/`lcars-awaits-human`, états `state:*` (legacy carte).
- `Fleet.Pilot.HopConsumer` — consumer Bus de la **fin-de-hop** (`pod.completed` → `HopCompleter`) ;
  gatekeeper §L441 (escalade soft/terminal → `resume_gate`). **Singleton** : la complétion lourde
  (git push ≤30s) est offloadée en `Task.Supervisor` (`:hop_runner` / `HopTaskSupervisor`, F067) → ne
  bloque pas la tête de ligne.
- `Fleet.Pilot.HopCompleter` — orchestrateur de fin-de-hop PR-natif (`complete_pr/2`). **②.1d single-brique
  (sans carte)** : producteur → `:review` (ouvre la PR **au nom de l'eng** via token de rôle + `request_review`
  des juges `:reviewer_roles` + **assigne l'humain** + unlock issue/PR) ; juge → `:reviewed` (poste la review
  native **signée par le juge** + unlock PR — le merge/rework est décidé par le poller sur l'état-PR agrégé).
  Identité ②.1e via `Fleet.Credentials.RoleToken` (poste EN SON NOM ; token absent → fallback système loggué).
  (Legacy carte multi-stage : `complete/2` séquence §5 + intents `:advance`/`:promote`/`:rework`, conservé.)

Knobs : `:stage_dispatch?` + `:poll_repo` + `:poll_interval_ms` (stage), `:producer_role` (défaut `engineer`),
`:reviewer_roles` (juges PR, défaut `["qualifier", "reviewer"]`), `:gatekeeper_role` (scelle les fusions,
défaut `gatekeeper`), `:hop_runner` (offload complétion, F067).

## Onboarding projet (Rail 1 — « idée → le projet existe »)

`Fleet.Pilot.ProjectOnboard` — `onboard/2` : crée mécaniquement un projet en répliquant l'archi
dual-dir de LCARS (un repo, **deux worktrees**) :

- `/home/projects/<name>` → worktree `main` (livrable, push origin) ;
- `/home/projects.work/<name>` → worktree **orphan** `work/ops` (plans/backlog/ops).

Séquence : `ForgeClient.create_repo` (org `fleet`, `auto_init`) → `git clone main` → scaffold (README,
.gitignore, .editorconfig, docs/spec.md) → commit+push `main` → `git worktree add --orphan -b work/ops`
→ scaffold (backlog.md, scratchpad.md, plans/) → commit+push `work/ops`. Identité **M2** (l'onboarding est
un acte d'infra système, pas du travail créatif) : `author=lcars-system` (le système GÉNÈRE le scaffold ;
l'arch n'écrit rien, il relaie `name`+`pitch`), `committer`=git config runtime (**l'humain qui a initié →
tracé**), `pusher`=`lcars-system` (`ForgeAuth.git_env`, owner fleet-wide) — tout avataré. Rail mécanique
(l'arch *déclenche* via le tool MCP `create_project`, le système *exécute* ; cf. `fleet_mcp`). Pas de GenServer.

`Fleet.Pilot.ForgeClient` porte aussi les write-ops forge réutilisées ici (`create_repo`, `create_issue`,
`put_file`, `post_comment`, `close_issue`).

## Découplage core

Pas dans le core ring 1 (cf. doctrine `topologie-ring.md:173`). Le core
peut être invoqué manuellement OU par `fleet_pilot` après — découplage.
