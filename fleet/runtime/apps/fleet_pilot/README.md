# fleet_pilot

**Date** : 2026-05-26
**Dernière révision** : 2026-07-02 (atomisation StepDispatcher : extraction du cycle de vie REVIEW `ReviewLifecycle` — aiguillage verdicts + rework/conflit + promotion (`dispatch_by_verdicts`/`dispatch_rework`/`dispatch_conflict_resolution`/`promote_pr`), struct `%ReviewLifecycle.Ctx{}` + captures partagées `route_for`/`tag_err`, 848→469 l ; extraction feuille de spawn SINGLE-AUTHORITY `Spawn` — spawn_step/pod_id/serialize_scope/opts-builders, struct `%Spawn.Seams{}` 6 seams, 1110→848 l ; + atomisation ForgeClient : Transport + ForgeProtocol + Jury/Repo/Files, 1652→786 l ; extraction `IncidentConsumer` hors StepRunConsumer)
**Statut** : actif — service d'auto-orchestration issues Gitea (ring 1 client du core).
**Référencé par** : `beyond_#4/01_architecture/topologie-ring.md` §Élagage

Service d'auto-orchestration issues Gitea (M-033 backlog, doctrine
`beyond_#4/01_architecture/topologie-ring.md` §"Élagage" : **client du
core ring 1, pas core**).

Découvre ses projets par topic (`lcars-fleet-<humain>`) et spawn le rôle
producteur via le rail forge-state-machine décrit ci-dessous (mode **step**) :
la forge EST la machine à états (label de route gravé sur le issue). Le
catalogue déclaratif `forge-routing.yaml` (axes `type:` × `state:` × `assignee`)
a été SUPPRIMÉ avec le rail AutoDispatcher legacy — plus aucun code ne le lisait.

> **OBSOLÈTE — dispatch legacy RETIRÉ.** L'ancien chemin invoquait
> `Fleet.Pipeline.start_pipeline/2` (moteur RAM `Fleet.Pipeline.Executor`) avec
> le issue_id + le brief (issue.body) comme `ask`, et posait un label
> `lcars-dispatched` (lock atomique) pour l'idempotence inter-restart. Ce moteur
> RAM a été **supprimé** (②.3 / BL-050 — cf. `fleet_pipeline` `Application`,
> `start_pipeline`/`Executor` n'existent plus) et le `AutoDispatcher` retiré à
> F-09. Le dispatch actuel passe **uniquement** par le mode step (§ ci-dessous).

## Mode step (forge-state-machine — A2/A3, actif)

Le mode **step** (la forge EST la machine à états : issue **assigné** à l'humain owner, non
verrouillé → spawn le rôle **PRODUCTEUR** ; l'**assignee = l'humain**, point fixe — DN §1)
double puis remplace le dispatch legacy ci-dessus. Activé par `:step_dispatch?` + la forge `base_url`
(`:forge[:base_url]` / `FORGE_BASE_URL`) — c'est la **seule** garde fail-loud du boot step
(`Fleet.Pilot.Application.step_children!`) : sans `base_url`, ni découverte par topic ni push per-step-run.
`:poll_repo` n'est **plus** une condition d'activation (override legacy/test mono-repo seulement, cf. § Knobs) :
la découverte des repos se fait par topic (`lcars-fleet-<human>`), pas par repo fixe, et le repo+remote de
chaque step_run voyagent dans l'event `pod.completed`. Submodules :

- `Fleet.Pilot.StepDispatcher` — `decide/2` (issue assignée non verrouillée → `{:spawn, role, profile}`
  où `role` = **rôle producteur invariant** `:producer_role`, défaut `engineer` — pas un marqueur
  par-issue, DN §1) + `dispatch_issue/2` (ordre canonique label-verrou → comment → pod). Les **juges**
  sont dispatchés PR-driven via `dispatch_review/2` (②.1d, **PR = machine à états**, DN §1.4-1.5,
  sans branch-protection — LCARS agrège, interim) : reviewers en attente → spawn le prochain juge (un à
  un, sérialisé par le verrou PR ; clone la **feature-branch** pour voir le diff) ; round terminé +
  verdict agrégé `:changes_requested` → rework du producteur (**borné MA-06** : compteur forge-natif
  `ForgeClient.count_change_request_rounds/3` = nb REQUEST_CHANGES ; > budget `:max_pr_rework_rounds`
  (défaut 2) → **escalade arch** au lieu de re-spawn → fin du churn infini) ; `:approved` → **merge `rebase` scellé
  `:gatekeeper_role`** via `Fleet.Pilot.GatekeeperSeal` (**sceau UNIQUE** partagé avec `StepRunCompleter.promote`,
  F-arch-MCP : comment gatekeeper + merge signé gatekeeper, plus de fork où l'escalade mergeait en token
  système ; LINÉAIRE + gère un `main` avancé sous une PR parallèle — multi-issue, cf. `ForgeClient.merge_pr`
  ; comment de fin honnête + close via `Closes #N`). **Passage de substance
  (anti-famine-d'info, fix #1)** : le brief **juge** (git-native) le POINTE sur son workspace
  (`git diff`) + porte le **critère** (body de l'issue, désamorcé I-CBC via `GateBrief :request`) ; le
  brief **rework** injecte le **body des reviews REQUEST_CHANGES** (`ForgeClient.change_request_feedback/3`)
  — sans quoi le juge jugeait du `{}` et l'eng corrigeait à l'aveugle (wedge prouvé live morse).
  Le pin de base (`ls-remote` du tip, hors-pod) passe par `Fleet.Credentials.Shell.git` : borné par
  construction (process-group dédié, tué entier à la deadline mur) — remplace le `Task.async`+`brutal_kill`
  qui ne tuait que le Task BEAM en laissant fuir le process git porteur du token forge.
  Les concerns à **frontière nette** sont éclatés en sous-modules :
    - `Fleet.Pilot.StepDispatcher.ProjectResolver` — cluster I/O **quasi-pur** (aucun seam module) :
      pinning de la base git (`base_sha`/`gate_base_sha`) via `git ls-remote` HORS-POD.
      `default_project_resolver/2` = API publique (défaut du seam `:project_resolver`, `defdelegate`
      depuis le module racine).
    - `Fleet.Pilot.StepDispatcher.ArchEscalation` — cluster **IMPUR** « escalade arch » (écriture forge) :
      `escalate_rework/4` (rework non convergent, budget épuisé MA-06) + `escalate_conflict/4` (conflit de
      merge récurrent) posent le **commentaire gatekeeper dédupliqué** (`as_role` + `dedup_signature`) + le
      verrou `lcars-awaits-arch` sur l'ISSUE (poller SKIP → fin du churn) via l'unique point d'écriture
      `escalate_to_arch` (privé, pas de fork). **Frontière blindée** : reçoit un struct
      `%ArchEscalation.Seams{}` (les 3 seams `forge`/`repo`/`forge_opts`, `@enforce_keys` → un accès
      hors-3-seams ne compile pas), jamais le `ctx` entier. La **DÉCISION** d'escalade (budget forge,
      IncidentRegistry, résolution-vs-escalade) reste le SINGLE-AUTHORITY du flux review
      (`ReviewLifecycle.dispatch_rework`/`dispatch_conflict_resolution`) — ArchEscalation ne fait QU'ÉCRIRE.
    - `Fleet.Pilot.StepDispatcher.Spawn` — **feuille de spawn SINGLE-AUTHORITY** sur laquelle les DEUX
      flux CONVERGENT (issue `dispatch_issue` + PR `ReviewLifecycle.do_dispatch_review`) : une seule copie de
      `spawn_step/9` (ordre canonique **verrou → pod → enqueue → wake**, wake EN DERNIER ; compensation
      = retrait du verrou + kill SEULEMENT si spawn frais ; retour `{:error, {:wake_unreached, …}}`
      load-bearing = le poller PREND le bail, le pod est démarré, seul le wake tmux a raté), une seule
      identité pod (`pod_id_for_scope/4`, project→`for_repo` | instance→`for_issue`) et une seule
      sérialisation de scope (`serialize_project_scope/6` : gate `:role_busy` AVANT tout verrou +
      reprovision cold in-place d'un pipe ready). Porte aussi les builders d'opts / naming
      (`rc_name/2`, `feature_slug/1` purs, `maybe_put_project|route|repo_id`, `resolve_repo_id/3`).
      Le cœur DÉCIDE (route/rôle/verdict), Spawn EXÉCUTE. **Frontière blindée** : `spawn_step/9` reçoit
      un struct `%Spawn.Seams{}` (les 6 seams `forge`/`spawner`/`task_queue`/`repo`/`forge_opts`/
      `wake_recovery`, `@enforce_keys` → un accès hors-6-seams ne compile pas), jamais le `ctx`/`opts`
      entier ; chacun des 2 callers construit le struct à son site. `safe_kill/2` reste public (partagé
      avec `ReviewLifecycle.promote_pr`, die-on-promote — une seule copie, pas de fork).
    - `Fleet.Pilot.StepDispatcher.ReviewLifecycle` — **cycle de vie REVIEW (PR)**. `dispatch_review/2`
      (PUBLIQUE, contrat poller) RESTE au cœur (gate PR `in-flight`/`awaits-arch` + construction du `ctx` +
      lecture `pr_review_state`) et DÉLÈGUE l'aiguillage à `dispatch_by_verdicts/5` (point d'entrée). Trois
      clusters : **aiguillage** (juge pending → spawn ; tous décisifs + un `:changes_requested` → rework ;
      tous approuvé → merge ; aucun demandé → `:no_verdict`), **rework/conflit** (`dispatch_rework` borné
      MA-06 + `dispatch_conflict_resolution` borné IncidentRegistry ; `encode_pr_letters/1` (pur, base-26
      digit-free) vit ICI, consommé par la clé d'incident), **promotion** (`promote_pr` = sceau
      `Fleet.Pilot.GatekeeperSeal` + merge rebase + die-on-promote de l'eng). **Dépendance
      uni-directionnelle** (ReviewLifecycle → `Spawn`/`ArchEscalation`/`GatekeeperSeal` → ø ; ne nomme JAMAIS
      `StepDispatcher` → pas de cycle) : re-construit `Spawn.Seams`/`ArchEscalation.Seams` au site d'appel de
      chaque feuille. **Frontière blindée** : reçoit un struct `%ReviewLifecycle.Ctx{}` (les seams
      `forge`/`loader`/`spawner`/`task_queue`/`resolver`/`repo`/`forge_opts`/`wake_recovery`/`opts`,
      `@enforce_keys`), jamais une map nue. Les helpers PARTAGÉS avec le flux issue (`route_for/4` lecture de
      route + `tag_err/2` tagging d'erreur) RESTENT au cœur et sont threadés par CAPTURE dans le `Ctx`
      (`route_reader`/`err_tagger`, exactement comme `resolver`/`wake_recovery`) — une seule copie (pas de
      fork), la capture est créée au cœur (pas de référence remontante → pas de cycle).
- `Fleet.Pilot.BriefBuilder` — **autorité du FORMAT des briefs** : worker / judge / brief-review /
  rework / conflit + instructions de voix de l'eng. `StepDispatcher` CHOISIT quel brief selon l'état forge
  (`build_brief/9` dispatche sur `brief_kind`/`judge_target`), `BriefBuilder` le FORME. La **judge-ness**
  est fail-loud (kind/target hors-vocab → `raise` ; un juge ne reçoit JAMAIS un corps d'issue exécutable) ;
  le brief juge est **désamorcé** via `Fleet.Pipeline.GateBrief` (critère rendu comme contexte). `forge` =
  arg injecté (seam). API publique : `build_brief/9`, `rework_brief/6`, `resolve_conflict_brief/6`.
- `Fleet.Pilot.Poller` — **DÉCOUVRE** ses repos par topic (`lcars-fleet-<human>`) PUIS **ADMET** uniquement
  ceux scellés système (`ForgeClient.admitted?` — marqueur d'onboarding bot-authored ; le topic mutable seul
  ne suffit plus, cf. § Onboarding « sceau d'admission »). Sur chaque repo admis : scanne, lit la **route-comment**
  (`[lcars-route:workflow_map:step]`, gravée par `create_issue` = la state-machine de routing) → dispatche le rôle du
  step (`workflow_map_role`). Bail « 1 pipeline/repo » sur la route (engagé = `in-flight` OU route avancée au-delà du
  1er step). Routing par label retiré (`type:*` = visu seulement). Sans route → producteur A1 (fallback).
  **Bail fail-closed (2 invariants)** : (1) le bail se prend dès qu'un pipeline est DÉMARRÉ (verrou posé +
  pod spawné), jamais sur le succès d'une étape postérieure — un dispatch qui rend `{:error,{:wake_unreached,_}}`
  (verrou+pod+brief en place, seul le réveil tmux a raté) PREND le bail intra-tick (sinon un 2e issue du même
  repo démarrerait un 2e pipeline) ; l'anomalie reste comptée en `errors`/`last_tally_errors`, jamais avalée.
  (2) l'engagement se lit sur la ROUTE (append-only, robuste), pas sur le chargement de la workflow_map : un échec
  TRANSITOIRE de workflow_map (réseau/forge nil) sur un pipeline routé le classe ENGAGÉ (bail TENU, fail-closed) —
  le dispatch de son step fail-loud si la workflow_map manque, mais le bail ne se libère pas.
- `Fleet.Pilot.Labels` / `Fleet.Pilot.ForgeProtocol` — **vocabulaire wire-protocol** (source unique, build+parse
  **co-localisés** : un seul point si un format change). `Labels` = les **labels-verrous** non dérivables de
  l'état forge (`lcars-in-flight`/`lcars-awaits-arch`). `ForgeProtocol` = les **formats purs** (aucun I/O) : la
  feature-branch `lcars/issue-<n>-<role>` (`feature_branch/2` construit, `parse_feature_branch/1` lit), les
  marqueurs route/step_run/onboard, le bloc ` ```result `, et le primitif de confiance `system_authored?/2`.
- `Fleet.Pilot.ForgeClient` — **client Gitea, couche DOMAINE** (la forge EST la machine à états). C'est le module
  injecté par le seam `:forge_client`. Agrégat éclaté par **sous-domaine** : ce module ne garde que le **cœur
  couplé** (cycle de vie d'une issue : label/assignee/comment/close/create + PR open/review-request/merge +
  route/step_run) + l'adaptateur credential→wire `as_role/2` (token du compte de rôle dans `forge_opts[:token]`,
  source unique partagée par `StepRunCompleter`/`StepDispatcher`/sceaux gatekeeper). Les concerns à **frontière
  nette** vivent dans des sous-modules :
    - `Fleet.Pilot.ForgeClient.Transport` — moteur HTTP/config/encodage-URL/pagination + login système (zéro
      protocole forge) ; `ForgeClient` l'**`import`e**.
    - `Fleet.Pilot.ForgeClient.Jury` — état de jury PR (verdicts commit-scopés, jury volatil, feedback/rounds de rework).
    - `Fleet.Pilot.ForgeClient.Repo` — provisioning repo + sceau d'admission (`post_onboard_marker`/`admitted?`) ;
      seule arête descendante : le sceau matérialisé via `create_issue`/`close_issue` du cœur (layering).
    - `Fleet.Pilot.ForgeClient.Files` — lecture/écriture de fichiers (contents API), appelé en direct par `IncidentRegistry`.

    Discipline du seam : les ops *seam-faced* (atteintes via le `forge` injecté : `pr_review_state`,
    `repo_id`, `search_repos_by_topic`, `admitted?`, `parse_feature_branch`…) restent **joignables depuis
    `ForgeClient`** (forwarders explicites / 1 `defdelegate` vers `ForgeProtocol`) ; les ops appelées en direct
    (provisioning, files) pointent sur leur sous-module. Le vocab pur du wire-protocol vit dans `ForgeProtocol`.
- `Fleet.Pilot.StepRunConsumer` — consumer Bus de la **fin-de-step-run** (`pod.completed` → `StepRunCompleter`) ;
  gatekeeper §L441 (escalade soft/terminal → `resume_gate`). **Singleton** : la complétion lourde
  (git push ≤30s) est offloadée en `Task.Supervisor` (`:step_run_runner` / `StepRunTaskSupervisor`, F067) → ne
  bloque pas la tête de ligne. **MA-03 — verdict auto-descriptif** : le contexte de reprise d'une escalade
  voyage dans le `metadata` de la **tâche** d'éval (qui survit dans le broker à un crash du StepRunConsumer
  seul) ; au restart (`gate_evals` RAM vide) le verdict (`work_item.completed`) est **reconstruit** du metadata
  au lieu d'un drop silencieux (plus d'issue wedgée à vie). `gate_evals` n'est qu'une optimisation fast-path.
    - `Fleet.Pilot.StepRunConsumer.Verdict` — cluster **PUR** du verdict (aucun `state`) extrait du consumer :
      **décodage** (`gate_result/1`, `gate_decision/1`, `unwrap_worker_envelope/1` — lecture de la décision
      gate-decision-v1 enfouie dans les enveloppes TaskQueue/worker) + **rendu texte** (`verdict_comment/3`,
      `review_event_for_decision/1`, `judge_review_body/2`, `eng_summary/1` — trace verdict durable, corps de
      review, voix de l'eng). **Un seul module** (décodage+rendu couplés : `eng_summary` s'appuie sur
      `unwrap_worker_envelope`, primitif partagé). Vocab canon via l'AUTORITÉ UNIQUE `Fleet.Pipeline.GateDecision`
      (`@gate_decisions` non recopié). Le cœur décisionnel stateful (`apply_verdict`/`gate_decide`/`resume_gate`/
      `complete_business_step_run`) reste dans le module racine.
    - `Fleet.Pilot.StepRunConsumer.GatekeeperEscalation` — cluster **IMPUR** « escalade gatekeeper »
      (async-out) extrait du consumer : `dispatch/7` (enqueue le brief d'éval au gatekeeper permanent
      + kick + télémétrie `[:fleet_pilot, :step_run_consumer, :gatekeeper_kick_unreached]`). Appelé par
      `gate_decide` sur le chemin `{:dispatch_gatekeeper, _}` ; rend le contrat étroit
      `{:ok, corr} | {:error, reason}` (fail-loud : pas de gatekeeper booté / enqueue raté →
      `{:error, _}`, jamais un pass silencieux). **Frontière blindée** : ne reçoit PAS le `state`
      entier mais un struct `%GatekeeperEscalation.Seams{}` (les 4 seams
      `task_queue`/`spawner`/`gatekeeper_pod_id_fun`/`wake_recovery`, `@enforce_keys` → un accès à un
      autre champ de state ne compile pas). Le cœur décisionnel (`gate_decide`/`resume_gate`) reste
      dans le module racine.
- `Fleet.Pilot.IncidentConsumer` — consumer Bus **séparé** des events d'**échec** de pod (`pod.failed`/
  `wake.failed`, source `:spawner`) → `IncidentRegistry` (note 1er / escalade récurrent ; wake récurrent =
  `:sp_suspect`). **Stateless**, sa propre `Task.Supervisor` d'offload (`:runner` défaut nil→sync, prod
  `&offload_async/1`). Extrait du `StepRunConsumer` : concern distinct de la complétion → blast-radius isolé
  (un burst d'échecs ne partage pas la mailbox de la fin-de-step-run) et nom du StepRunConsumer rendu honnête.
- `Fleet.Pilot.StepRunCompleter` — orchestrateur de fin-de-step-run PR-natif (`complete_pr/2`). **②.1d single-brique
  (sans workflow_map)** : producteur → `:review` (ouvre la PR **au nom de l'eng** via token de rôle + `request_review`
  des juges `:reviewer_roles` + **assigne l'humain** + unlock issue/PR) ; juge → `:reviewed` (poste la review
  native **signée par le juge** + unlock PR — le merge/rework est décidé par le poller sur l'état-PR agrégé).
  **Voix de l'eng (info SORTANTE)** : si le producteur rend un `summary` dans `submit_result` (extrait par
  `StepRunConsumer`, coercé `safe_str`), le système le poste en **commentaire PR `as_role` engineer** (livraison
  ET rework) — l'eng n'est plus muet sur la forge (jumeau sortant de l'anti-famine ; le brief l'élicite).
  **Blocked_dep** : si le producteur rend `blocked: true` (dépendance/info manquante), `StepRunConsumer` route vers
  `await_human` (motif = son `summary` + `lcars-awaits-human` + unlock → poller SKIP, l'humain tranche via l'arch)
  AU LIEU d'une publish vide (`:no_deliverable_commit` = wedge silencieux). Le brief dit à l'eng de marquer
  `blocked` plutôt que deviner à l'aveugle.
  Identité ②.1e via `Fleet.Credentials.RoleToken` (poste EN SON NOM ; token absent → fallback système loggué).
  (Legacy workflow_map multi-step : `complete/2` séquence §5 + intents `:advance`/`:promote`/`:rework`, conservé.)

Knobs : `:step_dispatch?` + `:poll_interval_ms` (step ; la forge `base_url` est l'unique config requise),
`:poll_repo` (override legacy/test mono-repo seulement — accepté par le Poller mais écrasé à chaque tick par la
découverte topic ; **pas** la source en prod), `:producer_role` (défaut `engineer`),
`:reviewer_roles` (juges PR, défaut data posé en `config/config.exs`), `:gatekeeper_role` (scelle les fusions,
défaut `gatekeeper`) — **les trois rôles ont leur AUTORITÉ UNIQUE dans `Fleet.Pilot.Roles`**
(`producer_role/1`, `reviewer_roles/1`, `gatekeeper_role/1` : config + overrides opts) ; `ProjectOnboard` et
`GatekeeperSeal` (qui re-exporte `gatekeeper_role/0`) délèguent ici, plus aucun défaut réécrit chez l'appelant, `:step_run_runner` (offload complétion, F067), `:wake_recovery` (seam recovery de wake,
défaut `&Fleet.Pilot.WakeRecovery.wake/3` ; MA-17 : le retour du wake est load-bearing → un kick injoignable
remonte `{:error,{:wake_unreached,_}}` au dispatch (tally honnête) / une telemetry au gatekeeper, jamais avalé).

**Supervision (`Application`)** : `:one_for_one` avec bornes explicites `max_restarts: 3 / max_seconds: 60`
(alignées sur les autres superviseurs d'app du runtime). `:one_for_one` (pas `:rest_for_one`) malgré l'ordre
de démarrage (Task.Supervisor + `IncidentRegistry` AVANT `Poller` + `StepRunConsumer`) : les enfants se réfèrent
par **nom global** (résolu à chaque appel), jamais par pid capturé à l'init → le redémarrage d'un singleton
ne nécessite pas la cascade. Chaque consommateur Bus (`StepRunConsumer`) se ré-abonne par construction : le
`Bus.subscribe()` vit dans `init/1`, qu'OTP rejoue à chaque restart (un consommateur redémarré n'est jamais
sourd ; contrat verrouillé par test côté `fleet_starfleet`).

Le superviseur démarre aussi, **inconditionnellement** (avant le rail step), `Fleet.Pilot.ForgeFinch` —
pool HTTP/1 dédié au `ForgeClient` avec `conn_max_idle_time: 30_000`. Le défaut Finch `:infinity` laisse une
connexion idle traîner jusqu'à ce que la forge la ferme côté serveur → le 1er appel après idle pend jusqu'au
`receive_timeout` (10s), et `create_issue` (qui enchaîne 3 appels : `create_issue` + `add_label`[GET+PUT])
cumulait ainsi jusqu'à ~30s. Inconditionnel car `create_issue` (côté `fleet_mcp`) appelle le `ForgeClient`
hors du rail Poller/StepRunConsumer. `Fleet.Pilot.ForgeClient.Transport.request/4` route via ce pool (`finch:`) et
**trace tout appel forge >1s** (`Logger.warning "ForgeClient … LENT …ms"`) — l'observabilité qui localise un appel forge lent
au run réel. Câblage du pool verrouillé par `forge_finch_test.exs` (sonde le process, pas un knob).

Le rail step démarre aussi `Fleet.Pilot.WorktreeSync` (AVANT Poller/StepRunConsumer) — sérialiseur qui
PROJETTE le livrable sur le clone local après merge. Au merge terminal, `origin/main` avance sur la forge
mais le worktree `main` de `/home/projects/<name>` (« le livrable » de `ProjectOnboard`) reste figé à
l'onboarding ; `GatekeeperSeal.seal_and_merge` (point UNIQUE des deux chemins de merge) lui caste
`sync(repo)` → `fetch` + `reset --hard origin/main`. **Pourquoi un process** : la sérialisation. Les deux
déclencheurs de merge — poller (`promote_pr`) et StepRunConsumer (`StepRunCompleter.promote`, offloadé en `Task`) —
peuvent tourner en même temps ; deux `reset --hard` sur le même worktree corrompent l'index. Le bail
« 1 pipeline/repo » est un invariant LOGIQUE du poller, pas un verrou disque → le GenServer ferme la race
par construction (un `git` à la fois). Best-effort et convergent (le merge fait foi ; un alignement raté =
disque en retard, jamais une perte — le livrable est sur la forge). Le git borné est factorisé dans
`Fleet.Pilot.GitOps` (partagé avec `ProjectOnboard`). Verrouillé par `worktree_sync_test.exs` (alignement
git réel + sérialisation) et le câblage merge→projection (`gatekeeper_seal_worktree_test.exs`).

## Onboarding projet (Rail 1 — « idée → le projet existe »)

`Fleet.Pilot.ProjectOnboard` — `onboard/2` : crée mécaniquement un projet en répliquant l'archi
dual-dir de LCARS (un repo, **deux worktrees**) :

- `/home/projects/<name>` → worktree `main` (livrable, push origin) ;
- `/home/projects.work/<name>` → worktree **orphan** `work/ops` (plans/backlog/ops).

Toutes les ops git de l'onboarding (clone/worktree/commit/push) passent par `Fleet.Credentials.Shell.git` :
bornées par construction (process-group dédié, tué entier à la deadline mur) — aucun `System.cmd("git", …)`
nu ne subsiste, et un clone/push réseau qui pend ne fige plus l'orchestration ni ne laisse fuir un process
git porteur du token forge.

**Sceau d'admission (frontière d'entrée dans la machine).** Le topic `lcars-fleet-<human>` rend le repo
**découvrable**, mais il est mutable (un propriétaire de repo peut se l'auto-poser) → le topic seul
n'**admet** pas. `register_for_fleet` pose donc, en plus du topic, le **marqueur d'admission**
`[lcars-onboarded:<human>]` via `ForgeClient.post_onboard_marker/3` : une issue système ouverte **sous le
compte du token** (= le bot système). Le poller n'admet un repo que s'il porte ce marqueur **vérifié
bot-authored** (`ForgeClient.admitted?/3`, `system_authored?` côté issue — MÊME primitif de confiance que
les marqueurs route/step_run/result). Non forgeable : un humain ordinaire n'a pas le token système pour poster
SOUS l'identité du bot. Pas de crypto, pas de registre — fail-closed (`admitted?` rend `false` sur doute).

Séquence : `ForgeClient.create_repo` (org `fleet`, `auto_init`) → `git clone main` → scaffold (README,
.gitignore, .editorconfig, docs/spec.md) → commit+push `main` → `git worktree add --orphan -b work/ops`
→ scaffold (backlog.md, scratchpad.md, plans/) → commit+push `work/ops` → **`register_for_fleet`** (topic +
**marqueur d'admission système** + collaborateur write humain) → **`lock_main`** (②.1d) : donne
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
