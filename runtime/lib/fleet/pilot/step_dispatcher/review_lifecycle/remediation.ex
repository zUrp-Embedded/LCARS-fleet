defmodule Fleet.Pilot.StepDispatcher.ReviewLifecycle.Remediation do
  @moduledoc """
  Routes review rework and merge refusals to RoleDispatch, ConflictLadder or ArchEscalation.
  Judge rework compares forge review/publish counts with the engraved card's budget;
  returned unreadable budget/count errors escalate. Policy-refused merges inspect CI
  even when the card ignores CI for jury admission.

  Two CI markers serve different paths: pre-jury ci-red is written on the PR before
  dispatch; post-merge-refusal ci-rework is written on the issue after a success return.
  Neither is an atomic reservation. Failed writes and admission failures can make the
  recorded count differ from work actually started; see the corresponding helpers.
  """

  require Logger

  alias Fleet.Pilot.StepDispatcher.ReviewLifecycle.Remediation.ConflictLadder

  alias Fleet.Forge.Payload
  alias Fleet.Forge.Protocol
  alias Fleet.Pilot.StepDispatcher.ArchEscalation

  alias Fleet.Pilot.StepDispatcher.ReviewLifecycle.CiGate
  alias Fleet.Pilot.StepDispatcher.ReviewLifecycle.Ctx
  alias Fleet.Pilot.StepDispatcher.ReviewLifecycle.RoleDispatch

  @doc """
  Reworks with the producer parsed from the feature branch. The caller has already
  classified the verdict. Publish failures above the card budget escalate first;
  otherwise review rounds at or below budget permit dispatch. Returned read errors
  escalate, while malformed data or missing required fields can raise.
  """
  @spec dispatch_rework(integer(), String.t(), Ctx.t()) ::
          {:ok, tuple()} | {:skipped, term()} | {:error, term()}
  def dispatch_rework(pr_number, head, %Ctx{} = ctx) do
    case Protocol.parse_feature_branch(head) do
      {:ok, {issue_n, producer_role}} ->
        with {:ok, budget} <- Ctx.rework_budget(ctx, issue_n),
             {:ok, rounds} <-
               ctx.forge.count_change_request_rounds(ctx.repo, pr_number, ctx.forge_opts),
             # Same budget bounds consecutive same-base publish failures.
             {:ok, publish_fails} <-
               count_publish_failures(ctx, issue_n) do
          rework_verdict(pr_number, head, producer_role, ctx, {budget, rounds, publish_fails})
        else
          # Unverifiable brake escalates instead of looping blind.
          {:error, reason} ->
            ArchEscalation.escalate_rework(
              Ctx.arch_seams(ctx),
              pr_number,
              head,
              {:budget_unreadable, reason}
            )
        end

      :error ->
        {:skipped, :not_fleet_branch}
    end
  end

  defp ci_pending_or_stalled(pr_number, head, %Ctx{} = ctx) do
    case CiGate.pending_stalled?(pr_number, head, ctx) do
      :stalled ->
        Logger.info(
          "StepDispatcher: PR #{ctx.repo}##{pr_number} — CI PENDANTE au-delà de la borne → arch"
        )

        ArchEscalation.escalate_merge_blocked(
          Ctx.arch_seams(ctx),
          pr_number,
          head,
          :ci_stalled,
          "plus de #{div(CiGate.pending_deadline_sec(), 60)} min sans verdict sur la tête de la PR"
        )

      _waiting_or_unknown ->
        {:skipped, :ci_pending}
    end
  end

  # Publication failures take precedence over review rounds: another rework cannot help
  # if its output repeatedly fails to reach the forge. Both use the same card budget.
  defp rework_verdict(pr_number, head, producer_role, ctx, {budget, rounds, publish_fails}) do
    cond do
      publish_fails > budget ->
        ArchEscalation.escalate_publish_failures(
          Ctx.arch_seams(ctx),
          pr_number,
          head,
          %{publish_failures: publish_fails, budget: budget}
        )

      rounds <= budget ->
        RoleDispatch.dispatch(:rework, pr_number, head, producer_role, ctx)

      true ->
        ArchEscalation.escalate_rework(
          Ctx.arch_seams(ctx),
          pr_number,
          head,
          %{rounds: rounds, budget: budget}
        )
    end
  end

  # Post-merge CI rework needs a separate counter because failed CI creates no review verdict.
  # Write its marker only after a success return; busy/capacity skips consume no counted round.
  defp dispatch_ci_rework(pr_number, head, %Ctx{} = ctx) do
    case Protocol.parse_feature_branch(head) do
      {:ok, {issue_n, _producer_role}} ->
        with {:ok, budget} <- Ctx.rework_budget(ctx, issue_n),
             {:ok, spent} <-
               ctx.forge.count_comments_marked(
                 ctx.repo,
                 issue_n,
                 Protocol.ci_rework_prefix(issue_n),
                 ctx.forge_opts
               ) do
          ci_rework_verdict(pr_number, head, issue_n, ctx, {budget, spent})
        else
          {:error, reason} ->
            ArchEscalation.escalate_rework(
              Ctx.arch_seams(ctx),
              pr_number,
              head,
              {:budget_unreadable, reason}
            )
        end

      :error ->
        {:skipped, :not_fleet_branch}
    end
  end

  defp ci_rework_verdict(pr_number, head, issue_n, ctx, {budget, spent}) do
    if spent >= budget do
      ArchEscalation.escalate_rework(
        Ctx.arch_seams(ctx),
        pr_number,
        head,
        %{ci_reworks: spent, budget: budget}
      )
    else
      record_ci_rework(pr_number, head, issue_n, ctx, dispatch_rework(pr_number, head, ctx))
    end
  end

  defp record_ci_rework(pr_number, head, issue_n, %Ctx{} = ctx, {:ok, _} = dispatched) do
    sha = head_sha(head, pr_number, ctx)
    marker = Protocol.ci_rework_marker(issue_n, sha)

    body =
      "⚠ Rework demandé par une CI ROUGE (aucune review ne l'a demandé) — le round est compté : " <>
        "les reworks CI s'accumulent sur ce ticket, l'architecte est saisi au-delà du budget de la " <>
        "carte.\n\n" <> marker

    case ctx.forge.post_comment(ctx.repo, issue_n, body, ctx.forge_opts) do
      {:ok, _} ->
        :ok

      {:error, reason} ->
        # Marker failure undercounts a successful dispatch; there is no rollback or repair here.
        # Conversely, wake_unreached admission is not counted because it returns an error.
        Logger.warning(
          "StepDispatcher: ci-rework marker NOT recorded on #{ctx.repo}##{issue_n} " <>
            "(#{inspect(reason)}) — ce round ne comptera pas dans le frein"
        )
    end

    dispatched
  end

  defp record_ci_rework(_pr_number, _head, _issue_n, %Ctx{}, not_dispatched), do: not_dispatched

  # Minimal forge seams without the optional publish counter read zero failures.
  defp count_publish_failures(%Ctx{} = ctx, issue_n) do
    if Fleet.Opts.exported?(ctx.forge, :count_publish_failures, 3) do
      ctx.forge.count_publish_failures(ctx.repo, issue_n, ctx.forge_opts)
    else
      {:ok, 0}
    end
  end

  @doc """
  Re-reads the PR to distinguish merged, closed, draft, policy, conflict and unknown.
  Merged state converges terminal guards without claiming authorship of the merge;
  closed/draft skip, policy inspects CI and re-requests, conflict enters ConflictLadder,
  and unknown escalates. A returned PR read error classifies as unknown.

  ConflictLadder can diagnose/resolve mechanically, request bounded local producer
  work, try an exception role or escalate. Diagnosis and exception passes have separate
  feature flags; local resolution does not require pod forge credentials.
  """
  @spec route_merge_failure(integer(), String.t(), term(), Ctx.t()) ::
          {:ok, tuple()} | {:skipped, term()} | {:error, term()}
  def route_merge_failure(pr_number, head, reason, %Ctx{} = ctx) do
    case classify_merge_failure(pr_number, ctx) do
      :merged ->
        # Converge stage/close guards after an observed external merge, without adding our seal claim.
        # An unparseable head returns merged without guessing its parent issue.
        converge_out_of_band(pr_number, head, ctx)

      :closed ->
        Logger.info(
          "StepDispatcher: PR #{ctx.repo}##{pr_number} closed (human cancellation) → merge abandoned"
        )

        {:skipped, {:cancelled, pr_number}}

      :draft ->
        {:skipped, {:draft, pr_number}}

      :policy ->
        reconverge_policy(pr_number, head, ctx)

      # A classified conflict can reuse the existing PR via the ladder; unknown causes must not guess.
      :conflict ->
        ConflictLadder.run(pr_number, head, reason, ctx)

      :unknown ->
        ArchEscalation.escalate_merge_blocked(
          Ctx.arch_seams(ctx),
          pr_number,
          head,
          :unknown,
          reason
        )
    end
  end

  defp converge_out_of_band(pr_number, head, %Ctx{} = ctx) do
    case RoleDispatch.parse_feature_branch_or_skip(head) do
      {:ok, {issue_n, producer}} ->
        case Fleet.Pilot.MergeAndPromote.converge_out_of_band_merge(
               ctx.forge,
               ctx.repo,
               pr_number,
               issue_n,
               ctx.forge_opts,
               base_branch: Keyword.fetch!(ctx.opts, :pr_base_branch),
               producer: producer
             ) do
          :ok -> {:ok, {:merged, pr_number}}
          {:error, _} = err -> err
        end

      {:skipped, _} ->
        {:ok, {:merged, pr_number}}
    end
  end

  @doc """
  Marks pre-jury CI red on the PR using the first eight-hex token in the gate message,
  or unknown when none is found. An existing same marker skips; at least two comments
  containing the PR prefix cause escalation for a new marker. This counts matching
  comments, not distinct SHAs, and does not validate their author or marker grammar.

  Marker posting precedes dispatch and its returned result is ignored. Thus a failed
  write can permit repeated work, while a posted marker followed by a busy/error return
  can suppress later work on the same head. This path still calls dispatch_rework and
  therefore also consults its review/publish budgets.
  """
  @spec ci_red_rework(integer(), String.t(), String.t(), Ctx.t()) ::
          {:ok, tuple()} | {:skipped, term()} | {:error, term()}
  def ci_red_rework(pr_number, head, message, %Ctx{} = ctx) do
    sha8 = message |> extract_sha8() || "unknown"
    marker = "[ci-red:pr-#{pr_number}:#{sha8}]"

    case ctx.forge.list_comments(ctx.repo, pr_number, ctx.forge_opts) do
      {:ok, comments} ->
        bodies = Enum.map(comments, &Map.get(&1, "body", ""))

        cond do
          Enum.any?(bodies, &String.contains?(&1, marker)) ->
            {:skipped, {:ci_red_already_signalled, sha8}}

          count_ci_red(bodies, pr_number) >= 2 ->
            escalate_ci(pr_number, head, ctx, :ci_red_loop, message)

          true ->
            # Request deduplication, but posting is not atomic with dispatch and its return is ignored.
            _ =
              ctx.forge.post_comment(
                ctx.repo,
                pr_number,
                "**CI** — #{message}\n\n#{marker}",
                ctx.forge_opts
                |> Keyword.put(:dedup_signature, marker)
                |> Keyword.put(:dedup_any_author, true)
              )

            dispatch_rework(pr_number, head, ctx)
        end

      # A returned comment-read error skips instead of dispatching without dedup evidence.
      {:error, reason} ->
        {:skipped, {:ci_red_marker_unreadable, reason}}
    end
  end

  @doc """
  Forwards the gate's classified CI cause and message to architect escalation.
  The observations can justify intervention without proving a particular runner failure.
  """
  @spec ci_stalled(integer(), String.t(), term(), String.t(), Ctx.t()) ::
          {:skipped, term()} | {:error, term()}
  def ci_stalled(pr_number, head, class, message, %Ctx{} = ctx),
    do: escalate_ci(pr_number, head, ctx, class, message)

  defp escalate_ci(pr_number, head, %Ctx{} = ctx, class, message) do
    Logger.warning(
      "StepDispatcher: PR #{ctx.repo}##{pr_number} CI #{inspect(class)} — #{message}"
    )

    # Preserve the CI class so escalation names its diagnosis instead of a generic merge failure.
    ArchEscalation.escalate_merge_blocked(Ctx.arch_seams(ctx), pr_number, head, class, message)
  end

  defp count_ci_red(bodies, pr_number) do
    prefix = "[ci-red:pr-#{pr_number}:"

    bodies
    |> Enum.filter(&String.contains?(&1, prefix))
    |> length()
  end

  # Extract the gate message's first eight-hex token without rereading a potentially moved head.
  # This is textual parsing, not a full-SHA identity guarantee.
  defp extract_sha8(message) do
    case Regex.run(~r/\b([0-9a-f]{8})\b/, message) do
      [_, sha8] -> sha8
      _ -> nil
    end
  end

  # Classify PR fields rather than infer Git conflict from the merge error text.
  defp classify_merge_failure(pr_number, %Ctx{} = ctx) do
    case ctx.forge.get_pull(ctx.repo, pr_number, ctx.forge_opts) do
      {:ok, pull} -> Fleet.Pilot.MergeOutcome.classify(pull)
      {:error, _} -> :unknown
    end
  end

  # Forge protection can require CI even when the card ignores it for jury admission.
  # Failure requests counted CI rework; pending uses the shared deadline.
  # Success, no status and returned read errors fall through to reviewer re-request handling.
  defp reconverge_policy(pr_number, head, %Ctx{} = ctx) do
    reconverge_on_ci(pr_number, head, ctx)
  end

  defp reconverge_on_ci(pr_number, head, %Ctx{} = ctx) do
    case ctx.forge.commit_ci_state(ctx.repo, head_sha(head, pr_number, ctx), ctx.forge_opts) do
      {:ok, :failure} ->
        Logger.info(
          "StepDispatcher: PR #{ctx.repo}##{pr_number} blocked by a RED CI → producer rework"
        )

        dispatch_ci_rework(pr_number, head, ctx)

      {:ok, :pending} ->
        # Share the gate deadline; unreadable date still collapses to ordinary ci_pending here.
        ci_pending_or_stalled(pr_number, head, ctx)

      # Unknown CI is not established success; this fallback investigates re-requests anyway.
      _ ->
        reconverge_rerequest(pr_number, head, ctx)
    end
  end

  # Missing/read-failed SHA falls back to the moving branch ref; it is not a pinned observation.
  defp head_sha(head, pr_number, %Ctx{} = ctx) do
    case ctx.forge.get_pull(ctx.repo, pr_number, ctx.forge_opts) do
      {:ok, pull} -> Payload.head_sha(pull) || head
      _ -> head
    end
  end

  defp reconverge_rerequest(pr_number, head, %Ctx{} = ctx) do
    case ctx.forge.pr_rerequested_reviewers(ctx.repo, pr_number, ctx.forge_opts) do
      {:ok, [judge | _]} ->
        Logger.info(
          "StepDispatcher: PR #{ctx.repo}##{pr_number} blocked by human re-request → re-dispatch #{judge}"
        )

        RoleDispatch.dispatch(:judge, pr_number, head, judge, ctx)

      {:ok, []} ->
        ArchEscalation.escalate_merge_blocked(
          Ctx.arch_seams(ctx),
          pr_number,
          head,
          :policy,
          {:policy, :no_rerequest}
        )

      {:error, reason} ->
        ArchEscalation.escalate_merge_blocked(
          Ctx.arch_seams(ctx),
          pr_number,
          head,
          :rerequest_read_failed,
          reason
        )
    end
  end
end
