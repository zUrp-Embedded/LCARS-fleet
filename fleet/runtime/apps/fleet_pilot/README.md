# fleet_pilot

**Date** : 2026-05-26
**Dernière révision** : 2026-07-05 (éclatement god-modules C1 — chaque concern séparable en sous-module à frontière blindée (structs `Seams` étroits, `@enforce_keys`), API publiques inchangées : StepRunConsumer→`GateEngine`/`TerminalEscalation`/`StepRunBuild` (1165→757 l) ; StepRunCompleter→`Texts`/`Emissions` (796→~710 l ; intent-routing REFUSÉ : seam bidirectionnel) ; Poller→`Backoff`/`Lease` (785→~600 l) ; ReviewLifecycle→`RoleDispatch`/`Remediation` (529→211 l) ; ProjectOnboard→`Scaffold` ; Transport→`ForgeClient.UrlSafe` ; IncidentRegistry→`Escalation` ; Spawn→`Naming`) (dedup B5 : `Fleet.Pilot.Offload` — squelette d'offload unique des 2 consumers Bus ; `Opts.maybe_put` remplace les wrappers à clé figée `maybe_put_project|repo_id` de Spawn ; prédicat de confiance `system_authored?` UNIQUE dans ForgeProtocol — la copie issue-side de ForgeClient.Repo délègue ; `Verdict.review_event/1` = table unique token→review-event des 2 vocabulaires decision/intent ; signature gatekeeper internalisée dans `GatekeeperSeal.seal_and_merge` via le writer unique `as_gatekeeper/1` — appelants en forge_opts bruts, ArchEscalation aligné) (atomisation Poller : extraction du cluster « réconciliation des verrous orphelins » `Poller.Reconciliation` — `reconcile/5` (lit 5 seams, rend le set de suspects), struct `%Reconciliation.Seams{}` 5 seams, grâce 2-tick + union cross-repo restées au cœur, 835→712 l ; atomisation StepDispatcher : extraction du cycle de vie REVIEW `ReviewLifecycle` — aiguillage verdicts + rework/conflit + promotion (`dispatch_by_verdicts`/`dispatch_rework`/`dispatch_conflict_resolution`/`promote_pr`), struct `%ReviewLifecycle.Ctx{}` + captures partagées `route_for`/`tag_err`, 848→469 l ; extraction feuille de spawn SINGLE-AUTHORITY `Spawn` — spawn_step/pod_id/serialize_scope/opts-builders, struct `%Spawn.Seams{}` 6 seams, 1110→848 l ; + atomisation ForgeClient : Transport + ForgeProtocol + Jury/Repo/Files, 1652→786 l ; extraction `IncidentConsumer` hors StepRunConsumer) (resync D2 contre le code : `decide/1` porte pure, routeless→onboarding, blocked→`lcars-awaits-arch`, catalogue knobs complet, modules feuilles inventoriés)
**Statut** : actif — service d'auto-orchestration issues Gitea (ring 1 client du core).
**Référencé par** : `beyond_#4/01_architecture/topologie-ring.md` §Élagage

Service d'auto-orchestration issues Gitea (M-033 backlog, doctrine
`beyond_#4/01_architecture/topologie-ring.md` §"Élagage" : **client du
core ring 1, pas core**).

Découvre ses projets par topic (`lcars-fleet-<humain>`) et spawn le rôle
du step courant via le rail forge-state-machine décrit ci-dessous (mode **step**) :
la forge EST la machine à états (label de route gravé sur le issue). Le
catalogue déclaratif `forge-routing.yaml` (axes `type:` × `state:` × `assignee`)
a été SUPPRIMÉ avec le rail AutoDispatcher legacy — plus aucun code ne le lisait.

> **OBSOLÈTE — dispatch legacy RETIRÉ.** L'ancien chemin invoquait
> `Fleet.Workflow.start_pipeline/2` (moteur RAM `Fleet.Workflow.Executor`) avec
> le issue_id + le brief (issue.body) comme `ask`, et posait un label
> `lcars-dispatched` (lock atomique) pour l'idempotence inter-restart. Ce moteur
> RAM a été **supprimé** (②.3 / BL-050 — cf. `fleet_workflow` `Application`,
> `start_pipeline`/`Executor` n'existent plus) et le `AutoDispatcher` retiré à
> F-09. Le dispatch actuel passe **uniquement** par le mode step (§ ci-dessous).

## Mode step (forge-state-machine — A2/A3, actif)

Le mode **step** (la forge EST la machine à états : issue **assignée** à l'humain owner, non
verrouillée → spawn le rôle du **step courant** de sa route, dérivé de la POSITION workflow_map ;
l'**assignee = l'humain**, point fixe — DN §1)
double puis remplace le dispatch legacy ci-dessus. Activé par `:step_dispatch?` + la forge `base_url`
(`:forge[:base_url]` / `FORGE_BASE_URL`) — c'est la **seule** garde fail-loud du boot step
(`Fleet.Pilot.Application.step_children!`) : sans `base_url`, ni découverte par topic ni push per-step-run.
`:poll_repo` n'est **plus** une condition d'activation (et n'a plus aucun lecteur, cf. § Knobs) :
la découverte des repos se fait par topic (`lcars-fleet-<human>`), pas par repo fixe, et le repo+remote de
chaque step_run voyagent dans l'event `pod.completed`. Submodules :

- `Fleet.Pilot.StepDispatcher` — `decide/1` (porte PURE : verrou `lcars-in-flight`/`lcars-awaits-arch`
  → `{:skip, reason}`, sinon `:engage` — le rôle n'est PAS décidé ici) + `dispatch_issue/2` (sur
  `:engage` : résout projet+route AVANT toute écriture forge ; issue **routeless** → onboarding système
  — grave la workflow_map de délégation `:delegation_workflow_map` (défaut `brief-gate`) puis DÉFÈRE au
  tick suivant ; **routée** → `workflow_map_role` dérive `{role, profile, step_spec}` de la POSITION
  workflow_map (pas de producteur en dur ; route absente à ce point = fail-loud `:unrouted`, jamais
  l'eng en silence) — puis ordre canonique du spawn verrou → pod → enqueue → wake, `Spawn.spawn_step`). Les **juges**
  sont dispatchés PR-driven via `dispatch_review/2` (②.1d, **PR = machine à états**, DN §1.4-1.5,
  sans branch-protection — LCARS agrège, interim) : reviewers en attente → spawn le prochain juge (un à
  un, sérialisé par le verrou PR ; clone la **feature-branch** pour voir le diff) ; round terminé +
  verdict agrégé `:changes_requested` → rework du producteur (**borné MA-06** : compteur forge-natif
  `ForgeClient.count_change_request_rounds/3` = nb REQUEST_CHANGES ; > budget `:max_pr_rework_rounds`
  (défaut 2) → **escalade arch** au lieu de re-spawn → fin du churn infini) ; `:approved` → **merge `rebase` scellé
  `:gatekeeper_role`** via `Fleet.Pilot.GatekeeperSeal` (**sceau UNIQUE** partagé avec `StepRunCompleter.promote`,
  F-arch-MCP : comment gatekeeper + merge signé gatekeeper, plus de fork où l'escalade mergeait en token
  système ; la signature gatekeeper est posée EN INTERNE par `seal_and_merge` — writer unique
  `GatekeeperSeal.as_gatekeeper/1`, les appelants passent les `forge_opts` bruts et ne peuvent plus
  oublier/forker la signature ; LINÉAIRE + gère un `main` avancé sous une PR parallèle — multi-issue, cf. `ForgeClient.merge_pr`
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
      merge récurrent) posent le **commentaire gatekeeper dédupliqué** (signé via le writer unique
      `GatekeeperSeal.as_gatekeeper/1` + `dedup_signature`) + le
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
      reprovision cold in-place d'un pipe ready). Les builders d'opts / naming vivent dans le sous-module
      `Fleet.Pilot.StepDispatcher.Spawn.Naming` (`rc_name/2`, `feature_slug/1` purs, `maybe_put_route/2` —
      2 clés couplées — et `resolve_repo_id/3`, quasi-purs, partagés par les deux flux ; les poses à UNE clé
      `:project`/`:repo_id` passent par `Fleet.Pilot.Opts.maybe_put/3` aux sites d'appel).
      Le cœur DÉCIDE (route/rôle/verdict), Spawn EXÉCUTE. **Frontière blindée** : `spawn_step/9` reçoit
      un struct `%Spawn.Seams{}` (les 6 seams `forge`/`spawner`/`task_queue`/`repo`/`forge_opts`/
      `wake_recovery`, `@enforce_keys` → un accès hors-6-seams ne compile pas), jamais le `ctx`/`opts`
      entier ; chacun des 2 callers construit le struct à son site. `safe_kill/2` reste public (partagé
      avec `ReviewLifecycle.promote_pr`, die-on-promote — une seule copie, pas de fork).
    - `Fleet.Pilot.StepDispatcher.ReviewLifecycle` — **cycle de vie REVIEW (PR)**. `dispatch_review/2`
      (PUBLIQUE, contrat poller) RESTE au cœur (gate PR `in-flight`/`awaits-arch` + construction du `ctx` +
      lecture `pr_review_state`) et DÉLÈGUE l'aiguillage à `dispatch_by_verdicts/5` (point d'entrée). Le module
      porte l'**aiguillage** (juge pending → spawn ; tous décisifs + un `:changes_requested` → rework ;
      tous approuvé → merge ; aucun demandé → `:no_verdict`) + la **promotion** (`promote_pr` = sceau
      `Fleet.Pilot.GatekeeperSeal` + merge rebase + die-on-promote de l'eng — reste ICI : son error-path
      conflit ré-entre dans l'aiguillage). Deux sous-modules :
        - `ReviewLifecycle.RoleDispatch` — feuille d'EXÉCUTION partagée (prépare + spawn UN rôle sur la PR :
          juge/rework/résolution ; clone-base vs gate-base, identité pod par scope, gate `:role_busy`,
          briefs via BriefBuilder). C'est la coupe qui rend le graphe ACYCLIQUE : aiguillage ET remédiation
          convergent dessus (couper aiguillage↔rework en deux aurait créé un cycle — le rework rappelle le
          spawn du producteur).
        - `ReviewLifecycle.Remediation` — remédiation BORNÉE (`dispatch_rework` borné MA-06 +
          `dispatch_conflict_resolution` borné IncidentRegistry ; `encode_pr_letters/1` (pur, base-26
          digit-free) vit ICI, consommé par la clé d'incident). DÉCIDE, puis redescend sur RoleDispatch
          (re-spawn) ou ArchEscalation (mur humain).
      **Dépendance uni-directionnelle** (ReviewLifecycle → `Remediation`/`RoleDispatch` →
      `Spawn`/`ArchEscalation`/`GatekeeperSeal` → ø ; ne nomme JAMAIS `StepDispatcher` → pas de cycle) :
      les sous-modules re-construisent `Spawn.Seams`/`ArchEscalation.Seams` au site d'appel de chaque feuille. **Frontière blindée** : reçoit un struct `%ReviewLifecycle.Ctx{}` (les seams
      `forge`/`loader`/`spawner`/`task_queue`/`resolver`/`repo`/`forge_opts`/`wake_recovery`/`opts`,
      `@enforce_keys`), jamais une map nue. Les helpers PARTAGÉS avec le flux issue (`route_for/4` lecture de
      route + `tag_err/2` tagging d'erreur) RESTENT au cœur et sont threadés par CAPTURE dans le `Ctx`
      (`route_reader`/`err_tagger`, exactement comme `resolver`/`wake_recovery`) — une seule copie (pas de
      fork), la capture est créée au cœur (pas de référence remontante → pas de cycle).
- `Fleet.Pilot.BriefBuilder` — **autorité du FORMAT des briefs** : worker / judge / brief-review /
  rework / conflit + instructions de voix de l'eng. `StepDispatcher` CHOISIT quel brief selon l'état forge
  (`build_brief/9` dispatche sur `brief_kind`/`judge_target`), `BriefBuilder` le FORME. La **judge-ness**
  est fail-loud (kind/target hors-vocab → `raise` ; un juge ne reçoit JAMAIS un corps d'issue exécutable) ;
  le brief juge est **désamorcé** via `Fleet.Workflow.GateBrief` (critère rendu comme contexte). `forge` =
  arg injecté (seam). API publique : `build_brief/9`, `rework_brief/6`, `resolve_conflict_brief/6`.
- `Fleet.Pilot.Poller` — **DÉCOUVRE** ses repos par topic (`lcars-fleet-<human>`) PUIS **ADMET** uniquement
  ceux scellés système (`ForgeClient.admitted?` — marqueur d'onboarding bot-authored ; le topic mutable seul
  ne suffit plus, cf. § Onboarding « sceau d'admission »). Sur chaque repo admis : scanne, lit la **route-comment**
  (`[lcars-route:workflow_map:step]`, gravée par `create_issue` = la state-machine de routing) → dispatche le rôle du
  step (`workflow_map_role`). Bail « 1 pipeline/repo » sur la route (engagé = `in-flight` OU route avancée au-delà du
  1er step). Routing par label retiré (`type:*` = visu seulement). Sans route → onboarding système :
  la workflow_map de délégation (défaut `brief-gate`) est gravée et le dispatch DÉFÉRÉ au tick suivant
  (pas de fallback producteur silencieux).
  **Bail fail-closed (2 invariants)** : (1) le bail se prend dès qu'un pipeline est DÉMARRÉ (verrou posé +
  pod spawné), jamais sur le succès d'une étape postérieure — un dispatch qui rend `{:error,{:wake_unreached,_}}`
  (verrou+pod+brief en place, seul le réveil tmux a raté) PREND le bail intra-tick (sinon un 2e issue du même
  repo démarrerait un 2e pipeline) ; l'anomalie reste comptée en `errors`/`last_tally_errors`, jamais avalée.
  (2) l'engagement se lit sur la ROUTE (append-only, robuste), pas sur le chargement de la workflow_map : un échec
  TRANSITOIRE de workflow_map (réseau/forge nil) sur un pipeline routé le classe ENGAGÉ (bail TENU, fail-closed) —
  le dispatch de son step fail-loud si la workflow_map manque, mais le bail ne se libère pas.
    - `Fleet.Pilot.Poller.Reconciliation` — cluster **IMPUR** « réconciliation des verrous orphelins » extrait
      du tick loop (frontière nette : le reste du poller = boucle irréductible). Un verrou `lcars-in-flight`
      ORPHELIN (pod reapé par le PodWarden — process retiré, label forge survivant) bloquerait la brique pour
      TOUJOURS (`dispatch_*` skip `:in_flight`) → ce module compare les verrous forge aux refs qu'un pod VIVANT
      possède réellement (refs REPO-QUALIFIÉES `{repo, :issue|:pr, n}` : pas de collision cross-repo sur le seul
      numéro) et **réclame** (retire le label) les orphelins CONFIRMÉS → re-dispatch au prochain tick. **API** :
      `reconcile(issues, pulls, pr_issue_ids, prior_suspects, %Seams{}) :: MapSet.t()` — LIT 5 seams, N'ÉCRIT rien
      (rend le nouveau set de suspects). **Fail-safe** : si l'énumération des pods échoue (`:error`), ne réclame
      RIEN (jamais déverrouiller à l'aveugle). **Frontière blindée** : `%Seams{}` (`@enforce_keys`
      `forge`/`spawner`/`task_queue`/`repo`/`forge_opts` — accès hors-5-seams ne compile pas), le caller résout
      les défauts prod (`spawner || Fleet.Spawner`) à SON site. La **grâce 2-tick** (`prior_suspects`) et
      l'**agrégation cross-repo** (`MapSet.union` des suspects de tous les repos du tick) = état CROSS-TICK →
      RESTENT au cœur (`do_poll`/`step_do_poll`). Ne nomme jamais `Poller` (pas de cycle).
    - `Fleet.Pilot.Poller.Backoff` — timing PUR du tick (extrait) : `jitter/1` (±10 %, plancher 1 s,
      anti thundering-herd) + `next_delay/2` (backoff exponentiel ×2^min(streak,10), capé 5 min). Le
      GenServer garde l'EFFET (`schedule/1` = `Process.send_after`) et le rescue de boucle (`safe_poll`).
    - `Fleet.Pilot.Poller.Lease` — **bail repo-sérialisé** (extrait, le cœur métier du chemin issues) :
      `process_issues/4` classe chaque issue (ENGAGÉ = in-flight ou route avancée → tient le bail ;
      EN FILE → démarre seulement si bail libre) puis dispatche sous ce bail — les 2 invariants fail-closed
      du bail (pris sur `wake_unreached`, lu sur la ROUTE pas sur le chargement de workflow_map) vivent ICI,
      ainsi que l'escalade G6 d'une workflow_map durablement illisible (IncidentRegistry, dédup = throttle).
      Possède le **vocabulaire du tally** (`zero_tally/0`, `merge_tally/2` — la monnaie d'observabilité du
      tick). **Frontière blindée** : `%Lease.Seams{}` (`@enforce_keys`
      `forge`/`repo`/`forge_opts`/`workflow_map_loader`/`incident_fun`, défauts prod résolus par le poller
      AU site de construction). Le chemin pulls (`step_process_pulls`, non gardé par le bail), le re-kick
      awaits-arch throttlé (couplé à `poll_count`) et l'état cross-tick restent au cœur.
- `Fleet.Pilot.Opts` — util pur **source unique** de l'idiome `maybe_put/3` (pose une clé opts SI la valeur
  n'est pas nil), partagé par `StepRunConsumer` / `ForgeClient.Transport` / `Poller` (builders d'opts+seams)
  et par les builders de spawn_opts de `StepDispatcher`/`ReviewLifecycle` (`:project`, `:repo_id`).
- `Fleet.Pilot.Offload` — util **source unique** de l'idiome d'offload supervisé des consumers Bus
  (`async(supervisor_name, fun, {consumer, conséquence})` : `Task.Supervisor.start_child` →
  `{:ok, :offloaded}` | échec de spawn fail-loud loggé + `{:error, {:offload_failed, _}}`). Chaque
  consumer (`StepRunConsumer`, `IncidentConsumer`) garde SON superviseur (blast-radius séparé) et SON
  message de conséquence (« complétion perdue » vs « incident NON gravé ») ; seul le squelette est partagé.
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
    - `Fleet.Pilot.ForgeClient.Transport` — moteur HTTP/config/pagination + login système (zéro
      protocole forge) ; `ForgeClient` l'**`import`e**.
    - `Fleet.Pilot.ForgeClient.UrlSafe` — **encodage sûr des segments d'URL** (extrait de Transport) :
      `encode_seg/1`/`encode_repo/1`/`encode_path/1`, cluster PUR de sécurité **path-traversal** (un
      composant `..`/`.` est percent-encodé `%2E%2E` — le verrou du vecteur `owner/../admin` ; `/`
      structurels préservés, `/` injectés inertes). Importé par ForgeClient/Repo/Jury/Files ; testé par
      `url_safe_test.exs`.
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
      `review_event/1`, `judge_review_body/2`, `eng_summary/1` — trace verdict durable, corps de
      review, voix de l'eng). `review_event/1` = **TABLE UNIQUE** token→review-event fail-closed, où
      convergent les DEUX vocabulaires disjoints (gate-decision string `"continue"`→approve côté
      `StepRunConsumer` ; intent atom `:advance`/`:promote`→approve côté `StepRunCompleter` ; catch-all
      partagé →request_changes, jamais d'approbation par omission). **Un seul module** (décodage+rendu
      couplés : `eng_summary` s'appuie sur
      `unwrap_worker_envelope`, primitif partagé). Vocab canon via l'AUTORITÉ UNIQUE `Fleet.Workflow.GateDecision`
      (`@gate_decisions` non recopié). Le cœur décisionnel stateful (`apply_verdict`/`resume_gate`/
      `complete_business_step_run`) reste dans le module racine (la décision de gate vit dans `GateEngine`).
    - `Fleet.Pilot.StepRunConsumer.GatekeeperEscalation` — cluster **IMPUR** « escalade gatekeeper »
      (async-out) extrait du consumer : `dispatch/7` (enqueue le brief d'éval au gatekeeper permanent
      + kick + télémétrie `[:fleet_pilot, :step_run_consumer, :gatekeeper_kick_unreached]`). Appelé par
      le `GateEngine` sur le chemin `{:dispatch_gatekeeper, _}` (seams transmis via `Seams.escalation`) ; rend le contrat étroit
      `{:ok, corr} | {:error, reason}` (fail-loud : pas de gatekeeper booté / enqueue raté →
      `{:error, _}`, jamais un pass silencieux). **Frontière blindée** : ne reçoit PAS le `state`
      entier mais un struct `%GatekeeperEscalation.Seams{}` (les 4 seams
      `task_queue`/`spawner`/`gatekeeper_pod_id_fun`/`wake_recovery`, `@enforce_keys` → un accès à un
      autre champ de state ne compile pas). Le cœur décisionnel (`resume_gate`/`apply_verdict`) reste
      dans le module racine.
    - `Fleet.Pilot.StepRunConsumer.GateEngine` — **moteur de DÉCISION de gate** (extrait) : `resolve_next/3`
      (gate du step fini → avancer / rebond borné / verdict-juge / escalade gatekeeper), `advance_intent/3`
      (SOURCE UNIQUE de l'intent terminal — « un producteur ne merge JAMAIS seul » : producteur → `:review`,
      juge-workflow_map → `:promote` ; partagée chemin gate `:pass` ET chemin verdict `continue`),
      `producer?/2` (autorité du classement producteur/juge). Rend une INTENTION, le consumer agit.
      **Frontière blindée** : `%GateEngine.Seams{}` (7 lectures :
      `loader`/`deliverable_mode_fun`/`max_rework_rounds`/`repo`/`forge_opts`/`forge_client`/`escalation`).
    - `Fleet.Pilot.StepRunConsumer.TerminalEscalation` — **mur humain** (extrait) : `freeze_to_arch/5`
      = LE geste unique (await_arch : comment adressé-arch + `lcars-awaits-arch` + unlock LOAD-BEARING →
      fin du churn G2, PUIS kick arch best-effort), partagé par `escalate_terminal_error` (rework épuisé /
      budget illisible / aval humain requis — classés par `terminal_escalate?/1`), `escalate_blocked_producer`
      (flag `blocked` du producteur, motif = sa voix `summary`) et les verdicts fail-closed d'`apply_verdict`.
      `kick_architect/1` public (aussi utilisé au close `abandon`). **Frontière blindée** :
      `%TerminalEscalation.Seams{}` (5 champs, dont la closure `run_completion` — la discipline sync/offload
      RESTE au consumer, l'escalade ne choisit pas son mode d'exécution).
    - `Fleet.Pilot.StepRunConsumer.StepRunBuild` — **construction du step_run PR-natif** (extrait) :
      `build/5` classe le rôle qui finit (producteur git_native → `feature_branch` + `deliverable_opts` +
      voix eng ; juge payload → branche producteur résolue via `list_open_pulls`+`parse_feature_branch`,
      `review_event` fail-closed + `review_body`) et assemble la map que `complete_pr` route. Appelé DANS
      la closure offloadée (E4 : l'I/O de résolution ne bloque pas la mailbox). **Frontière blindée** :
      `%StepRunBuild.Seams{}` (6 lectures : `repo`/`remote`/`role_emails`/`deliverable_mode_fun`/
      `forge_client`/`forge_opts`).
- `Fleet.Pilot.IncidentConsumer` — consumer Bus **séparé** des events d'**échec** de pod (`pod.failed`/
  `wake.failed`, source `:spawner`) → `IncidentRegistry` (note 1er / escalade récurrent ; wake récurrent =
  `:sp_suspect`). **Stateless**, sa propre `Task.Supervisor` d'offload (`:runner` défaut nil→sync, prod
  `&offload_async/1`). Extrait du `StepRunConsumer` : concern distinct de la complétion → blast-radius isolé
  (un burst d'échecs ne partage pas la mailbox de la fin-de-step-run) et nom du StepRunConsumer rendu honnête.
  Côté registre, l'**escalade sysadmin** (ouverture de l'issue `error_system`, retry sans assignee,
  kind_describe) vit dans `Fleet.Pilot.IncidentRegistry.Escalation` — acte STATELESS (aucune lecture du
  GenServer), extrait du registre qui garde la MÉMOIRE (WAL + sync forge) ; `IncidentRegistry.escalate/5`
  reste en façade (defdelegate) pour WakeRecovery et les consumers.
- `Fleet.Pilot.StepRunCompleter` — orchestrateur de fin-de-step-run PR-natif (`complete_pr/2`). **②.1d single-brique
  (sans workflow_map)** : producteur → `:review` (ouvre la PR **au nom de l'eng** via token de rôle + `request_review`
  des juges `:reviewer_roles` + **assigne l'humain** + unlock issue/PR) ; juge → `:reviewed` (poste la review
  native **signée par le juge** + unlock PR — le merge/rework est décidé par le poller sur l'état-PR agrégé).
  **Voix de l'eng (info SORTANTE)** : si le producteur rend un `summary` dans `submit_result` (extrait par
  `StepRunConsumer`, coercé `safe_str`), le système le poste en **commentaire PR `as_role` engineer** (livraison
  ET rework) — l'eng n'est plus muet sur la forge (jumeau sortant de l'anti-famine ; le brief l'élicite).
  **Blocked_dep** : si le producteur rend `blocked: true` (dépendance/info manquante), `StepRunConsumer`
  escalade via `TerminalEscalation.escalate_blocked_producer` → `freeze_to_arch` (motif = son `summary`,
  commentaire adressé-arch + `lcars-awaits-arch` + unlock via `StepRunCompleter.await_arch` → poller SKIP,
  l'humain tranche via l'arch) AU LIEU d'une publish vide (`:no_deliverable_commit` = wedge silencieux).
  Le brief dit à l'eng de marquer `blocked` plutôt que deviner à l'aveugle.
  Identité ②.1e via `Fleet.Credentials.RoleToken` (poste EN SON NOM ; token absent → fallback système loggué).
  (Legacy workflow_map multi-step : `complete/2` séquence §5 + intents `:advance`/`:promote`/`:rework`, conservé.)
  Deux sous-modules extraits : `StepRunCompleter.Texts` (wording PAR DÉFAUT — `pr_body/2` avec `Closes #N`,
  `review_body/2`, `step_run_comment/2` — générateurs purs, les overrides de l'appelant priment) et
  `StepRunCompleter.Emissions` (émissions ANNEXES best-effort de la livraison producteur : voix eng PR+issue
  `as_role`, slot-freeze `deliverable.published` — un échec ne casse JAMAIS la complétion, d'où la coupe).
  Le routage par intent (`route/3` ×5) reste DANS le completer : il rappelle la primitive publique `promote`
  et partage `unlock`/`post_route_if_present` (autorités uniques) avec la séquence maison — l'extraire
  créerait un seam bidirectionnel (mauvaise frontière, refus argumenté).
- `Fleet.Pilot.GatekeeperSeal` — **sceau de fusion UNIQUE** (`seal_and_merge/6` : commentaire de fin
  honnête + merge rebase signé gatekeeper, writer unique `as_gatekeeper/1`), partagé par les deux points
  de merge (`ReviewLifecycle.promote_pr`, `StepRunCompleter.promote`) ; après merge, caste la projection
  du clone local à `WorktreeSync.sync(repo)` (seam `:worktree_sync`).
- `Fleet.Pilot.Roles` — accesseur UNIQUE des rôles de l'atelier : `producer_role/1` (défaut
  `"engineer"`), `reviewer_roles/1` (fail-loud, data `config/config.exs`), `gatekeeper_role/1` (défaut
  `"gatekeeper"`), `architect_pod_id/1` (défaut `"permanent-architect"`) — config + override opts,
  aucun défaut réécrit chez l'appelant.
- `Fleet.Pilot.WorkflowMapNav` — navigation **PURE** dans une workflow_map (chaînage forge-driven des
  steps, stateless) : keyée par NOM de step (un même rôle peut tenir plusieurs steps), chaîne linéaire
  (0/1 successeur ; DAG → `{:error, :dag_not_supported}`) ; `first_step`/`step_role`/`safe_load` —
  l'appelant passe la workflow_map déjà chargée (sortie `Fleet.Workflow.Loader`).
- `Fleet.Pilot.IssueId` — source UNIQUE du format `issue_id` step-mode `"issue-<n>"`
  (`compose/1`/`parse/1`) : corrèle un pod à son issue forge de l'enqueue à la fin-de-step-run
  (writer `StepDispatcher`, parser `StepRunConsumer` — qui délègue).
- `Fleet.Pilot.PodId` — id de pod sémantique DÉTERMINISTE, **repo-scopé** (clé GLOBALE : Registry,
  broker, pod_dir, tmux) : `for_issue`/`for_pr` construisent, `parse_ref/2` ancre (réconciliation des
  verrous) ; même `(repo, n, role)` → même id (un re-dispatch retombe sur le pod vivant pour le
  re-briefer) ; path-safe (contrat `Fleet.Spawner.valid_pod_id?/1`).
- `Fleet.Pilot.WakeRecovery` — durcissement de `Fleet.Spawner.wake_pod/1` (`wake/3`) : incident déjà au
  registre → escalade DIRECTE (pattern → root-cause) ; 1er coup → re-roll (re-spawn + re-wake) ; re-wake
  OK → récupéré + gravé au registre ; re-roll raté → escalade immédiate (issue système `error_system`,
  assignee sysadmin).
- `Fleet.Pilot.IncidentRegistry` — mémoire PERSISTANTE cross-session des incidents système (GenServer,
  démarré inconditionnellement dans le rail step) : `seen_before?` = lookup RAM (tient un burst),
  `note` = upsert sérialisé + WAL local atomique + sync forge ASYNC débouncé (branche `work/ops`, merge
  bidirectionnel, fail-loud — jamais de perte) ; `record_or_escalate/4` ; l'escalade sysadmin vit dans
  le sous-module `Escalation` (`escalate/5` reste en façade defdelegate).
- `Fleet.Pilot.GitOps` — git borné, source unique des ops git FS du pilot (`run/2` : borne réelle
  `Fleet.Credentials.Shell.git`, token forge en env jamais sur l'argv, identité de commit, retour
  typé) — partagé par `ProjectOnboard` (clone/scaffold/commit/push) et `WorktreeSync` (fetch/reset).

### Knobs (app env `:fleet_pilot`)

- `:step_dispatch?` — défaut `false` ; `true` démarre le rail step (env `LCARS_PILOT_STEP=true`, posé
  par défaut par `bin/fleet_v2`). Garde fail-loud au boot : la forge `base_url` est l'unique config
  requise (raise sinon, cf. `Application.step_children!`).
- `:poll_interval_ms` — défaut `30_000` (env `LCARS_PILOT_POLL_INTERVAL_MS`).
- `:forge` — keyword forge : `base_url` (env `FORGE_BASE_URL`, obligatoire step-mode), `token`
  (env `FORGE_TOKEN`) / `token_file` (env `FORGE_TOKEN_FILE`, fallback `~/.gitea_token`),
  `req_options` (tests, passé à `Req.new/1`). Résolu à CHAQUE appel par `Transport.resolve_config/1`
  (merge avec les opts d'appel).
- `:forge_bot_login` — login du compte SYSTÈME (les marqueurs route/step_run/result ne font foi que
  bot-authored). Pas de défaut : absent → dérivé une fois via `GET /user` puis caché (env
  `FORGE_BOT_LOGIN`).
- `:poll_repo` — **posé** par `config/runtime.exs` (env `LCARS_PILOT_POLL_REPO`) mais **plus aucun
  lecteur** dans le code : la découverte est par topic, et l'override mono-repo réel est l'opt d'init
  `:repo` du Poller (seam test/legacy, écrasé à chaque tick) — NON câblé sur cette config.
- `:producer_role` (défaut `"engineer"`), `:reviewer_roles` (`fetch_env!` fail-loud — data posée en
  `config/config.exs` : `["qualifier", "reviewer"]`), `:gatekeeper_role` (défaut `"gatekeeper"`),
  `:architect_pod_id` (défaut `"permanent-architect"`, id posé par `PermanentBoot`) — **AUTORITÉ
  UNIQUE `Fleet.Pilot.Roles`** (config + overrides opts) ; `ProjectOnboard` et `GatekeeperSeal` (qui
  re-exporte `gatekeeper_role/0`) délèguent ici, plus aucun défaut réécrit chez l'appelant.
- `:delegation_workflow_map` — défaut `"brief-gate"` : la workflow_map gravée à l'onboarding d'une
  issue routeless (data-catalogue, pas un nom magique en dur).
- `:step_run_write_spacing_ms` — défaut `2000` (gap inter-écritures forge du `StepRunCompleter`) ;
  posé à `0` par `config/test.exs` (tests rapides et déterministes).
- `:worktree_sync` — défaut `Fleet.Pilot.WorktreeSync` (seam test du `GatekeeperSeal` : le process de
  projection casté après merge).
- `:incident_registry_repo` (défaut `"fleet/lcars"`), `:incident_registry_branch` (défaut
  `"work/ops"`), `:incident_registry_path` (défaut `"work/system-incidents.json"`),
  `:incident_registry_wal_path` (défaut : `Fleet.Layout.state_dir()/system-incidents.json`),
  `:incident_registry_author` (défaut `LCARS-starfleet` + email de rôle `ForgeIdentity`),
  `:incident_registry_max_entries` (défaut `500`, cap du registre) — backing store du
  `IncidentRegistry`.
- `:system_issue_repo` (défaut `"fleet/lcars"`), `:system_issue_label` (défaut `"error_system"`),
  `:system_issue_assignee` (défaut `"starfleet"`) — cible de l'escalade sysadmin
  (`IncidentRegistry.Escalation`).

Opts d'init (seams process, PAS des clés d'app env) : `:step_run_runner` (StepRunConsumer — offload
complétion F067, défaut `nil` → sync ; prod = `&offload_async/1` posé par l'Application),
`:wake_recovery` (défaut `&Fleet.Pilot.WakeRecovery.wake/3` ; MA-17 : le retour du wake est
load-bearing → un kick injoignable remonte `{:error,{:wake_unreached,_}}` au dispatch (tally honnête) /
une telemetry au gatekeeper, jamais avalé), `:max_rework_rounds` (StepRunConsumer, défaut `2` — budget
du rebond de gate), `:max_pr_rework_rounds` (flux review, défaut `2` — budget MA-06),
`:repo`/`:start_tick?` (Poller), `:subscribe` (consumers Bus, défaut `true` — tests : `false` + envoi
manuel).

Hermétisme test : pas de knob `start_*` dédié — le rail step est OFF par défaut (`:step_dispatch?`
absent → `step_children` = `[]`, app inerte) ; `config/test.exs` pose uniquement
`step_run_write_spacing_ms: 0`.

**Supervision (`Application`)** : `:one_for_one` avec bornes explicites `max_restarts: 3 / max_seconds: 60`
(alignées sur les autres superviseurs d'app du runtime). `:one_for_one` (pas `:rest_for_one`) malgré l'ordre
de démarrage (Task.Supervisor + `IncidentRegistry` AVANT `Poller` + `StepRunConsumer`) : les enfants se réfèrent
par **nom global** (résolu à chaque appel), jamais par pid capturé à l'init → le redémarrage d'un singleton
ne nécessite pas la cascade. Chaque consommateur Bus (`StepRunConsumer`, `IncidentConsumer`) se ré-abonne
par construction : le `Bus.subscribe()` vit dans `init/1`, qu'OTP rejoue à chaque restart (un consommateur
redémarré n'est jamais sourd ; contrat verrouillé par test côté `fleet_starfleet`).
`Application.step_status/0` expose la liveness du rail (`:inactive` | `:operational` | `:degraded` selon
que Poller + StepRunConsumer sont vivants) — consommé par la readiness de `fleet_api` (le vert-creux
« daemon up, rail mort » est attrapé sans fuiter les noms de process Ring 2 en Ring 4).

Le superviseur démarre aussi, **inconditionnellement** (avant le rail step), `Fleet.Pilot.ForgeFinch` —
pool HTTP/1 dédié au `ForgeClient` avec `conn_max_idle_time: 30_000`. Le défaut Finch `:infinity` laisse une
connexion idle traîner jusqu'à ce que la forge la ferme côté serveur → le 1er appel après idle pend jusqu'au
`receive_timeout` (10s), et `create_issue` (qui enchaîne 3 appels : `create_issue` + `add_label`[GET+PUT])
cumulait ainsi jusqu'à ~30s. Inconditionnel car `create_issue` (côté `fleet_mcp`) appelle le `ForgeClient`
hors du rail Poller/StepRunConsumer. Le moteur HTTP de `Fleet.Pilot.ForgeClient.Transport` (`request/4`,
privé) route via ce pool (`finch:`) et
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
.gitignore, .editorconfig, docs/spec.md — contenu + écriture dans le sous-module
`Fleet.Pilot.ProjectOnboard.Scaffold` : templates purs, zéro dépendance à l'orchestration) → commit+push
`main` → `git worktree add --orphan -b work/ops`
→ scaffold (backlog.md, scratchpad.md, plans/ — même sous-module) → commit+push `work/ops` → **`register_for_fleet`** (topic +
**marqueur d'admission système** + collaborateur write humain) → **`lock_main`** (②.1d) : donne
le **write** aux comptes de rôle (engineer/qualifier/reviewer/gatekeeper — sinon leurs reviews ne comptent
pas + le gatekeeper ne peut pas merger) **puis pose la branch-protection sur `main`** (N approvals = nb de
juges, dismiss-stale, block-on-rejected, pas de push direct). Mécanique → tout projet onboardé a le **gate
forge-enforcé** (l'arbitre = la forge, cible DN §1.4). `work/ops` + feature-branches non protégées. Identité **M2** (l'onboarding est
un acte d'infra système, pas du travail créatif) : `author=lcars-system` (le système GÉNÈRE le scaffold ;
l'arch n'écrit rien, il relaie `name`+`pitch`), `committer`=git config runtime (**l'humain qui a initié →
tracé**), `pusher`=`lcars-system` (`ForgeAuth.git_env`, owner fleet-wide) — tout avataré. Rail mécanique
(l'arch *déclenche* via le tool MCP `create_project`, le système *exécute* ; cf. `fleet_mcp`). Pas de GenServer.

Les write-ops forge réutilisées ici vivent dans le cœur `Fleet.Pilot.ForgeClient` (`create_issue`,
`post_comment`, `close_issue`) et ses sous-modules appelés en direct : `ForgeClient.Repo`
(`create_repo`, `add_topic`, `post_onboard_marker`, `add_collaborator`, `protect_branch`) et
`ForgeClient.Files` (`put_file`).

## Découplage core

Pas dans le core ring 1 (cf. doctrine `topologie-ring.md:173`). Le core
peut être invoqué manuellement OU par `fleet_pilot` après — découplage.
