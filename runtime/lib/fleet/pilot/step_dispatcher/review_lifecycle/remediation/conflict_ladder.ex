defmodule Fleet.Pilot.StepDispatcher.ReviewLifecycle.Remediation.ConflictLadder do
  @moduledoc """
  Routes merge conflicts through diagnosis, producer rework, an outsider pass and the architect.

  Optional tier 0 (`:pilot_conflict_diagnosis?`, code default off) routes all-semantic
  conflicts to the chief, all-writable to `ConflictApply`, otherwise to the producer.
  Producer rounds use the card's `max_rework_rounds` and forge `[conflict-rework:pr-N`
  markers. The outsider has its own flag (`:pilot_conflict_exception_pass?`) and
  `[conflict-chief:pr-N` counter; exhausted or unavailable stages escalate.

  Markers survive restarts and also select the seal's merge method. Producer/outsider
  markers precede dispatch, so a failed/busy dispatch may consume a round. Counting,
  posting and dispatch are not atomic; comment deduplication does not serialize dispatches.
  Tier 0 posts its report marker after a successful apply, or before the chief handoff.
  """

  require Logger

  alias Fleet.Forge.Protocol
  alias Fleet.Layout
  alias Fleet.Pilot.StepDispatcher.ArchEscalation

  alias Fleet.Forge.Client, as: ForgeClient
  alias Fleet.Pilot.ConflictReport
  alias Fleet.Pilot.StepDispatcher.ReviewLifecycle.Ctx
  alias Fleet.Pilot.StepDispatcher.ReviewLifecycle.RoleDispatch
  alias Fleet.Workflow.Pinning

  @doc false
  @spec run(integer(), String.t(), term(), Ctx.t()) ::
          {:ok, tuple()} | {:skipped, term()} | {:error, term()}
  def run(pr_number, head, reason, %Ctx{} = ctx) do
    if diagnosis_enabled?() do
      case tier0_conflict_route(pr_number, head, reason, ctx) do
        {:handled, result} -> result
        :fall_through -> legacy_conflict_rework(pr_number, head, reason, ctx)
      end
    else
      legacy_conflict_rework(pr_number, head, reason, ctx)
    end
  end

  defp tier0_conflict_route(pr_number, head, reason, %Ctx{} = ctx) do
    case diagnoser().probe(ctx.repo, head, conflict_face_opts(ctx)) do
      # A clean probe contradicts the forge's conflict report: warn and use the budgeted path.
      # A stale base or lagging forge flag are possible explanations, not established causes.
      {:ok, %{totals: %{total: 0}}} ->
        Logger.warning(
          "ConflictProbe: PR ##{pr_number} — the forge reports a conflict, the probe merges " <>
            "clean (0 hunks). Stale probe base or lagging forge flag; falling through to " <>
            "producer rework."
        )

        :fall_through

      {:ok, diagnosis} ->
        tier0_act(tier0_decision(diagnosis), pr_number, head, reason, ctx, diagnosis)

      {:error, reason_probe} ->
        Logger.warning(
          "ConflictProbe: probe failed on PR ##{pr_number} (#{inspect(reason_probe)}) — " <>
            "tier 0 unavailable, falling through to producer rework."
        )

        :fall_through
    end
  end

  # Publish per-hunk DecisionTrace, including refusals, under the conflict resolver's identity;
  # the runtime authors resolution commits. Returned identity/post errors only warn; rendering
  # exceptions propagate. Pinning uses the default ops root, not ctx.opts[:ops_root].
  defp post_conflict_report(pr_number, diagnosis, outcome, %Ctx{} = ctx) do
    body =
      diagnosis
      |> ConflictReport.render(outcome)
      |> Pinning.render(
        work_dir: conflict_report_work_dir(ctx),
        ref: Layout.conflict_ref(pr_number),
        kind: "Rapport",
        label: "conflict",
        repo: ctx.repo
      )

    # Keep the protocol marker outside both report rendering and pinning: the seal reads
    # the forge comment itself to choose its merge method.
    body = body <> "\n\n[conflict-engine:pr-#{pr_number}:#{outcome}]"

    case ForgeClient.as_role(ctx.forge_opts, Fleet.Project.Roles.conflict_resolver_role()) do
      {:ok, role_opts} ->
        case ctx.forge.post_comment(ctx.repo, pr_number, body, role_opts) do
          {:ok, _} ->
            :ok

          {:error, why} ->
            Logger.warning(
              "Remediation: conflict report NOT posted on #{ctx.repo}##{pr_number} " <>
                "(#{inspect(why)}) — the routing stands, only its explanation is missing" <>
                report_loss_consequence(outcome, pr_number)
            )
        end

      {:error, why} ->
        Logger.warning(
          "Remediation: conflict report NOT posted on #{ctx.repo}##{pr_number} — no chief " <>
            "identity (#{inspect(why)}); posting it under the system account would name the " <>
            "wrong owner for the call" <> report_loss_consequence(outcome, pr_number)
        )
    end
  end

  # Without another conflict marker, losing this report also loses the seal's signal to
  # avoid rebase. Other paths may already have left producer/outsider markers.
  defp report_loss_consequence(:auto_resolved, pr_number),
    do:
      " — AND the seal's conflict signal is now MISSING (tier-0 leaves no other mark): the merge " <>
        "will be attempted in `rebase` and misrouted. Repair: post a comment containing " <>
        "`[conflict-engine:pr-#{pr_number}]` on the PR."

  defp report_loss_consequence(_outcome, _pr_number), do: ""

  defp conflict_report_work_dir(%Ctx{} = ctx) do
    dir = Path.join(Layout.ops_root(), Layout.project_name(ctx.repo))
    if File.dir?(dir), do: dir
  end

  @doc false
  # All-semantic skips the producer, not the outsider. This is a routing policy, not
  # proof that the producer cannot resolve the conflict.
  @spec tier0_decision(map()) :: :chief | :apply | :fall_through
  def tier0_decision(%{totals: %{none_trivial?: true}}), do: :chief

  # Trivial is insufficient: whitespace, reordering and competing insertions may need
  # context the engine cannot safely infer before writing.
  def tier0_decision(%{totals: %{all_writable?: true}}), do: :apply
  def tier0_decision(_), do: :fall_through

  # Reuse the outsider counter. The zero passed below describes this shortcut, not
  # a read of the PR's historical producer-round count.
  defp tier0_act(:chief, pr_number, head, reason, ctx, diagnosis) do
    _ = post_conflict_report(pr_number, diagnosis, :all_semantic, ctx)
    do_tier0_chief(pr_number, head, reason, ctx)
  end

  defp tier0_act(:apply, pr_number, head, reason, ctx, diagnosis) do
    case do_tier0_apply(pr_number, head, reason, ctx) do
      {:handled, _} = handled ->
        # Announce auto-resolution only after the applier reports success.
        _ = post_conflict_report(pr_number, diagnosis, :auto_resolved, ctx)
        handled

      other ->
        other
    end
  end

  defp tier0_act(:fall_through, _pr, _head, _reason, _ctx, _diagnosis), do: :fall_through

  defp do_tier0_chief(pr_number, head, reason, ctx) do
    Logger.info(
      "Remediation: PR #{ctx.repo}##{pr_number} conflict is all-semantic → chief exception pass " <>
        "(tier-0, producer rounds skipped on evidence)"
    )

    {:handled, exception_stage(pr_number, head, {:conflict_all_semantic, reason}, ctx, 0)}
  end

  defp do_tier0_apply(pr_number, head, _reason, ctx) do
    case applier().apply(ctx.repo, head, conflict_face_opts(ctx)) do
      {:ok, :auto_resolved} ->
        Logger.info(
          "Remediation: PR #{ctx.repo}##{pr_number} conflict auto-resolved (tier-0, all trivial)"
        )

        {:handled, {:ok, {:auto_resolved, pr_number}}}

      {:error, _} ->
        :fall_through
    end
  end

  defp diagnosis_enabled?,
    do: Application.get_env(:lcars_fleet, :pilot_conflict_diagnosis?, false)

  # Use the PR's target base and face worktree; a default main/code pairing is wrong for ops PRs.
  defp conflict_face_opts(%Ctx{} = ctx) do
    base = Keyword.fetch!(ctx.opts, :pr_base_branch)

    name = Layout.project_name(ctx.repo)

    # Layout owns the face set. A stacked feature base has no face classification:
    # use the code worktree because the branch name cannot identify its originating face.
    dir =
      case Layout.face_of(base) do
        nil -> Path.join(Layout.code_root(), name)
        face -> Path.join(Layout.face_root(face), name)
      end

    [base_branch: "origin/" <> base, dir: dir]
  end

  defp diagnoser,
    do: Application.get_env(:lcars_fleet, :pilot_conflict_diagnoser, Fleet.Pilot.ConflictProbe)

  defp applier,
    do: Application.get_env(:lcars_fleet, :pilot_conflict_applier, Fleet.Pilot.ConflictApply)

  # The fleet's outsider pass has its own switch. Disabling the external diagnosis
  # engine must not disable a pass that uses only forge markers and role dispatch.
  defp producer_exhausted(pr_number, head, reason, %Ctx{} = ctx, producer_rounds) do
    exception_stage(pr_number, head, reason, ctx, producer_rounds)
  end

  defp exception_stage(pr_number, head, reason, %Ctx{} = ctx, producer_rounds) do
    # Both exhaustion and the all-semantic shortcut check the flag here; name a disabled stage.
    if exception_pass_enabled?() do
      do_exception_stage(pr_number, head, reason, ctx, producer_rounds)
    else
      escalate_exhausted(
        pr_number,
        head,
        {:exception_pass_disabled, reason},
        ctx,
        producer_rounds
      )
    end
  end

  defp exception_pass_enabled?,
    do: Application.get_env(:lcars_fleet, :pilot_conflict_exception_pass?, false)

  defp do_exception_stage(pr_number, head, reason, %Ctx{} = ctx, producer_rounds) do
    marker = "[conflict-chief:pr-#{pr_number}"
    count = ctx.forge.count_comments_marked(ctx.repo, pr_number, marker, ctx.forge_opts)

    case exception_stage_decision(count) do
      :dispatch ->
        # Skips escalate, including busy roles; other errors return unchanged even if a marker was posted.
        case dispatch_exception_rework(pr_number, head, ctx) do
          {:skipped, why} ->
            Logger.warning(
              "Remediation: PR #{ctx.repo}##{pr_number} chief exception pass NOT dispatched " <>
                "(#{inspect(why)}) — escalating to the arch rather than dropping the conflict"
            )

            escalate_exhausted(
              pr_number,
              head,
              {:exception_pass_undispatchable, why, reason},
              ctx,
              producer_rounds
            )

          other ->
            other
        end

      :escalate ->
        escalate_exhausted(pr_number, head, {:exception_pass_spent, reason}, ctx, producer_rounds)
    end
  end

  @doc false
  # Unreadable counts take the same escalation path as a spent pass.
  @spec exception_stage_decision({:ok, integer()} | {:error, term()}) :: :dispatch | :escalate
  def exception_stage_decision({:ok, spent}) when is_integer(spent) and spent < 1, do: :dispatch
  def exception_stage_decision(_), do: :escalate

  # The exception brief speaks to an outsider, not an owner resuming their own work.
  # This forge-visible prefix is a budget protocol: renaming requires a migration that
  # counts old and new prefixes during the transition, or existing PRs regain a pass.
  defp dispatch_exception_rework(pr_number, head, %Ctx{} = ctx) do
    signature = "[conflict-chief:pr-#{pr_number}:round-1]"

    # Use the PR target base in the human-facing report as well as the conflict worktree.
    base = Keyword.fetch!(ctx.opts, :pr_base_branch)

    body =
      "⚠ Conflit de merge non résolu par le producteur (budget de rework épuisé). Passe " <>
        "d'exception : le **chief** tente une dernière résolution avant escalade humaine — il " <>
        "intègre `origin/#{base}`, résout, et re-livre sur CETTE PR ; les juges re-jugeront le " <>
        "nouveau head.\n\n" <> signature

    comment_opts =
      ctx.forge_opts
      |> Keyword.put(:dedup_signature, signature)
      |> Keyword.put(:dedup_any_author, true)

    case ctx.forge.post_comment(ctx.repo, pr_number, body, comment_opts) do
      {:ok, _} ->
        # Resolver and merge signatory are separate capabilities; changing one must not move the other.
        RoleDispatch.dispatch(
          :conflict_rework_exception,
          pr_number,
          head,
          Fleet.Project.Roles.conflict_resolver_role(),
          ctx
        )

      {:error, marker_reason} ->
        ArchEscalation.escalate_merge_blocked(
          Ctx.arch_seams(ctx),
          pr_number,
          head,
          :conflict,
          {:conflict_exception_marker_unpostable, marker_reason}
        )
    end
  end

  defp escalate_exhausted(pr_number, head, reason, %Ctx{} = ctx, producer_rounds) do
    ArchEscalation.escalate_merge_blocked(
      Ctx.arch_seams(ctx),
      pr_number,
      head,
      :conflict,
      {:conflict_rework_exhausted, producer_rounds, reason}
    )
  end

  # Producer budget shares the review policy but uses its own conflict-marker counter.
  # Returned budget/count errors escalate directly; exhaustion tries the outsider stage.
  defp legacy_conflict_rework(pr_number, head, reason, %Ctx{} = ctx) do
    marker_prefix = "[conflict-rework:pr-#{pr_number}"

    with {:ok, {issue_n, _producer}} <- RoleDispatch.parse_feature_branch_or_skip(head),
         {:ok, budget} <- Ctx.rework_budget(ctx, issue_n),
         {:ok, rounds} <-
           ctx.forge.count_comments_marked(ctx.repo, pr_number, marker_prefix, ctx.forge_opts) do
      if rounds < budget do
        dispatch_conflict_rework(pr_number, head, rounds + 1, budget, ctx)
      else
        producer_exhausted(pr_number, head, reason, ctx, rounds)
      end
    else
      {:skipped, _} = skip ->
        skip

      {:error, err_reason} ->
        ArchEscalation.escalate_merge_blocked(
          Ctx.arch_seams(ctx),
          pr_number,
          head,
          :conflict,
          {:conflict_budget_unreadable, err_reason}
        )
    end
  end

  # Post before dispatch: write failure escalates without spending an unrecorded round.
  # A successful post followed by a skipped/failed dispatch still consumes the marker;
  # an already-present deduplicated marker does not itself prevent another dispatch.
  defp dispatch_conflict_rework(pr_number, head, round, budget, %Ctx{} = ctx) do
    signature = "[conflict-rework:pr-#{pr_number}:round-#{round}]"

    base = Keyword.fetch!(ctx.opts, :pr_base_branch)

    body =
      "⚠ Conflit de merge avec `#{base}` (des briques sœurs ont atterri depuis la coupe de cette " <>
        "branche). Rework automatique round #{round}/#{budget} : le producteur intègre " <>
        "`origin/#{base}`, résout, et re-livre sur CETTE PR — les juges re-jugeront le nouveau " <>
        "head.\n\n" <> signature

    comment_opts =
      ctx.forge_opts
      |> Keyword.put(:dedup_signature, signature)
      |> Keyword.put(:dedup_any_author, true)

    case ctx.forge.post_comment(ctx.repo, pr_number, body, comment_opts) do
      {:ok, _} ->
        RoleDispatch.dispatch(:conflict_rework, pr_number, head, producer_of!(head), ctx)

      {:error, reason} ->
        ArchEscalation.escalate_merge_blocked(
          Ctx.arch_seams(ctx),
          pr_number,
          head,
          :conflict,
          {:conflict_marker_unpostable, reason}
        )
    end
  end

  # The caller already validated this feature-branch shape.
  defp producer_of!(head) do
    {:ok, {_issue_n, producer}} = Protocol.parse_feature_branch(head)
    producer
  end
end
