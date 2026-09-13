defmodule Fleet.Pilot.StepDispatcher.ReviewLifecycle do
  @moduledoc """
  Routes the review state supplied by StepDispatcher to judge dispatch, rework,
  arbitration, adoption or promotion. LCARS aggregates jury decisions independently
  of forge branch-protection rules; merge failures still require forge-state recovery.

  RoleDispatch is the shared execution leaf for routing and Remediation, avoiding a
  dependency cycle. Spawn and ArchEscalation receive narrow dependency structs;
  MergeAndPromote owns the shared seal. This module also finalizes the parent issue
  unlock after promotion. No local reservation prevents concurrent promotion callers.
  """

  require Logger

  alias Fleet.Pilot.StepDispatcher.ArchEscalation
  alias Fleet.Pilot.StepDispatcher.Spawn
  alias Fleet.Pilot.WorkflowMapNav
  alias Fleet.Project.Roles
  alias Fleet.Workflow.Loader

  alias Fleet.Pilot.StepDispatcher.ReviewLifecycle.Remediation

  alias Fleet.Pilot.StepDispatcher.ReviewLifecycle.CiGate
  alias Fleet.Pilot.StepDispatcher.ReviewLifecycle.RoleDispatch
  alias Fleet.Pilot.StepDispatcher.ReviewLifecycle.VerdictException

  defmodule Ctx do
    @moduledoc """
    Review dependencies and options, constructed by StepDispatcher and narrowed at leaf calls.
    """
    @enforce_keys [
      :forge,
      :loader,
      :workflow_map_loader,
      :spawner,
      :task_queue,
      :resolver,
      :repo,
      :forge_opts,
      :wake_recovery,
      :opts
    ]
    defstruct @enforce_keys

    @type t :: %__MODULE__{
            forge: module(),
            loader: module(),
            # WorkflowMapNav accepts function or module loaders; binary forms preserve catalogue options.
            workflow_map_loader:
              (String.t(), keyword() -> map()) | (String.t() -> map()) | module(),
            spawner: module(),
            task_queue: module(),
            resolver: (String.t(), keyword() -> {:ok, map() | nil} | {:error, term()}),
            repo: String.t(),
            forge_opts: keyword(),
            wake_recovery: (String.t(), (-> any()), keyword() -> :ok | {:error, term()}),
            opts: keyword()
          }

    @doc false
    # Convert full review context to the escalation writer's forge dependencies.
    @spec arch_seams(t()) :: Fleet.Pilot.StepDispatcher.ArchEscalation.Seams.t()
    def arch_seams(%__MODULE__{} = ctx) do
      %Fleet.Pilot.StepDispatcher.ArchEscalation.Seams{
        forge: ctx.forge,
        repo: ctx.repo,
        forge_opts: ctx.forge_opts
      }
    end

    @doc false
    # Read the engraved card's budget in the repo catalogue; judge/conflict rework share it.
    # Missing max_rework_rounds raises at fetch!, rather than returning a typed error.
    @spec rework_budget(t(), integer()) :: {:ok, integer()} | {:error, term()}
    def rework_budget(%__MODULE__{} = ctx, issue_n) do
      with {:ok, {map_name, _step}} when is_binary(map_name) <-
             Fleet.Pilot.StepDispatcher.Spawn.route_for(
               ctx.forge,
               ctx.repo,
               issue_n,
               ctx.forge_opts
             ),
           {:ok, workflow_map} <-
             WorkflowMapNav.safe_load(
               ctx.workflow_map_loader,
               map_name,
               Loader.card_opts_for_repo(ctx.repo)
             ) do
        {:ok, Map.fetch!(workflow_map, "max_rework_rounds")}
      else
        # Typed route/load failures are handled; unexpected route shapes still raise.
        {:ok, nil} -> {:error, :routeless}
        {:error, _} = err -> err
      end
    end
  end

  @doc """
  Routes the caller's union of requested and historical jury roles using commit-scoped
  verdicts and findings. Pending jurors precede rework; only all-present verdicts can
  reach approval or policy arbitration. No observed jury adopts the card's jury, or
  promotes directly when that card has no judges.

  CI is checked before dispatching a pending juror. Approved/no-jury promotion does
  not pass through this gate; forge merge policy may still trigger remediation.
  Inputs must already follow the jury's typed vocabulary.
  """
  @spec dispatch_by_verdicts([String.t()], map(), map(), integer(), String.t(), Ctx.t()) ::
          {:ok, tuple()} | {:skipped, term()} | {:error, term()}
  def dispatch_by_verdicts(requested, verdicts, findings, pr_number, head, %Ctx{} = ctx) do
    # Use Jury.review_outcome/5 so findings/policy arbitration shares the status reader's predicate.
    case Fleet.Forge.Client.Jury.review_outcome(
           requested,
           verdicts,
           findings,
           issue_card_verdict_policy(head, ctx),
           Roles.gatekeeper_role(ctx.opts)
         ) do
      {:pending, [next | _]} ->
        # Reject a non-fleet head before paying for CI reads or scheduling an unusable judge.
        with {:ok, _} <- RoleDispatch.parse_feature_branch_or_skip(head) do
          gate_then_dispatch(pr_number, head, next, ctx)
        end

      :no_jury ->
        # Prefer the engraved card's jury, with project fallback when its resolution fails.
        case issue_card_jury(head, ctx) do
          [] -> promote_or_route(pr_number, head, ctx)
          card_jury -> adopt_orphan_pr(pr_number, card_jury, ctx)
        end

      :changes_requested ->
        Remediation.dispatch_rework(pr_number, head, ctx)

      # Favorable verdicts with policy-blocking findings need arbitration.
      # VerdictException distinguishes an unarmed, spent or undispatchable exception pass.
      :gray_zone ->
        VerdictException.dispatch(
          pr_number,
          head,
          findings,
          issue_card_verdict_policy(head, ctx),
          ctx
        )

      :approved ->
        promote_or_route(pr_number, head, ctx)
    end
  end

  # Check required CI before spending a pending judge; carry measured facts into its brief.
  defp gate_then_dispatch(pr_number, head, next, %Ctx{} = ctx) do
    case CiGate.decide(pr_number, head, ctx, fn -> issue_card_ci(head, ctx) end) do
      {:proceed, fact} ->
        RoleDispatch.dispatch(:judge, pr_number, head, next, with_ci_fact(ctx, fact))

      {:refuse, :ci_red, message} ->
        Remediation.ci_red_rework(pr_number, head, message, ctx)

      # Keep emitted wait reasons literal: the reverse source contract must see each reason.
      {:wait, :ci_pending} ->
        {:skipped, :ci_pending}

      {:wait, {:ci_head_unreadable, why}} ->
        {:skipped, {:ci_head_unreadable, why}}

      {:wait, {:ci_unreadable, why}} ->
        {:skipped, {:ci_unreadable, why}}

      {:wait, {:ci_deadline_unreachable, why}} ->
        {:skipped, {:ci_deadline_unreachable, why}}

      {:escalate, class, message} ->
        Remediation.ci_stalled(pr_number, head, class, message, ctx)
    end
  end

  # Re-read merge failures to classify state; provenance refusal has a separate escalation path.
  defp promote_or_route(pr_number, head, %Ctx{} = ctx) do
    case promote_pr(pr_number, head, ctx) do
      {:error, {:merge, reason}} ->
        Remediation.route_merge_failure(pr_number, head, reason, ctx)

      # Escalate incoherent provenance instead of repeatedly attempting the same seal.
      {:error, {:provenance_incoherent, reason}} ->
        ArchEscalation.escalate_merge_blocked(
          Ctx.arch_seams(ctx),
          pr_number,
          head,
          :provenance_incoherent,
          reason
        )

      other ->
        other
    end
  end

  # Shared lookup rule, not a cached snapshot: each reader resolves the route/card again.
  # Any returned lookup failure falls back to project, including transient read errors.
  defp issue_card(head, %Ctx{} = ctx) do
    with {:ok, {issue_n, _producer}} <- RoleDispatch.parse_feature_branch_or_skip(head),
         {:ok, {map_name, _step}} <-
           Spawn.route_for(
             ctx.forge,
             ctx.repo,
             issue_n,
             ctx.forge_opts
           ),
         {:ok, map} when is_map(map) <-
           WorkflowMapNav.safe_load(
             ctx.workflow_map_loader,
             map_name,
             Loader.card_opts_for_repo(ctx.repo)
           ) do
      {:ok, map}
    else
      _ -> :project
    end
  end

  # The engraved card's jury, else the project card's. Same fallback shape as the completer's
  # `step_run_jury` twin.
  defp issue_card_jury(head, %Ctx{} = ctx) do
    case issue_card(head, ctx) do
      # Through Roles.jury/2 (not the raw key): the reviewer_roles injection seam keeps priority.
      {:ok, %{"jury" => jury} = map} when is_list(jury) -> Roles.jury(map, ctx.opts)
      _ -> Roles.project_jury(ctx.repo, ctx.opts)
    end
  end

  # Roles.verdict_policy_for/4 owns policy resolution for both dispatch and architect status.
  defp issue_card_verdict_policy(head, %Ctx{} = ctx) do
    case RoleDispatch.parse_feature_branch_or_skip(head) do
      {:ok, {issue_n, _producer}} ->
        Roles.verdict_policy_for(
          ctx.forge,
          ctx.repo,
          issue_n,
          Keyword.put(ctx.opts, :forge_opts, ctx.forge_opts)
        )

      # Without a fleet issue id, use project policy.
      _ ->
        Roles.project_verdict_policy(ctx.repo, ctx.opts)
    end
  end

  # CI and jury share the lookup rule; their separate reads can observe different card versions.
  # Public for focused checks that authored policy reaches the gate.
  @doc false
  @spec issue_card_ci(String.t(), Ctx.t()) :: :required | :ignore
  def issue_card_ci(head, %Ctx{} = ctx) do
    case issue_card(head, ctx) do
      {:ok, map} -> Roles.ci(map)
      :project -> Roles.project_ci(ctx.repo, ctx.opts)
    end
  end

  @doc false
  # Public counterpart for checking jury/CI selection on a stable fixture.
  @spec issue_card_jury_of(String.t(), Ctx.t()) :: [String.t()]
  def issue_card_jury_of(head, %Ctx{} = ctx), do: issue_card_jury(head, ctx)

  # Forward the measured CI fact to BriefBuilder. A nil fact leaves existing opts unchanged.
  defp with_ci_fact(%Ctx{} = ctx, nil), do: ctx

  defp with_ci_fact(%Ctx{} = ctx, fact),
    do: %{ctx | opts: Keyword.put(ctx.opts, :ci_fact, fact)}

  # Set reviewers when no jury is observed; this does not prove the PR was created by a human.
  # Return the forge request result. Later polling may retry if its snapshot still has no jury.
  defp adopt_orphan_pr(pr_number, reviewers, %Ctx{} = ctx) do
    case ctx.forge.request_review(ctx.repo, pr_number, reviewers, ctx.forge_opts) do
      :ok -> {:ok, {:adopted, pr_number, reviewers}}
      {:error, reason} -> {:error, {:adopt_failed, reason}}
    end
  end

  # MergeAndPromote owns signing, seal and explicit close. No local lock is taken here.
  defp promote_pr(pr_number, head, %Ctx{} = ctx) do
    with {:ok, {issue_n, producer}} <- RoleDispatch.parse_feature_branch_or_skip(head) do
      # Use the shared chief-merge/decision-promotion seal instead of recreating signing here.
      case Fleet.Pilot.MergeAndPromote.merge_and_promote(
             ctx.forge,
             ctx.repo,
             pr_number,
             issue_n,
             producer,
             ctx.forge_opts,
             [
               head_branch: head,
               # Align the face named by the PR destination.
               base_branch: Keyword.fetch!(ctx.opts, :pr_base_branch)
               # Pass the same injected face roots used by policy readers.
             ] ++ Keyword.take(ctx.opts, [:code_root, :ops_root])
           ) do
        :ok ->
          # Target the issue-scoped producer id, not a shared project pod that may serve another ticket.
          # Kill result is discarded; it does not establish that a producer exited.
          _ =
            Spawn.safe_kill(ctx.spawner, Fleet.PodId.for_issue(ctx.repo, issue_n, producer))

          # Finalize the parent issue separately from PR review locks, using producer stopwatch identity.
          # :delivered selects the terminal feed/wake event, not an intermediate step milestone.
          # Closed issues leave open-item polling, so verify unlock and attempt bounded retries.
          # Keep this outside the seal: lock lifecycle and stopwatch identity belong to its caller.
          log_unlock_outcome(
            finalize_issue_unlock(ctx, issue_n, producer),
            ctx,
            pr_number,
            issue_n
          )

          {:ok, {:merged, pr_number}}

        {:error, _} = err ->
          err
      end
    end
  end

  # Retry returned unlock errors immediately; preserve merge success after persistent failure.
  # Closed issues have no natural retry through open-item polling.
  @issue_unlock_attempts 3
  # Log actual merge/promotion identities; the merge method is not always rebase.
  defp log_unlock_outcome(:ok, ctx, pr_number, issue_n) do
    Logger.info(
      "StepDispatcher: PROMOTE pr=#{ctx.repo}##{pr_number} issue=##{issue_n} " <>
        "(judges OK → chief merged, gatekeeper promoted + explicit close ; " <>
        "eng killed, issue lock released)"
    )
  end

  # A residual lock on a closed issue needs intervention. Request an incident, but its returned
  # result is discarded: the preceding log does not prove that an incident was opened.
  defp log_unlock_outcome({:error, reason}, ctx, pr_number, issue_n) do
    Logger.error(
      "StepDispatcher: PROMOTE pr=#{ctx.repo}##{pr_number} issue=##{issue_n} MERGED+SEALED+CLOSED " <>
        "but issue lock NOT released (#{inspect(reason)}) — residual lcars-in-flight + running " <>
        "stopwatch on the CLOSED issue, NOT re-polled (open-issue poll skips it) — an incident is " <>
        "opened on the forge, and the cleanup is MANUAL: no rail reclaims it"
    )

    escalate =
      Keyword.get(ctx.opts, :escalate_fun, &Fleet.Pilot.IncidentRegistry.escalate_gated/5)

    _ =
      escalate.(
        :issue_lock_residual,
        "#{ctx.repo}##{issue_n}",
        {:unlock_failed, reason},
        "issue_lock_residual:#{ctx.repo}##{issue_n}",
        ctx.forge_opts
      )

    :ok
  end

  defp finalize_issue_unlock(%Ctx{} = ctx, issue_n, producer, attempt \\ 1) do
    case Fleet.Pilot.StepRunCompleter.unlock(
           ctx.forge,
           ctx.repo,
           issue_n,
           ctx.forge_opts,
           producer,
           :delivered
         ) do
      {:ok, _} ->
        :ok

      {:error, reason} when attempt < @issue_unlock_attempts ->
        Logger.warning(
          "StepDispatcher: PROMOTE issue ##{issue_n} unlock attempt " <>
            "#{attempt}/#{@issue_unlock_attempts} FAILED (#{inspect(reason)}) — retrying"
        )

        finalize_issue_unlock(ctx, issue_n, producer, attempt + 1)

      {:error, reason} ->
        {:error, reason}
    end
  end
end
