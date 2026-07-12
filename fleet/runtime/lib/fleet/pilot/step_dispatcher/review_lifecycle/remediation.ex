defmodule Fleet.Pilot.StepDispatcher.ReviewLifecycle.Remediation do
  @moduledoc """
  BOUNDED remediation of the review flow, extracted from `ReviewLifecycle`: producer re-spawn for REWORK
  (verdict `changes_requested`), and ROUTING of a merge failure by its real cause
  (`route_merge_failure`) — always under a brake / an honest classification, never infinite churn
  nor action on a false premise.

  ## Rework — anti-churn brake

  FORGE-NATIVE counter (`count_change_request_rounds` = number of REQUEST_CHANGES reviews, monotonic),
  budget = the issue MAP's `spec.max_rework_rounds` (DATA, the SAME brake as the issue rebound — no more
  hand-aligned hard-coded `:max_pr_rework_rounds` default). Beyond that → ARCH ESCALATION. Unreadable
  budget/route/map → we DO NOT re-spawn blindly: escalation (symmetric to `rebound` on the StepRunConsumer side).

  ## Merge failure — honest classification (`route_merge_failure`)

  A merge can fail for NATURALLY distinct reasons (`Fleet.Pilot.MergeOutcome`, re-read from
  the PR object): already-merged / cancelled (human close) / draft / policy (human re-request) / real git
  conflict / unknown. Each has its own routing. The historical catch-all "any failure = conflict →
  dispatch eng rebase" is removed (the eng is forge-blind, it CANNOT rebase → wall 2026-07-07).
  The throttle for escalated cases = the `lcars-awaits-arch` lock laid by `ArchEscalation` (the poller
  SKIPS the issue), not an IncidentRegistry (no more resolution loop to bound here).

  The DECISION lives here; the EXECUTION of the re-spawn descends to `RoleDispatch` (leaf shared with the
  judge spawn — no fork of the mechanics); the WRITING of the human escalation descends to
  `ArchEscalation` (narrow seams rebuilt HERE, never the whole `Ctx`).
  """

  require Logger

  # Writing the human escalation (IMPURE cluster): Remediation DECIDES (rework budget /
  # merge-failure classification), ArchEscalation WRITES (deduplicated gatekeeper comment + `awaits-arch` lock).
  alias Fleet.Pilot.StepDispatcher.ArchEscalation

  alias Fleet.Pilot.StepDispatcher.ReviewLifecycle.Ctx
  alias Fleet.Pilot.StepDispatcher.ReviewLifecycle.RoleDispatch

  @doc """
  Judge rework: the PR carries a current REQUEST_CHANGES verdict (the state was already read by
  `dispatch_review` → no re-read here) → the PRODUCER (git_native role from head.ref)
  resumes to fix on the same PR. Idempotent (PR lock).

  ANTI-CHURN BRAKE: without a counter, this path would re-spawn the producer on every tick —
  the `rebound` brake (workflow_map budget, StepRunConsumer) is NEVER called on the
  PR-review-driven path → INFINITE rework if the eng never satisfies the judge. Forge-native
  bounding (cf. moduledoc), beyond that → arch escalation, end of churn.
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
          # Budget not verifiable (unreadable route/map) OR unreadable counter → we do NOT enter a
          # blind loop: we escalate to the arch (symmetric to the issue brake `rework_budget_unreadable`).
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

  # PR rework budget = the SAME `spec.max_rework_rounds` as the issue brake (the pipeline's SINGLE churn
  # policy, read as DATA — no more hand-aligned hard-coded default). Issue route → map name →
  # budget. Routeless / unreadable map → `{:error}`: the caller escalates (never a blind loop).
  defp pr_rework_budget(%Ctx{} = ctx, issue_n) do
    with {:ok, {map_name, _step}} when is_binary(map_name) <-
           Fleet.Pilot.StepDispatcher.Spawn.route_for(
             ctx.forge,
             ctx.repo,
             issue_n,
             ctx.forge_opts
           ),
         {:ok, workflow_map} <-
           Fleet.Pilot.WorkflowMapNav.safe_load(ctx.workflow_map_loader, map_name) do
      {:ok, Map.fetch!(workflow_map, "max_rework_rounds")}
    else
      # Les specs de route_for/4 (Z6c : appel direct typé, plus une capture opaque) et
      # de safe_load couvrent tout — l'ancien fourre-tout `other -> :route_unreadable`
      # était mort-par-spec (prouvé dialyzer au gate final Z7, retiré).
      {:ok, nil} -> {:error, :routeless}
      {:error, _} = err -> err
    end
  end

  @doc """
  Routing of a MERGE FAILURE by its REAL cause (`Fleet.Pilot.MergeOutcome`, re-read from the fresh PR
  object — never the "conflict" catch-all). Replaces the old `dispatch_conflict_resolution` which
  ALWAYS assumed a git conflict and dispatched the producer to rebase — IMPOSSIBLE (the pod is
  forge-blind, no credentials) → wall observed live 2026-07-07 on a mere policy window.

    * `:merged`   → someone merged in the meantime (multi-actor race / replay) → `{:ok, :merged}` idempotent.
    * `:closed`   → a human CLOSED the PR (cancellation) → the brick is dead, we don't push on.
    * `:draft`    → a human moved it back to draft (parked) → skip; `dispatch_review` re-skips it
                    while draft (dispatch-judge guard).
    * `:policy`   → git-mergeable but branch-protection refuses (approvals cleared by a
                    human RE-REQUEST, CI…) → we re-converge: re-dispatch the re-requested judge (timeline).
                    No re-requested = policy block we can't lift mechanically → honest escalation.
    * `:conflict` / `:unknown` → not auto-resolvable by the system (forge-blind barrier) → HONEST
                    arch escalation (no more lying brief "after a rebase" nor impossible-eng-dispatch).
                    Mechanical conflict resolution (system rebase in scratch) is a later increment.
  """
  @spec route_merge_failure(integer(), String.t(), term(), Ctx.t()) ::
          {:ok, tuple()} | {:skipped, term()} | {:error, term()}
  def route_merge_failure(pr_number, head, reason, %Ctx{} = ctx) do
    case classify_merge_failure(pr_number, ctx) do
      :merged ->
        {:ok, {:merged, pr_number}}

      :closed ->
        Logger.info(
          "StepDispatcher: PR #{ctx.repo}##{pr_number} closed (human cancellation) → merge abandoned"
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

  # Re-reads the FRESH PR object and classifies it (source of truth = the forge fields, not the merge
  # error message). get_pull failing → `:unknown` (we don't guess → honest escalation rather than a wrong action).
  defp classify_merge_failure(pr_number, %Ctx{} = ctx) do
    case ctx.forge.get_pull(ctx.repo, pr_number, ctx.forge_opts) do
      {:ok, pull} -> Fleet.Pilot.MergeOutcome.classify(pull)
      {:error, _} -> :unknown
    end
  end

  # `:policy` = git-mergeable but the forge refuses. NOMINAL cause (CI off in dev): a human RE-REQUEST
  # reset the branch-protection approval counter. We read the timeline (`pr_rerequested_reviewers`)
  # → the re-requested judge(s) → we re-dispatch the first (spawn re-review, serialized by the PR lock;
  # the rest on the next tick). It's the "re-request a judgment" button that FINALLY does its job. No
  # re-requested = policy block not mechanically liftable (signed commits required, or — if ever enabled —
  # CI not green, to be gated by a status read before escalating) → honest escalation rather than a silent wedge.
  defp reconverge_policy(pr_number, head, %Ctx{} = ctx) do
    case ctx.forge.pr_rerequested_reviewers(ctx.repo, pr_number, ctx.forge_opts) do
      {:ok, [judge | _]} ->
        Logger.info(
          "StepDispatcher: PR #{ctx.repo}##{pr_number} blocked by human re-request → re-dispatch #{judge}"
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

  # Boundary contract of the escalation writing: Remediation decides, ArchEscalation writes. We pass
  # it ONLY the 3 forge seams (`@enforce_keys` → an out-of-3-seams access does not compile), never the whole ctx.
  defp arch_seams(%Ctx{} = ctx),
    do: %ArchEscalation.Seams{forge: ctx.forge, repo: ctx.repo, forge_opts: ctx.forge_opts}
end
