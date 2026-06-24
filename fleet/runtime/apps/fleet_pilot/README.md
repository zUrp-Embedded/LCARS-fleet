# fleet_pilot

**Date** : 2026-05-26
**Dernière révision** : 2026-06-24 (git réseau borné via Fleet.Credentials.Shell — ls-remote + onboarding, remédiation Lot C)
**Statut** : actif — service d'auto-orchestration tickets Gitea (ring 1 client du core).
**Référencé par** : `beyond_#4/01_architecture/topologie-ring.md` §Élagage

Service d'auto-orchestration tickets Gitea (M-033 backlog, doctrine
`beyond_#4/01_architecture/topologie-ring.md` §"Élagage" : **client du
core ring 1, pas core**).

Reçoit les events `gitea.*` du Bus (`Fleet.EventRouter.Bus`), filtre via
catalogue déclaratif `priv/config/forge-routing.yaml` (axes
`type:` × `state:` × `assignee`), puis spawn le rôle producteur via le rail
forge-state-machine décrit ci-dessous (mode **stage**).

> **OBSOLÈTE — dispatch legacy RETIRÉ.** L'ancien chemin invoquait
> `Fleet.Pipeline.start_pipeline/2` (moteur RAM `Fleet.Pipeline.Executor`) avec
> le ticket_id + le brief (issue.body) comme `ask`, et posait un label
> `lcars-dispatched` (lock atomique) pour l'idempotence inter-restart. Ce moteur
> RAM a été **supprimé** (②.3 / BL-050 — cf. `fleet_pipeline` `Application`,
> `start_pipeline`/`Executor` n'existent plus) et le `AutoDispatcher` retiré à
> F-09. Le dispatch actuel passe **uniquement** par le mode stage (§ ci-dessous).

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
  verdict agrégé `:changes_requested` → rework du producteur (**borné MA-06** : compteur forge-natif
  `ForgeClient.count_change_request_rounds/3` = nb REQUEST_CHANGES ; > budget `:max_pr_rework_rounds`
  (défaut 2) → **escalade arch** au lieu de re-spawn → fin du churn infini) ; `:approved` → **merge `rebase` scellé
  `:gatekeeper_role`** via `Fleet.Pilot.GatekeeperSeal` (**sceau UNIQUE** partagé avec `HopCompleter.promote`,
  F-arch-MCP : comment gatekeeper + merge signé gatekeeper, plus de fork où l'escalade mergeait en token
  système ; LINÉAIRE + gère un `main` avancé sous une PR parallèle — multi-ticket, cf. `ForgeClient.merge_pr`
  ; comment de fin honnête + close via `Closes #N`). **Passage de substance
  (anti-famine-d'info, fix #1)** : le mandat **juge** (git-native) le POINTE sur son workspace
  (`git diff`) + porte le **critère** (body de l'issue, désamorcé I-CBC via `GateBrief :request`) ; le
  mandat **rework** injecte le **body des reviews REQUEST_CHANGES** (`ForgeClient.change_request_feedback/3`)
  — sans quoi le juge jugeait du `{}` et l'eng corrigeait à l'aveugle (wedge prouvé live morse).
  Le pin de base (`ls-remote` du tip, hors-pod) passe par `Fleet.Credentials.Shell.git` : borné par
  construction (process-group dédié, tué entier à la deadline mur) — remplace le `Task.async`+`brutal_kill`
  qui ne tuait que le Task BEAM en laissant fuir le process git porteur du token forge.
- `Fleet.Pilot.Poller` — scanne le repo, lit la **route-comment** (`[lcars-route:carte:stage]`, gravée par `create_ticket` = la state-machine de routing) → dispatche le rôle du stage (`carte_role`). Bail « 1 pipeline/repo » sur la route (engagé = `in-flight` OU route avancée au-delà du 1er stage). Routing par label retiré (`type:*` = visu seulement). Sans route → producteur A1 (fallback).
- `Fleet.Pilot.Labels` — vocabulaire wire-protocol (source unique) : **uniquement** ce qui n'est pas
  dérivable de l'état forge — verrous `lcars-in-flight`/`lcars-awaits-human`, états `state:*` (legacy carte).
- `Fleet.Pilot.HopConsumer` — consumer Bus de la **fin-de-hop** (`pod.completed` → `HopCompleter`) ;
  gatekeeper §L441 (escalade soft/terminal → `resume_gate`). **Singleton** : la complétion lourde
  (git push ≤30s) est offloadée en `Task.Supervisor` (`:hop_runner` / `HopTaskSupervisor`, F067) → ne
  bloque pas la tête de ligne. **MA-03 — verdict auto-descriptif** : le contexte de reprise d'une escalade
  voyage dans le `metadata` de la **tâche** d'éval (qui survit dans le broker à un crash du HopConsumer
  seul) ; au restart (`gate_evals` RAM vide) le verdict (`task_completed`) est **reconstruit** du metadata
  au lieu d'un drop silencieux (plus d'issue wedgée à vie). `gate_evals` n'est qu'une optimisation fast-path.
- `Fleet.Pilot.HopCompleter` — orchestrateur de fin-de-hop PR-natif (`complete_pr/2`). **②.1d single-brique
  (sans carte)** : producteur → `:review` (ouvre la PR **au nom de l'eng** via token de rôle + `request_review`
  des juges `:reviewer_roles` + **assigne l'humain** + unlock issue/PR) ; juge → `:reviewed` (poste la review
  native **signée par le juge** + unlock PR — le merge/rework est décidé par le poller sur l'état-PR agrégé).
  **Voix de l'eng (info SORTANTE)** : si le producteur rend un `summary` dans `submit_result` (extrait par
  `HopConsumer`, coercé `safe_str`), le système le poste en **commentaire PR `as_role` engineer** (livraison
  ET rework) — l'eng n'est plus muet sur la forge (jumeau sortant de l'anti-famine ; le mandat l'élicite).
  **Blocked_dep** : si le producteur rend `blocked: true` (dépendance/info manquante), `HopConsumer` route vers
  `await_human` (motif = son `summary` + `lcars-awaits-human` + unlock → poller SKIP, l'humain tranche via l'arch)
  AU LIEU d'une publish vide (`:no_deliverable_commit` = wedge silencieux). Le mandat dit à l'eng de marquer
  `blocked` plutôt que deviner à l'aveugle.
  Identité ②.1e via `Fleet.Credentials.RoleToken` (poste EN SON NOM ; token absent → fallback système loggué).
  (Legacy carte multi-stage : `complete/2` séquence §5 + intents `:advance`/`:promote`/`:rework`, conservé.)

Knobs : `:stage_dispatch?` + `:poll_repo` + `:poll_interval_ms` (stage), `:producer_role` (défaut `engineer`),
`:reviewer_roles` (juges PR, défaut `["qualifier", "reviewer"]`), `:gatekeeper_role` (scelle les fusions,
défaut `gatekeeper`), `:hop_runner` (offload complétion, F067), `:wake_recovery` (seam recovery de wake,
défaut `&Fleet.Pilot.WakeRecovery.wake/3` ; MA-17 : le retour du wake est load-bearing → un kick injoignable
remonte `{:error,{:wake_unreached,_}}` au dispatch (tally honnête) / une telemetry au gatekeeper, jamais avalé).

## Onboarding projet (Rail 1 — « idée → le projet existe »)

`Fleet.Pilot.ProjectOnboard` — `onboard/2` : crée mécaniquement un projet en répliquant l'archi
dual-dir de LCARS (un repo, **deux worktrees**) :

- `/home/projects/<name>` → worktree `main` (livrable, push origin) ;
- `/home/projects.work/<name>` → worktree **orphan** `work/ops` (plans/backlog/ops).

Toutes les ops git de l'onboarding (clone/worktree/commit/push) passent par `Fleet.Credentials.Shell.git` :
bornées par construction (process-group dédié, tué entier à la deadline mur) — aucun `System.cmd("git", …)`
nu ne subsiste, et un clone/push réseau qui pend ne fige plus l'orchestration ni ne laisse fuir un process
git porteur du token forge.

Séquence : `ForgeClient.create_repo` (org `fleet`, `auto_init`) → `git clone main` → scaffold (README,
.gitignore, .editorconfig, docs/spec.md) → commit+push `main` → `git worktree add --orphan -b work/ops`
→ scaffold (backlog.md, scratchpad.md, plans/) → commit+push `work/ops` → **`lock_main`** (②.1d) : donne
le **write** aux comptes de rôle (engineer/qualifier/reviewer/gatekeeper — sinon leurs reviews ne comptent
pas + le gatekeeper ne peut pas merger) **puis pose la branch-protection sur `main`** (N approvals = nb de
juges, dismiss-stale, block-on-rejected, pas de push direct). Mécanique → tout projet onboardé a le **gate
forge-enforcé** (l'arbitre = la forge, cible DN §1.4). `work/ops` + feature-branches non protégées. Identité **M2** (l'onboarding est
un acte d'infra système, pas du travail créatif) : `author=lcars-system` (le système GÉNÈRE le scaffold ;
l'arch n'écrit rien, il relaie `name`+`pitch`), `committer`=git config runtime (**l'humain qui a initié →
tracé**), `pusher`=`lcars-system` (`ForgeAuth.git_env`, owner fleet-wide) — tout avataré. Rail mécanique
(l'arch *déclenche* via le tool MCP `create_project`, le système *exécute* ; cf. `fleet_mcp`). Pas de GenServer.

`Fleet.Pilot.ForgeClient` porte aussi les write-ops forge réutilisées ici (`create_repo`, `create_issue`,
`put_file`, `post_comment`, `close_issue`, `add_collaborator`, `protect_branch`).

## Découplage core

Pas dans le core ring 1 (cf. doctrine `topologie-ring.md:173`). Le core
peut être invoqué manuellement OU par `fleet_pilot` après — découplage.
