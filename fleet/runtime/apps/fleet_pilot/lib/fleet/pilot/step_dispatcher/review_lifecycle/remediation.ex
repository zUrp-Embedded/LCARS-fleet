defmodule Fleet.Pilot.StepDispatcher.ReviewLifecycle.Remediation do
  @moduledoc """
  Remédiation BORNÉE du flux review, extraite de `ReviewLifecycle` : re-spawn du producteur pour REWORK
  (verdict `changes_requested`), et AIGUILLAGE d'un échec de merge selon sa cause réelle
  (`route_merge_failure`) — toujours sous un frein / une classification honnête, jamais de churn infini
  ni d'action sur une prémisse fausse.

  ## Rework — frein anti-churn

  Compteur FORGE-NATIF (`count_change_request_rounds` = nb de reviews REQUEST_CHANGES, monotone),
  budget = `spec.max_rework_rounds` du MAP de l'issue (DONNÉE, le MÊME frein que le rebond issue — plus
  de défaut codé `:max_pr_rework_rounds` aligné à la main). Au-delà → ESCALADE ARCH. Budget/route/map
  illisible → on NE re-spawn PAS à l'aveugle : escalade (symétrique de `rebound` côté StepRunConsumer).

  ## Échec de merge — classification honnête (`route_merge_failure`)

  Un merge peut échouer pour des raisons NATURELLEMENT distinctes (`Fleet.Pilot.MergeOutcome`, relue de
  l'objet PR) : déjà-mergé / annulé (close humain) / draft / policy (re-request humaine) / vrai conflit
  git / inconnu. Chacune a son aiguillage propre. Le fourre-tout historique « tout échec = conflit →
  dispatch eng rebase » est retiré (l'eng est forge-aveugle, il ne peut PAS rebaser → mur 2026-07-07).
  Le throttle des cas escaladés = le verrou `lcars-awaits-arch` posé par `ArchEscalation` (le poller
  SKIP l'issue), pas un IncidentRegistry (plus de boucle de résolution à borner ici).

  La DÉCISION vit ici ; l'EXÉCUTION du re-spawn descend vers `RoleDispatch` (feuille partagée avec le
  spawn de juge — pas de fork de la mécanique) ; l'ÉCRITURE de l'escalade humaine descend vers
  `ArchEscalation` (seams étroits reconstruits ICI, jamais le `Ctx` entier).
  """

  require Logger

  # Écriture de l'escalade humaine (cluster IMPUR) : Remediation DÉCIDE (budget rework /
  # IncidentRegistry), ArchEscalation ÉCRIT (comment gatekeeper dédupliqué + verrou `awaits-arch`).
  alias Fleet.Pilot.StepDispatcher.ArchEscalation

  alias Fleet.Pilot.StepDispatcher.ReviewLifecycle.Ctx
  alias Fleet.Pilot.StepDispatcher.ReviewLifecycle.RoleDispatch

  @doc """
  Rework juge : la PR porte un verdict REQUEST_CHANGES courant (l'état a déjà été lu par
  `dispatch_review` → pas de re-lecture ici) → le PRODUCTEUR (rôle git_native de head.ref)
  reprend pour corriger sur la même PR. Idempotent (verrou PR).

  FREIN ANTI-CHURN : sans compteur, ce chemin re-spawnerait le producteur à chaque tick —
  le frein `rebound` (budget workflow_map, StepRunConsumer) n'est JAMAIS appelé sur le
  chemin PR-review-driven → rework INFINI si l'eng ne satisfait jamais le juge. Bornage
  forge-natif (cf. moduledoc), au-delà → escalade arch, fin du churn.
  """
  @spec dispatch_rework(integer(), String.t(), Ctx.t()) ::
          {:ok, tuple()} | {:skipped, term()} | {:error, term()}
  def dispatch_rework(pr_number, head, %Ctx{} = ctx) do
    case Fleet.Pilot.ForgeProtocol.parse_feature_branch(head) do
      {:ok, {issue_n, producer_role}} ->
        with {:ok, budget} <- pr_rework_budget(ctx, issue_n),
             {:ok, rounds} <-
               ctx.forge.count_change_request_rounds(ctx.repo, pr_number, ctx.forge_opts) do
          if rounds <= budget do
            RoleDispatch.dispatch(:rework, pr_number, head, producer_role, ctx)
          else
            ArchEscalation.escalate_rework(
              arch_seams(ctx),
              pr_number,
              head,
              %{rounds: rounds, budget: budget}
            )
          end
        else
          # Budget non vérifiable (route/map illisible) OU compteur illisible → on n'entre PAS dans une
          # boucle aveugle : on remonte à l'arch (symétrique du frein issue `rework_budget_unreadable`).
          {:error, reason} ->
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

  # Budget rework PR = le MÊME `spec.max_rework_rounds` que le frein issue (policy de churn UNIQUE du
  # pipeline, lue comme DONNÉE — plus de défaut codé aligné-à-la-main). Route de l'issue → nom de map →
  # budget. Routeless / map illisible → `{:error}` : le caller escalade (jamais de boucle aveugle).
  defp pr_rework_budget(%Ctx{} = ctx, issue_n) do
    with {:ok, {map_name, _step}} when is_binary(map_name) <-
           ctx.route_reader.(ctx.forge, ctx.repo, issue_n, ctx.forge_opts),
         {:ok, workflow_map} <-
           Fleet.Pilot.WorkflowMapNav.safe_load(ctx.workflow_map_loader, map_name) do
      {:ok, Map.fetch!(workflow_map, "max_rework_rounds")}
    else
      {:ok, nil} -> {:error, :routeless}
      {:error, _} = err -> err
      other -> {:error, {:route_unreadable, other}}
    end
  end

  @doc """
  Aiguillage d'un ÉCHEC DE MERGE selon sa cause RÉELLE (`Fleet.Pilot.MergeOutcome`, relue de l'objet PR
  frais — jamais le fourre-tout « conflit »). Remplace l'ancien `dispatch_conflict_resolution` qui
  supposait TOUJOURS un conflit git et dispatchait le producteur pour rebaser — IMPOSSIBLE (le pod est
  forge-aveugle, pas de credentials) → mur constaté live 2026-07-07 sur une simple fenêtre de policy.

    * `:merged`   → quelqu'un a mergé entre-temps (course multi-acteur / replay) → `{:ok, :merged}` idempotent.
    * `:closed`   → un humain a FERMÉ la PR (annulation) → la brique est morte, on ne s'acharne pas.
    * `:draft`    → un humain l'a repassée en brouillon (parquée) → skip ; `dispatch_review` la re-skip
                    tant que draft (garde dispatch-juge).
    * `:policy`   → git mergeable mais branch-protection refuse (approbations retirées par une
                    RE-REQUEST humaine, CI…) → on re-converge : re-dispatch le juge re-demandé (timeline).
                    Aucun re-demandé = blocage de policy qu'on ne peut pas lever mécaniquement → escalade honnête.
    * `:conflict` / `:unknown` → non auto-résoluble par le système (barrière forge-aveugle) → escalade
                    HONNÊTE arch (plus de brief menteur « après un rebase » ni de dispatch-eng-impossible).
                    La résolution mécanique du conflit (système rebase en scratch) est un incrément ultérieur.
  """
  @spec route_merge_failure(integer(), String.t(), term(), Ctx.t()) ::
          {:ok, tuple()} | {:skipped, term()} | {:error, term()}
  def route_merge_failure(pr_number, head, reason, %Ctx{} = ctx) do
    case classify_merge_failure(pr_number, ctx) do
      :merged ->
        {:ok, {:merged, pr_number}}

      :closed ->
        Logger.info(
          "StepDispatcher: PR #{ctx.repo}##{pr_number} fermée (annulation humaine) → merge abandonné"
        )

        {:skipped, {:cancelled, pr_number}}

      :draft ->
        {:skipped, {:draft, pr_number}}

      :policy ->
        reconverge_policy(pr_number, head, ctx)

      class when class in [:conflict, :unknown] ->
        ArchEscalation.escalate_merge_blocked(arch_seams(ctx), pr_number, head, class, reason)
    end
  end

  # Relit l'objet PR FRAIS et le classe (source de vérité = les champs forge, pas le message d'erreur du
  # merge). get_pull en échec → `:unknown` (on ne devine pas → escalade honnête plutôt qu'une action fausse).
  defp classify_merge_failure(pr_number, %Ctx{} = ctx) do
    case ctx.forge.get_pull(ctx.repo, pr_number, ctx.forge_opts) do
      {:ok, pull} -> Fleet.Pilot.MergeOutcome.classify(pull)
      {:error, _} -> :unknown
    end
  end

  # `:policy` = git mergeable mais la forge refuse. Cause NOMINALE (CI off en dev) : une RE-REQUEST humaine
  # a reset le compteur d'approbations de la branch-protection. On lit la timeline (`pr_rerequested_reviewers`)
  # → le(s) juge(s) re-demandé(s) → on re-dispatche le premier (spawn re-review, sérialisé par le verrou PR ;
  # les suivants au tick d'après). C'est le bouton « redemander un jugement » qui FAIT enfin son job. Aucun
  # re-demandé = blocage de policy non levable mécaniquement (commits signés requis, ou — si un jour activé —
  # CI non verte, à gater par une lecture de status avant d'escalader) → escalade honnête plutôt que wedge muet.
  defp reconverge_policy(pr_number, head, %Ctx{} = ctx) do
    case ctx.forge.pr_rerequested_reviewers(ctx.repo, pr_number, ctx.forge_opts) do
      {:ok, [judge | _]} ->
        Logger.info(
          "StepDispatcher: PR #{ctx.repo}##{pr_number} bloquée par re-request humaine → re-dispatch #{judge}"
        )

        RoleDispatch.dispatch(:judge, pr_number, head, judge, ctx)

      {:ok, []} ->
        ArchEscalation.escalate_merge_blocked(
          arch_seams(ctx),
          pr_number,
          head,
          :policy,
          {:policy, :no_rerequest}
        )

      {:error, reason} ->
        ArchEscalation.escalate_merge_blocked(
          arch_seams(ctx),
          pr_number,
          head,
          :unknown,
          {:rerequest_read_failed, reason}
        )
    end
  end

  # Contrat de frontière de l'écriture d'escalade : Remediation décide, ArchEscalation écrit. On ne
  # lui passe QUE les 3 seams forge (`@enforce_keys` → un accès hors-3-seams ne compile pas), jamais le ctx entier.
  defp arch_seams(%Ctx{} = ctx),
    do: %ArchEscalation.Seams{forge: ctx.forge, repo: ctx.repo, forge_opts: ctx.forge_opts}
end
