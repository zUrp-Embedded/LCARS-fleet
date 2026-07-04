defmodule Fleet.Pilot.StepDispatcher.ReviewLifecycle.RoleDispatch do
  @moduledoc """
  Feuille d'EXÉCUTION du flux review, extraite de `ReviewLifecycle` : prépare et spawn
  UN rôle sur une PR — juge (`:judge`), producteur en rework (`:rework`), producteur en
  résolution de conflit (`:resolve_conflict`).

  ## Pourquoi cette coupe (et pas une par cluster déclaré)

  Les trois clusters de `ReviewLifecycle` (aiguillage / rework-conflit / promotion)
  convergent TOUS sur la même mécanique de spawn PR-role : couper aiguillage↔rework en
  deux modules créerait un cycle (le rework rappelle le spawn du producteur). En
  extrayant la FEUILLE partagée, le graphe devient un DAG strict :
  aiguillage → remédiation → ICI → `Spawn` (leaf global). La décision reste en amont,
  ce module EXÉCUTE (résolutions read-only puis spawn, jamais de choix de politique).

  ## Invariants portés ici

    * **clone-base vs gate-base** : le pod review/rework clone la FEATURE-BRANCH
      (`base_branch: head` — le juge doit voir le DIFF, le rework reprend SON travail) ;
      une RÉSOLUTION (rebase) garde la feature en clone-base mais pinne la gate
      d'ancêtre sur `main` (`gate_base_branch` — le tip de feature est réécrit par le
      rebase, il ne serait plus ancêtre).
    * **résolutions AVANT toute écriture forge** (projet + route read-only) : un échec
      ne laisse jamais de verrou orphelin.
    * **identité pod par scope** : rework/conflit = le PRODUCTEUR (`slot_scope` project
      → `for_repo`, MÊME identité que le flux issue ; instance → `for_issue`) ; le JUGE
      keye sur la PR (`for_pr`, fan-out par review).
    * **gate de sérialisation** : un producteur project-scoped occupé → `{:skipped,
      :role_busy}` (retry au tick suivant), jamais re-briefer-pendant-occupé.

  Reçoit le `%Ctx{}` du flux review (construit au site unique
  `StepDispatcher.dispatch_review/2`) et re-construit `Spawn.Seams` au site d'appel de
  la feuille globale (frontière étroite préservée).
  """

  require Logger

  # Autorité du FORMAT des briefs (worker/judge/rework/conflit) : l'appelant CHOISIT le `kind`,
  # BriefBuilder FORME le brief.
  alias Fleet.Pilot.BriefBuilder

  # Source unique de l'idiome « pose la clé SI non-nil » (builders de spawn_opts).
  alias Fleet.Pilot.Opts

  # Feuille de spawn SINGLE-AUTHORITY (ordre verrou→pod→enqueue→wake + compensation).
  alias Fleet.Pilot.StepDispatcher.Spawn

  # Builders d'opts / naming du spawn (rc_name / maybe_put_route / resolve_repo_id) — partagés
  # avec le flux issue (StepDispatcher), une seule copie.
  alias Fleet.Pilot.StepDispatcher.Spawn.Naming

  alias Fleet.Pilot.StepDispatcher.ReviewLifecycle.Ctx

  @typedoc "Nature du dispatch PR : juge, rework producteur, ou résolution de conflit (rebase)."
  @type kind :: :judge | :rework | :resolve_conflict

  @doc """
  Prépare et spawn le rôle `role` sur la PR `pr_number` (head = feature-branch du
  producteur). Résout la brique (`parse_feature_branch_or_skip/1`) + le cap-profile,
  puis exécute. `{:skipped, _}` (branche non-fleet / rôle inconnu / role_busy) remonte
  au poller (retry au tick suivant) ; `{:error, {phase, _}}` = résolution échouée
  (aucune écriture forge posée).
  """
  @spec dispatch(kind(), integer(), String.t(), String.t(), Ctx.t()) ::
          {:ok, tuple()} | {:skipped, term()} | {:error, term()}
  def dispatch(kind, pr_number, head, role, %Ctx{} = ctx) do
    with {:ok, {issue_n, _producer}} <- parse_feature_branch_or_skip(head),
         {:ok, profile} <- load_role_or_skip(ctx.loader, role) do
      do_dispatch_review(pr_number, issue_n, head, role, profile, kind, ctx)
    end
  end

  @doc """
  Vocabulaire de la feature-branch fleet, mappé au contrat du poller : head non-fleet →
  `{:skipped, :not_fleet_branch}` (jamais une erreur — une PR étrangère n'est pas une
  anomalie). Partagé par tout le flux review (aiguillage/remédiation/promotion).
  """
  @spec parse_feature_branch_or_skip(String.t()) ::
          {:ok, {integer(), String.t()}} | {:skipped, :not_fleet_branch}
  def parse_feature_branch_or_skip(head) do
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
            [brief: brief, pod_id: pod_id, rc_name: Naming.rc_name(repo, role)]
            |> Opts.maybe_put(:project, project)
            |> Naming.maybe_put_route(route)
            |> Opts.maybe_put(:repo_id, Naming.resolve_repo_id(forge, repo, forge_opts))

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
end
