defmodule Fleet.Pilot.StepDispatcher.ReviewLifecycle do
  @moduledoc """
  Cycle de vie REVIEW (PR) extrait de `Fleet.Pilot.StepDispatcher`.

  `StepDispatcher.dispatch_review/2` (PUBLIQUE — contrat du poller) reste au cœur : elle fait le gate
  PR (`in-flight`/`awaits-arch`), lit `pr_review_state` (verdicts commit-scopés + jury stable) PUIS
  DÉLÈGUE ici tout l'aiguillage. Ce module porte les trois clusters du flux PR :

    * **aiguillage** (`dispatch_by_verdicts/5`, point d'entrée) : un juge demandé sans verdict décisif →
      spawn le juge ; tous décisifs + un `:changes_requested` → rework ; tous approuvé → merge scellé ;
      aucun demandé → `:no_verdict`.
    * **rework / conflit** (`dispatch_rework`, `dispatch_conflict_resolution`) : re-spawn du producteur
      borné (budget de rounds forge-natif MA-06 pour le rework, IncidentRegistry cross-session pour le
      conflit) — au-delà, escalade arch, jamais de churn infini.
    * **promotion** (`promote_pr`) : sceau gatekeeper + merge rebase + die-on-promote de l'eng.

  ## Dépendance UNI-directionnelle (pas de cycle)

  ReviewLifecycle → `Spawn` (feuille de spawn SINGLE-AUTHORITY : `spawn_step/9`, `pod_id_for_scope/4`,
  `serialize_project_scope/6`, `safe_kill/2`, builders d'opts) + `ArchEscalation` (écriture de
  l'escalade humaine) + `GatekeeperSeal` (sceau de merge, autorité EXTERNE partagée avec
  `StepRunCompleter.promote`) → ø. Ce module ne NOMME JAMAIS `StepDispatcher` : le flux review descend
  vers les feuilles, il ne remonte pas au cœur. Le cœur DÉCIDE (gate PR + verdicts lus), ReviewLifecycle
  AIGUILLE, les feuilles EXÉCUTENT.

  ## Frontière : struct de seams `%Ctx{}` (blindé, `@enforce_keys`)

  Le flux review a besoin d'un large contexte (forge/loader/spawner/task_queue/resolver/repo/forge_opts/
  wake_recovery/opts). Contrairement aux seams ÉTROITS de `Spawn`/`ArchEscalation` (6 / 3 champs, un
  cluster feuille), ce contexte est le paquet complet du dispatch — d'où un struct DÉDIÉ plutôt qu'une
  map nue : `@enforce_keys` force chaque champ à la construction (site UNIQUE : `StepDispatcher.
  dispatch_review/2`) et un accès `ctx.<typo>` ne compile pas (là où `Map.get(ctx, :typo)` passerait en
  silence). ReviewLifecycle re-construit `Spawn.Seams`/`ArchEscalation.Seams` depuis ce `Ctx` au site
  d'appel de chaque feuille (frontière étroite préservée).

  ## Helpers PARTAGÉS avec le cœur, threadés SANS cycle ni fork

  `route_for/4` (lecture de la route gravée) et `tag_err/2` (tagging d'erreur de résolution) sont
  utilisés par les DEUX flux (issue `dispatch_issue` AU CŒUR + review ici). Ils RESTENT définis au cœur
  (leur home : le flux issue les appelle en direct) et sont threadés vers ReviewLifecycle par CAPTURE
  dans le `Ctx` (`route_reader` / `err_tagger`), exactement comme `resolver`/`wake_recovery` — la
  capture est créée AU CŒUR, donc ReviewLifecycle n'a aucune référence compile-time vers
  `StepDispatcher` (dépendance strictement uni-directionnelle, pas de cycle) sans dupliquer les deux
  helpers (pas de fork).
  """

  require Logger

  # Autorité du FORMAT des briefs (worker/judge/rework/conflit) : ReviewLifecycle CHOISIT quel brief
  # selon le `kind` du dispatch PR ; BriefBuilder le FORME.
  alias Fleet.Pilot.BriefBuilder

  # Écriture de l'escalade humaine (cluster IMPUR) : ReviewLifecycle DÉCIDE (budget rework /
  # IncidentRegistry), ArchEscalation ÉCRIT (comment gatekeeper dédupliqué + verrou `awaits-arch`).
  alias Fleet.Pilot.StepDispatcher.ArchEscalation

  # Feuille de spawn SINGLE-AUTHORITY : le flux review CONVERGE avec le flux issue sur `Spawn.spawn_step/9`
  # (ordre verrou→pod→enqueue→wake + compensation), `Spawn.pod_id_for_scope/4`, `Spawn.serialize_project_scope/6`
  # et `Spawn.safe_kill/2` (die-on-promote) — une seule copie chacun, jamais un fork.
  alias Fleet.Pilot.StepDispatcher.Spawn

  defmodule Ctx do
    @moduledoc """
    Contexte complet du flux review, construit au site UNIQUE `StepDispatcher.dispatch_review/2` et
    threadé à travers l'aiguillage/rework/promotion. Struct DÉDIÉ (pas une map) : `@enforce_keys`
    force chaque champ, un accès `ctx.<typo>` ne compile pas. `route_reader`/`err_tagger` sont les
    captures des helpers du cœur (`route_for`/`tag_err`) partagés avec le flux issue.
    """
    @enforce_keys [
      :forge,
      :loader,
      :spawner,
      :task_queue,
      :resolver,
      :repo,
      :forge_opts,
      :wake_recovery,
      :opts,
      :route_reader,
      :err_tagger
    ]
    defstruct @enforce_keys

    @type t :: %__MODULE__{
            # Client forge injecté (seam `:forge_client`, défaut prod `Fleet.Pilot.ForgeClient`).
            forge: module(),
            # Loader de cap-profile injecté (seam `:loader`, défaut prod `Fleet.CapProfile`).
            loader: module(),
            # Spawner injecté (seam `:spawner`, défaut prod `Fleet.Spawner`).
            spawner: module(),
            # Broker de briefs injecté (seam `:task_queue`, défaut prod `Fleet.TaskQueue`).
            task_queue: module(),
            # Résolveur projet injecté (seam `:project_resolver`, défaut `&default_project_resolver/2`).
            resolver: (String.t(), keyword() -> {:ok, map() | nil} | {:error, term()}),
            # `owner/name` du repo (PR + issue parente y vivent).
            repo: String.t(),
            # Opts forge (base_url/token…) passés au ForgeClient.
            forge_opts: keyword(),
            # Recovery de wake injecté (seam `:wake_recovery`, défaut `&Fleet.Pilot.WakeRecovery.wake/3`).
            wake_recovery: (String.t(), (-> any()), keyword() -> :ok | {:error, term()}),
            # Le keyword `opts` brut du dispatch (base des `review_opts`, budgets, seam d'incident registry).
            opts: keyword(),
            # Capture de `StepDispatcher.route_for/4` (lecture de la route gravée) — partagée avec le flux issue.
            route_reader: (module(), String.t(), integer(), keyword() ->
                             {:ok, {String.t(), String.t()} | nil} | {:error, term()}),
            # Capture de `StepDispatcher.tag_err/2` (tagging d'erreur de résolution) — partagée avec le flux issue.
            err_tagger: (term(), atom() -> term())
          }
  end

  # ============================================================
  # Cluster D — aiguillage (entrée du flux review)
  # ============================================================

  @doc """
  Aiguillage REVIEWS-DRIVEN (la source de vérité = les reviews postées, PAS `requested_reviewers`
  que Gitea ne vide pas). Sans branch-protection : LCARS agrège (décision user). ORDRE :
    1. un juge demandé SANS verdict décisif → round actif → on le spawn (sérialisé par le verrou PR).
       Un juge déjà décisif (même encore listé dans requested_reviewers) n'est PAS re-spawné → fin de
       la boucle de re-spawn.
    2. tous les demandés ont un verdict + au moins un `:changes_requested` → rework du producteur.
    3. tous les demandés ont APPROUVÉ → MERGE (scellé gatekeeper).
    4. aucun juge demandé → no_verdict (PR sans review-request, surfacé).

  Point d'entrée du flux review : `StepDispatcher.dispatch_review/2` y délègue après le gate PR + la
  lecture de `pr_review_state`. `requested` = union(requested_reviewers volatil, jury stable) ;
  `verdicts` = map `login → verdict` commit-scopée.
  """
  @spec dispatch_by_verdicts([String.t()], map(), integer(), String.t(), Ctx.t()) ::
          {:ok, tuple()} | {:skipped, term()} | {:error, term()}
  def dispatch_by_verdicts(requested, verdicts, pr_number, head, %Ctx{} = ctx) do
    pending = requested -- Map.keys(verdicts)

    cond do
      pending != [] ->
        dispatch_pr_role(:judge, pr_number, head, hd(pending), ctx)

      requested == [] ->
        {:skipped, :no_verdict}

      Enum.any?(Map.values(Map.take(verdicts, requested)), &(&1 == :changes_requested)) ->
        dispatch_rework(pr_number, head, ctx)

      true ->
        # Tous approuvé → MERGE. Si le merge échoue sur un CONFLIT (PR approuvée mais
        # `main` a avancé + même fichier édité), on ne remonte PAS l'erreur sèche (= retry-à-l'infini avec un
        # sceau mensonger). On RÉSOUT (rebase producteur), borné par l'IncidentRegistry (récurrence → escalade arch).
        case promote_pr(pr_number, head, ctx) do
          {:error, {:merge, reason}} -> dispatch_conflict_resolution(pr_number, head, reason, ctx)
          other -> other
        end
    end
  end

  defp dispatch_pr_role(kind, pr_number, head, role, ctx) do
    with {:ok, {issue_n, _producer}} <- parse_feature_branch_or_skip(head),
         {:ok, profile} <- load_role_or_skip(ctx.loader, role) do
      do_dispatch_review(pr_number, issue_n, head, role, profile, kind, ctx)
    end
  end

  defp parse_feature_branch_or_skip(head) do
    case Fleet.Pilot.ForgeProtocol.parse_feature_branch(head) do
      {:ok, _} = ok -> ok
      :error -> {:skipped, :not_fleet_branch}
    end
  end

  defp load_role_or_skip(_loader, ""), do: {:skipped, :no_role}

  defp load_role_or_skip(loader, role) do
    case loader.load(role) do
      {:ok, _} = ok -> ok
      {:error, _} -> {:skipped, :no_role}
    end
  end

  defp do_dispatch_review(pr_number, issue_n, head, role, profile, kind, %Ctx{} = ctx) do
    # Spawner/task_queue ne sont pas lus ici directement : ils transitent via `ctx` vers `spawn_step`.
    %Ctx{
      repo: repo,
      forge: forge,
      resolver: resolver,
      forge_opts: forge_opts,
      opts: opts
    } = ctx

    # Le pod review (juge) OU rework (producteur) clone la FEATURE-BRANCH (`head.ref`), PAS
    # `main` : le juge doit voir le DIFF du producteur (sinon il juge `main`, c.-à-d. rien de réel) ;
    # le rework reprend SON propre travail. Read-only sur le code via le workspace provisionné par le
    # système (le pod n'a aucun token forge). `base_branch: head` → le pod CLONE et
    # part du tip de la feature-branch.
    #
    # La RÉSOLUTION (rebase) part AUSSI de la feature (son travail à rebaser),
    # mais son livrable doit DESCENDRE de `main` (la cible du rebase), pas de l'ancien tip de feature
    # (réécrit par le rebase → la gate le rejetterait : `base_not_ancestor`). On
    # DÉCONFLE les deux rôles autrement portés par `base_sha` : `base_branch` = clone-base (feature, le pod
    # part de là, INCHANGÉ) ; `gate_base_branch` = "main" → le resolver pinne la base de GATE sur `main`.
    # judge/rework (forward, pas de réécriture) : pas de `gate_base_branch` → gate = clone-base, inchangé.
    review_opts =
      opts
      |> Keyword.put(:base_branch, head)
      |> maybe_gate_base_main(kind)

    # PROJET + ROUTE resolus AVANT toute ecriture forge (read-only) : un echec ne laisse pas de
    # verrou orphelin. La route (workflow_map_name, step) est lue sur l'ISSUE (le pipeline-state y reste).
    # `route_reader`/`err_tagger` = captures des helpers du cœur (route_for/tag_err), partagés avec le flux issue.
    with {:ok, project} <- ctx.err_tagger.(resolver.(repo, review_opts), :project_resolution),
         {:ok, route} <-
           ctx.err_tagger.(ctx.route_reader.(forge, repo, issue_n, forge_opts), :route_resolution) do
      # pod_id : rework/conflict = le PRODUCTEUR, routé par `slot_scope` (project → for_repo = MÊME
      # identité que dispatch_issue, UNE par projet ; instance → for_issue). Le JUGE keye sur la PR
      # (for_pr, fan-out par review). Le rework re-lit son état DEPUIS LA FORGE (PR + findings) →
      # changer l'identité du pod ne perd aucun contexte.
      pod_id =
        case kind do
          k when k in [:rework, :resolve_conflict] ->
            Spawn.pod_id_for_scope(Fleet.CapProfile.slot_scope(profile), repo, issue_n, role)

          _ ->
            Fleet.Pilot.PodId.for_pr(repo, pr_number, role)
        end

      # Gate de sérialisation (MÊME règle que dispatch_issue) : un producteur project-scoped déjà vivant
      # (occupé par un autre issue) → on DÉFÈRE, jamais re-briefer-pendant-occupé. Juges (instance) et
      # rework instance → `:ok` (no-op, jamais gated). Appel uniforme via `slot_scope`. `{:skipped,
      # :role_busy}` remonte au poller (qui gère `{:skipped, _}` → retry au tick suivant).
      case Spawn.serialize_project_scope(
             Fleet.CapProfile.slot_scope(profile),
             Fleet.CapProfile.lifetime_scope(profile),
             ctx.spawner,
             pod_id,
             project,
             "work"
           ) do
        {:skipped, :role_busy} ->
          {:skipped, :role_busy}

        :ok ->
          # :judge -> GateBrief désamorcé ; :rework -> brief au PRODUCTEUR (corrige + push).
          brief =
            review_brief(
              kind,
              profile,
              role,
              forge,
              repo,
              issue_n,
              forge_opts,
              route,
              pr_number
            )

          spawn_opts =
            [brief: brief, pod_id: pod_id, rc_name: Spawn.rc_name(repo, role)]
            |> Spawn.maybe_put_project(project)
            |> Spawn.maybe_put_route(route)
            |> Spawn.maybe_put_repo_id(Spawn.resolve_repo_id(forge, repo, forge_opts))

          # Spawn LEAF partagé avec dispatch_issue (verrou → pod → enqueue → wake + compensation).
          # Verrou keyé sur la PR (pr_number) ; issue_id + enqueue keyés sur l'ISSUE (issue_n — le
          # pipeline-state y reste). On construit le struct de seams à ce site depuis `ctx` (les 6
          # seams, pas le `ctx` entier — frontière blindée).
          log_ctx = "review pr=#{repo}##{pr_number} issue=##{issue_n}"

          Spawn.spawn_step(
            %Spawn.Seams{
              forge: ctx.forge,
              spawner: ctx.spawner,
              task_queue: ctx.task_queue,
              repo: ctx.repo,
              forge_opts: ctx.forge_opts,
              wake_recovery: ctx.wake_recovery
            },
            pod_id,
            role,
            profile,
            brief,
            spawn_opts,
            pr_number,
            issue_n,
            log_ctx
          )
      end
    else
      {:error, {phase, reason}} ->
        Logger.warning(
          "StepDispatcher: #{phase} review role=#{role} pr=#{repo}##{pr_number} → #{inspect(reason)} (skip, pas de verrou)"
        )

        {:error, {phase, reason}}
    end
  end

  # DÉCONFLATION clone-base / gate-base. Une RÉSOLUTION (rebase) part de la
  # feature (clone-base, son travail) mais son livrable doit DESCENDRE de `main` (cible du rebase) → la
  # gate se base sur `main`, pas sur l'ancien tip de feature (réécrit par le rebase, donc pas
  # ancêtre). judge/rework (forward, pas de réécriture) : aucune divergence → gate = clone-base.
  defp maybe_gate_base_main(opts, :resolve_conflict),
    do: Keyword.put(opts, :gate_base_branch, "main")

  defp maybe_gate_base_main(opts, _kind), do: opts

  # Brief d'un dispatch PR : :judge -> GateBrief desamorce (via build_brief, le pod
  # juge l'issue) ; :rework -> brief de rework au PRODUCTEUR (corrige selon la review, re-pousse).
  # Chemin PR-juge — pas de step workflow_map ici (juges PR-driven) → `step_spec = %{}` :
  # build_brief retombe sur le `brief_kind` du profil (judge pour qualifier/reviewer) ET sur le
  # `judge_target` par défaut (deliverable) → build_judge_brief (juge le livrable/PR).
  defp review_brief(:judge, profile, role, forge, repo, issue_n, forge_opts, route, _pr),
    do:
      BriefBuilder.build_brief(
        profile,
        role,
        forge,
        repo,
        issue_n,
        %{},
        forge_opts,
        route,
        %{}
      )

  defp review_brief(:rework, _profile, role, forge, repo, _issue_n, forge_opts, route, pr),
    do: BriefBuilder.rework_brief(role, forge, repo, pr, forge_opts, route)

  defp review_brief(
         :resolve_conflict,
         _profile,
         role,
         forge,
         repo,
         _issue_n,
         forge_opts,
         route,
         pr
       ),
       do: BriefBuilder.resolve_conflict_brief(role, forge, repo, pr, forge_opts, route)

  # ============================================================
  # Cluster E — rework / conflit (décision de re-spawn borné vs escalade)
  # ============================================================

  # Rework juge : la PR porte un verdict REQUEST_CHANGES courant (l'état a déjà été lu par
  # `dispatch_review` → pas de re-lecture ici) -> le PRODUCTEUR (role git_native de head.ref) reprend
  # pour corriger sur la même PR. Idempotent (verrou PR).
  #
  # FREIN ANTI-CHURN. Sans compteur, `dispatch_rework` re-spawnerait le producteur à chaque tick — le frein
  # `rebound` (budget workflow_map, StepRunConsumer) n'est jamais appelé sur CE chemin (PR-review-driven) → rework
  # INFINI si l'eng ne satisfait jamais le juge, sans escalade. On borne les rounds par un compteur
  # FORGE-NATIF (`count_change_request_rounds` = nb de reviews REQUEST_CHANGES, monotone) aligné sur le frein
  # workflow_map (budget = `max_rework_rounds`, défaut 2, configurable via `:max_pr_rework_rounds`). Au-delà du
  # budget → ESCALADE ARCH (label `awaits-arch` + commentaire), pas de re-spawn → fin du churn. Budget
  # illisible (`{:error}`) → on NE re-spawn PAS à l'aveugle : escalade (symétrique de `rebound` qui surface).
  defp dispatch_rework(pr_number, head, ctx) do
    case Fleet.Pilot.ForgeProtocol.parse_feature_branch(head) do
      {:ok, {_n, producer_role}} ->
        budget = Keyword.get(ctx.opts, :max_pr_rework_rounds, 2)

        case ctx.forge.count_change_request_rounds(ctx.repo, pr_number, ctx.forge_opts) do
          {:ok, rounds} when rounds <= budget ->
            dispatch_pr_role(:rework, pr_number, head, producer_role, ctx)

          {:ok, rounds} ->
            ArchEscalation.escalate_rework(
              arch_seams(ctx),
              pr_number,
              head,
              %{rounds: rounds, budget: budget}
            )

          {:error, reason} ->
            # Budget non vérifiable → on n'entre pas dans une boucle aveugle : on remonte à l'arch.
            ArchEscalation.escalate_rework(
              arch_seams(ctx),
              pr_number,
              head,
              {:budget_unreadable, reason}
            )
        end

      :error ->
        {:skipped, :not_fleet_branch}
    end
  end

  # Merge KO sur conflit (PR approuvée, `main` avancé sous une PR parallèle touchant le
  # même fichier). Borné par l'IncidentRegistry (cross-session, work/ops) :
  #   1ʳᵉ occurrence → `:recorded` → dispatch le PRODUCTEUR en `:resolve_conflict` (rebase + résous ; le push
  #     rebasé invalide les vieilles reviews via head_sha → les juges re-valident le fusionné, gatekeeper scelle
  #     au tick suivant) ;
  #   récurrence → `{:escalated, _}` (résolution déjà tentée, conflit persiste) → ESCALADE ARCH. PAS de boucle.
  defp dispatch_conflict_resolution(pr_number, head, reason, ctx) do
    # Le n° de PR est encodé DIGIT-FREE (base-26 a..z) DANS le subject. `IncidentRegistry.signature`
    # passe le subject par `normalize` (`~r/\d+/ → "N"`, PARTAGÉ pod/wake — on ne le touche PAS) : un `pr-8`
    # décimal deviendrait `pr-N` ≡ `pr-12` → après le 1er conflit d'un repo, TOUTE PR suivante en conflit serait
    # vue « récurrente » → escaladée arch au lieu d'être résolue (la résolution parallèle neutralisée dès le
    # 2ᵉ issue parallèle). En encodant le numéro en LETTRES (`pr-i` pour 8, `pr-m` pour 12), `normalize` ne
    # le collapse plus → la clé incident est DISTINCTE par PR. (Le repo, lui, peut porter des digits collapsés
    # par normalize : sans incidence — une session de conflits est dans UN repo, l'axe de distinction est la PR.)
    subject = "#{ctx.repo}#pr-#{encode_pr_letters(pr_number)}"

    # Reason STABLE pour le compteur : la dedup inclut la reason → un message http qui varie casserait le seuil.
    # Le détail réel (`reason`) va dans le commentaire d'escalade, pas dans la clé. Seam test : router vers un
    # IncidentRegistry nommé (async-safe) via `:incident_registry_server` ; absent (prod) → registry par défaut.
    reg_opts =
      case Keyword.get(ctx.opts, :incident_registry_server) do
        nil -> []
        server -> [server: server]
      end

    case Fleet.Pilot.IncidentRegistry.record_or_escalate(
           "merge-conflict",
           subject,
           "PR inmergeable (conflit de base)",
           reg_opts
         ) do
      :recorded ->
        resolve_first_conflict(head, pr_number, ctx)

      {:record_failed, e} ->
        # Registre indisponible : l'incident n'est PAS mémorisé (une récurrence ne sera pas détectée),
        # mais c'est bien une 1re occurrence → on tente quand même la résolution. On le CRIE.
        Logger.error(
          "StepDispatcher merge-conflict #{subject} : incident NON gravé (registre indisponible) — " <>
            "1re résolution tentée SANS mémoire (récurrence non détectable) : #{inspect(e)}"
        )

        resolve_first_conflict(head, pr_number, ctx)

      {:escalated, _} ->
        ArchEscalation.escalate_conflict(arch_seams(ctx), pr_number, head, reason)

      {:escalation_failed, e} ->
        # Récurrence DÉTECTÉE (le conflit persiste) → on escalade à l'arch comme prévu. Mais le issue
        # sysadmin (error_system) n'a PAS pu être ouvert (forge down ?) — on le CRIE, on ne rassure pas.
        Logger.error(
          "StepDispatcher merge-conflict #{subject} RÉCURRENT mais issue sysadmin ÉCHOUÉ — AUCUN " <>
            "issue error_system créé (forge down ?) ; escalade arch tentée tout de même : #{inspect(e)}"
        )

        ArchEscalation.escalate_conflict(arch_seams(ctx), pr_number, head, reason)
    end
  end

  # 1re occurrence d'un conflit : on tente la résolution (re-spawn du producteur en mode rebase/résous).
  # Partagé entre `:recorded` (incident gravé) et `{:record_failed, _}` (registre indisponible — on tente
  # quand même, c'est bien un 1er passage du point de vue dispatch).
  defp resolve_first_conflict(head, pr_number, ctx) do
    case Fleet.Pilot.ForgeProtocol.parse_feature_branch(head) do
      {:ok, {_n, producer_role}} ->
        dispatch_pr_role(:resolve_conflict, pr_number, head, producer_role, ctx)

      :error ->
        {:skipped, :not_fleet_branch}
    end
  end

  # Contrat de frontière de l'écriture d'escalade : ReviewLifecycle décide, ArchEscalation écrit. On ne
  # lui passe QUE les 3 seams forge (`@enforce_keys` → un accès hors-3-seams ne compile pas), jamais le ctx entier.
  defp arch_seams(%Ctx{} = ctx),
    do: %ArchEscalation.Seams{forge: ctx.forge, repo: ctx.repo, forge_opts: ctx.forge_opts}

  # Encode un n° de PR en LETTRES (base-26 bijective a..z) → DIGIT-FREE, invisible au `normalize` de
  # l'IncidentRegistry (qui collapse ~r/\d+/ → "N") : deux PR distinctes gardent des clés incident
  # DISTINCTES (isole les conflits par PR). n ≤ 0 / non-entier (anomalie forge) → "x" (ne crash pas la clé).
  # Vit ici : seul `dispatch_conflict_resolution` le consomme (clé d'incident, pas l'écriture d'escalade).
  defp encode_pr_letters(n) when is_integer(n) and n > 0, do: encode_pr_letters(n, [])
  defp encode_pr_letters(_), do: "x"
  defp encode_pr_letters(0, acc), do: List.to_string(acc)

  defp encode_pr_letters(n, acc),
    do: encode_pr_letters(div(n - 1, 26), [?a + rem(n - 1, 26) | acc])

  # ============================================================
  # Cluster G — promotion (merge scellé gatekeeper)
  # ============================================================

  # PROMOTE PR-state-driven (interim, sans branch-protection) : tous les juges ont
  # approuvé → le système SCELLE. Comment de fin + merge signés GATEKEEPER
  # (gardien des PRs — « c'est dans son nom » ; token de rôle, `as_role`). Comment HONNÊTE
  # (on ne ment pas, on montre) : livré par l'eng, validé par les juges (APPROVED), mergé
  # par le système (branch-protection OFF en dev → LCARS agrège, pas Gitea — explicité). Le merge
  # `rebase` (LINÉAIRE, gère un `main` avancé sous une PR parallèle — multi-issue, cf. merge_pr)
  # auto-close l'issue via `Closes #N` du body PR → close APRÈS merge, jamais avant. Pas de verrou
  # (poller mono-process) ; PR déjà mergée → 409 → la PR disparaît au tick suivant (idempotent).
  #
  # `promote_comment` + le rôle gatekeeper + le merge vivent dans `Fleet.Pilot.GatekeeperSeal`
  # (sceau UNIQUE partagé avec `StepRunCompleter.promote` — pas de fork de signature de merge).
  defp promote_pr(pr_number, head, %Ctx{} = ctx) do
    with {:ok, {issue_n, producer}} <- parse_feature_branch_or_skip(head) do
      # Sceau UNIQUE partagé avec `StepRunCompleter.promote` : commentaire gatekeeper + merge
      # signé gatekeeper. Un chemin de merge séparé forkerait en token système (l'escalade signerait `system`).
      gk_opts =
        Fleet.Pilot.ForgeClient.as_role(
          ctx.forge_opts,
          Fleet.Pilot.GatekeeperSeal.gatekeeper_role()
        )

      case Fleet.Pilot.GatekeeperSeal.seal_and_merge(
             ctx.forge,
             ctx.repo,
             pr_number,
             issue_n,
             producer,
             gk_opts
           ) do
        :ok ->
          # Die-on-promote (best-effort). Le producteur est `one-shot` : il est DÉJÀ mort en fin de
          # build/rework → ce kill est un no-op dans le cas nominal. On garde DÉLIBÉRÉMENT `for_issue`
          # (pas `for_repo`) : pour un producteur `slot_scope: project`, `for_issue(issue_n, producer)`
          # cible un pod_id PHANTÔME (`<repo>-issue-N-engineer` n'existe pas — l'identité projet est
          # `<repo>-engineer`) → no-op SÛR. Utiliser `for_repo` ici TUERAIT l'eng s'il code déjà une
          # AUTRE issue (pod projet partagé) = bug « kill the wrong eng ». À revisiter SEULEMENT si un
          # producteur PIPE (long-lived) est réintroduit (cleanup ciblé non-naïf nécessaire alors).
          _ =
            Spawn.safe_kill(ctx.spawner, Fleet.Pilot.PodId.for_issue(ctx.repo, issue_n, producer))

          Logger.info(
            "StepDispatcher: PROMOTE pr=#{ctx.repo}##{pr_number} issue=##{issue_n} " <>
              "(juges OK → merge rebase, scellé gatekeeper, close via Closes ##{issue_n} ; eng tué)"
          )

          {:ok, {:merged, pr_number}}

        {:error, _} = err ->
          err
      end
    end
  end
end
