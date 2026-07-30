defmodule Fleet.Pilot.StepDispatcher.ReviewLifecycle.Remediation do
  @moduledoc """
  BOUNDED remediation of the review flow (`ReviewLifecycle`): producer re-spawn for REWORK
  (verdict `changes_requested`), and ROUTING of a merge failure by its real cause
  (`route_merge_failure`) — always under a brake / an honest classification, never infinite churn
  nor action on a false premise.

  ## Rework — anti-churn brake

  FORGE-NATIVE counter (`count_change_request_rounds` = number of REQUEST_CHANGES reviews, monotonic),
  budget = the issue MAP's `spec.max_rework_rounds` (DATA, the SAME brake as the issue rebound — never
  a hand-aligned hard-coded default). Beyond that → ARCH ESCALATION. Unreadable
  budget/route/map → we DO NOT re-spawn blindly: escalation (symmetric to `rebound` on the StepRunConsumer side).

  ## Merge failure — honest classification (`route_merge_failure`)

  A merge can fail for NATURALLY distinct reasons (`Fleet.Pilot.MergeOutcome`, re-read from
  the PR object): already-merged / cancelled (human close) / draft / policy (human re-request) / real git
  conflict / unknown. Each has its own routing. A REAL conflict goes to `conflict_rework`
  (tier 1: the producer resolves LOCALLY on its PR — a local merge needs no forge credentials;
  bounded by the same `max_rework_rounds`, counted via the `[conflict-rework:pr-N` markers).
  The throttle for escalated cases = the `lcars-awaits-arch` lock laid by `ArchEscalation` (the poller
  SKIPS the issue), not an IncidentRegistry (there is no resolution loop to bound here).

  The DECISION lives here; the EXECUTION of the re-spawn descends to `RoleDispatch` (leaf shared with the
  judge spawn — no fork of the mechanics); the WRITING of the human escalation descends to
  `ArchEscalation` (narrow seams rebuilt HERE, never the whole `Ctx`).

  **Last revised**: 2026-07-30
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
  # policy, read as DATA — never a hand-aligned hard-coded default). Issue route → map name →
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
      # The specs of route_for/4 (typed direct call) and safe_load cover every shape —
      # a catch-all `other ->` clause here would be dead-by-spec (dialyzer-provable).
      {:ok, nil} -> {:error, :routeless}
      {:error, _} = err -> err
    end
  end

  @doc """
  Routing of a MERGE FAILURE by its REAL cause (`Fleet.Pilot.MergeOutcome`, re-read from the fresh PR
  object — never the "conflict" catch-all). Assuming a git conflict and dispatching the producer
  to rebase is IMPOSSIBLE (the pod is forge-blind, no credentials) — and a mere policy window
  would masquerade as a conflict.

    * `:merged`   → someone merged in the meantime (multi-actor race / replay) → `{:ok, :merged}` idempotent.
    * `:closed`   → a human CLOSED the PR (cancellation) → the brick is dead, we don't push on.
    * `:draft`    → a human moved it back to draft (parked) → skip; `dispatch_review` re-skips it
                    while draft (dispatch-judge guard).
    * `:policy`   → git-mergeable but branch-protection refuses (approvals cleared by a
                    human RE-REQUEST, CI…) → we re-converge: re-dispatch the re-requested judge (timeline).
                    No re-requested = policy block we can't lift mechanically → honest escalation.
    * `:conflict` → the 4-tier pipeline of `conflict_rework/4`, gated by `:conflict_diagnosis?`:
                    tier 0 (deterministic diagnosis + auto-resolution of an all-trivial conflict,
                    runtime, no pod), tier 1 (BOUNDED producer conflict-rework: local resolution on
                    the same PR — needs no forge credentials), tier 2 (ONE gatekeeper pass, the
                    exception judge), tier 3 (honest arch escalation). Flag off → tier 1 → tier 3,
                    byte-for-byte the legacy path.
    * `:unknown`  → not classifiable → HONEST arch escalation (we don't guess).
  """
  @spec route_merge_failure(integer(), String.t(), term(), Ctx.t()) ::
          {:ok, tuple()} | {:skipped, term()} | {:error, term()}
  def route_merge_failure(pr_number, head, reason, %Ctx{} = ctx) do
    case classify_merge_failure(pr_number, ctx) do
      :merged ->
        # Merged OUT-OF-BAND (another actor, or our own seal whose readback failed
        # transiently). The bare no-op left the merged brick OPEN without `stage/merged`:
        # reclaimable by the reconciliation, then re-dispatched — double-delivery. Converge
        # the attribution-neutral terminal guards (never the seal comment — this path did
        # not merge). A head that does not parse (adopted human PR) keeps the historical
        # no-op: its issue linkage is not ours to guess.
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

      # A REAL git conflict is mechanically recoverable by the PRODUCER (tier 1, live retex
      # fleet/hello#3 2026-07-19: a full re-delegated chain — 4 agent passes, ~7 min — for what a
      # local merge-resolve on the SAME PR handles): bounded conflict-rework, budget exhausted →
      # honest escalation (tier 3). `:unknown` stays a straight escalation (we don't guess).
      :conflict ->
        conflict_rework(pr_number, head, reason, ctx)

      :unknown ->
        ArchEscalation.escalate_merge_blocked(arch_seams(ctx), pr_number, head, :unknown, reason)
    end
  end

  # Tier-0 conflict handling (deterministic, config-gated, OFF by default). A diagnosis routes the
  # conflict BEFORE any producer round: an all-semantic conflict escalates straight to the arch (no
  # wasted rounds), an all-trivial one is auto-resolved and pushed by the runtime (the jury re-judges
  # the new head, so a wrong resolution is caught downstream), anything else — and any probe/apply
  # failure — falls through to the legacy producer conflict-rework. The gain only ever SHORTENS a
  # path, never breaks one. Enabled by `:fleet_pilot, :conflict_diagnosis?`; diagnoser/applier are
  # injectable seams (`:conflict_diagnoser` / `:conflict_applier`). NB tier-2 (gatekeeper inference)
  # is a distinct, still-future increment — tier-0 is the deterministic pre-filter in front of it.
  defp conflict_rework(pr_number, head, reason, %Ctx{} = ctx) do
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
    case diagnoser().probe(ctx.repo, head, []) do
      {:ok, diagnosis} -> tier0_act(tier0_decision(diagnosis), pr_number, head, reason, ctx)
      {:error, _} -> :fall_through
    end
  end

  @doc false
  # PURE routing decision from the diagnosis totals (isolated so it is unit-testable).
  @spec tier0_decision(map()) :: :escalate | :apply | :fall_through
  def tier0_decision(%{totals: %{none_trivial?: true}}), do: :escalate

  # `all_writable?`, not `all_trivial?`: the write path is authorized by what the machine may safely
  # do alone, not by how shallow the conflict looks. A shallow-but-unwritable conflict (whitespace,
  # reorder, competing insertions) falls through to the producer, which HAS the context to decide
  # whether the indentation, the order or the duplicate mattered.
  def tier0_decision(%{totals: %{all_writable?: true}}), do: :apply
  def tier0_decision(_), do: :fall_through

  defp tier0_act(:escalate, pr_number, head, reason, ctx) do
    Logger.info(
      "Remediation: PR #{ctx.repo}##{pr_number} conflict is all-semantic → arch escalation (tier-0, rounds skipped)"
    )

    {:handled,
     ArchEscalation.escalate_merge_blocked(
       arch_seams(ctx),
       pr_number,
       head,
       :conflict,
       {:conflict_all_semantic, reason}
     )}
  end

  defp tier0_act(:apply, pr_number, head, _reason, ctx) do
    case applier().apply(ctx.repo, head, []) do
      {:ok, :auto_resolved} ->
        Logger.info(
          "Remediation: PR #{ctx.repo}##{pr_number} conflict auto-resolved (tier-0, all trivial)"
        )

        {:handled, {:ok, {:auto_resolved, pr_number}}}

      {:error, _} ->
        :fall_through
    end
  end

  defp tier0_act(:fall_through, _pr_number, _head, _reason, _ctx), do: :fall_through

  defp diagnosis_enabled?, do: Application.get_env(:fleet_pilot, :conflict_diagnosis?, false)

  defp diagnoser,
    do: Application.get_env(:fleet_pilot, :conflict_diagnoser, Fleet.Pilot.ConflictProbe)

  defp applier,
    do: Application.get_env(:fleet_pilot, :conflict_applier, Fleet.Pilot.ConflictApply)

  # Producer conflict-rework budget exhausted. Under the conflict-diagnosis flag this is tier-2: give
  # the one-shot GATEKEEPER a single inference pass before immobilizing a human (tier-3). Flag off,
  # or the gatekeeper pass already spent → the legacy arch escalation, byte-for-byte unchanged.
  defp producer_exhausted(pr_number, head, reason, %Ctx{} = ctx, producer_rounds) do
    if diagnosis_enabled?() do
      gatekeeper_stage(pr_number, head, reason, ctx, producer_rounds)
    else
      escalate_exhausted(pr_number, head, reason, ctx, producer_rounds)
    end
  end

  defp gatekeeper_stage(pr_number, head, reason, %Ctx{} = ctx, producer_rounds) do
    marker = "[conflict-gatekeeper:pr-#{pr_number}"
    count = ctx.forge.count_comments_marked(ctx.repo, pr_number, marker, ctx.forge_opts)

    case gatekeeper_stage_decision(count) do
      :dispatch ->
        dispatch_gatekeeper_rework(pr_number, head, ctx)

      :escalate ->
        escalate_exhausted(pr_number, head, {:gatekeeper_spent, reason}, ctx, producer_rounds)
    end
  end

  @doc false
  # PURE tier-2 gate: one gatekeeper pass, then the arch. Unreadable count → escalate (never a loop).
  @spec gatekeeper_stage_decision({:ok, integer()} | {:error, term()}) :: :dispatch | :escalate
  def gatekeeper_stage_decision({:ok, spent}) when is_integer(spent) and spent < 1, do: :dispatch
  def gatekeeper_stage_decision(_), do: :escalate

  # One inference pass by the gatekeeper (a distinct, more-capable one-shot judge) on the SAME proven
  # conflict-rework dispatch as the producer: it clones the feature branch (`base_branch: head`),
  # resolves in its workspace, the SYSTEM pushes, the jury re-judges the new head. The round-1 marker
  # bounds it to a single pass and makes the re-dispatch idempotent (dedup, like the producer's).
  # The brief carries the EXCEPTION-JUDGE voice (`:conflict_rework_gatekeeper`), not the producer's:
  # the gatekeeper has no brief of its own to resume, and being told "ton brief est INCHANGÉ" invited
  # it to guess at an intention it does not hold. Same mechanics, addressed to who is actually there.
  defp dispatch_gatekeeper_rework(pr_number, head, %Ctx{} = ctx) do
    signature = "[conflict-gatekeeper:pr-#{pr_number}:round-1]"

    body =
      "⚠ Conflit de merge non résolu par le producteur (budget de rework épuisé). Passe " <>
        "d'exception : le gatekeeper tente une dernière résolution avant escalade humaine — il " <>
        "intègre `origin/main`, résout, et re-livre sur CETTE PR ; les juges re-jugeront le nouveau " <>
        "head.\n\n" <> signature

    comment_opts =
      ctx.forge_opts
      |> Keyword.put(:dedup_signature, signature)
      |> Keyword.put(:dedup_any_author, true)

    case ctx.forge.post_comment(ctx.repo, pr_number, body, comment_opts) do
      {:ok, _} ->
        RoleDispatch.dispatch(
          :conflict_rework_gatekeeper,
          pr_number,
          head,
          Fleet.Pilot.Roles.gatekeeper_role(),
          ctx
        )

      {:error, marker_reason} ->
        ArchEscalation.escalate_merge_blocked(
          arch_seams(ctx),
          pr_number,
          head,
          :conflict,
          {:conflict_gatekeeper_marker_unpostable, marker_reason}
        )
    end
  end

  defp escalate_exhausted(pr_number, head, reason, %Ctx{} = ctx, producer_rounds) do
    ArchEscalation.escalate_merge_blocked(
      arch_seams(ctx),
      pr_number,
      head,
      :conflict,
      {:conflict_rework_exhausted, producer_rounds, reason}
    )
  end

  # Tier 1 of the conflict model (user go 2026-07-19): the producer resolves ON ITS PR — it has
  # the workspace, the brief unchanged, and the review budget; the judges then re-review the new
  # head (commit-scoped verdicts). Bounded by the SAME `max_rework_rounds` policy as the judge
  # rework, counted via the `[conflict-rework:pr-N` markers this path posts (round-numbered →
  # dedup makes the count replay-safe). Beyond budget, or any unreadable read → tier 3, the
  # honest arch escalation (never a blind loop). Tier 2 (a gatekeeper one-shot before the arch) is
  # CÂBLÉ since the conflict-engine increment: budget-exhausted goes through `gatekeeper_stage_decision`
  # and one gatekeeper pass, then the arch — gated by `:conflict_diagnosis?` like tier 0.
  defp legacy_conflict_rework(pr_number, head, reason, %Ctx{} = ctx) do
    marker_prefix = "[conflict-rework:pr-#{pr_number}"

    with {:ok, {issue_n, _producer}} <- RoleDispatch.parse_feature_branch_or_skip(head),
         {:ok, budget} <- pr_rework_budget(ctx, issue_n),
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

      # Budget/counter unreadable → the arch rules (symmetric to dispatch_rework's stance):
      # never a blind loop, never a guessed round.
      {:error, err_reason} ->
        ArchEscalation.escalate_merge_blocked(
          arch_seams(ctx),
          pr_number,
          head,
          :conflict,
          {:conflict_budget_unreadable, err_reason}
        )
    end
  end

  # The marker is posted BEFORE the dispatch (round-numbered signature → idempotent replay: a
  # re-run of the same round dedups, a NEW conflict after a re-push posts the next round). A
  # marker that cannot be posted → escalate rather than dispatch an uncounted round (the budget
  # would silently stop bounding).
  defp dispatch_conflict_rework(pr_number, head, round, budget, %Ctx{} = ctx) do
    signature = "[conflict-rework:pr-#{pr_number}:round-#{round}]"

    body =
      "⚠ Conflit de merge avec `main` (des briques sœurs ont atterri depuis la coupe de cette " <>
        "branche). Rework automatique round #{round}/#{budget} : le producteur intègre " <>
        "`origin/main`, résout, et re-livre sur CETTE PR — les juges re-jugeront le nouveau " <>
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
          arch_seams(ctx),
          pr_number,
          head,
          :conflict,
          {:conflict_marker_unpostable, reason}
        )
    end
  end

  # The head was already parsed by the caller (conflict_rework) — a re-parse failure here is
  # unreachable by construction; raise loud rather than a silent wrong role.
  defp producer_of!(head) do
    {:ok, {_issue_n, producer}} = Fleet.Pilot.ForgeProtocol.parse_feature_branch(head)
    producer
  end

  defp converge_out_of_band(pr_number, head, %Ctx{} = ctx) do
    case RoleDispatch.parse_feature_branch_or_skip(head) do
      {:ok, {issue_n, _producer}} ->
        case Fleet.Pilot.GatekeeperSeal.converge_out_of_band_merge(
               ctx.forge,
               ctx.repo,
               pr_number,
               issue_n,
               ctx.forge_opts
             ) do
          :ok -> {:ok, {:merged, pr_number}}
          {:error, _} = err -> err
        end

      {:skipped, _} ->
        {:ok, {:merged, pr_number}}
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
  # the rest on the next tick). It's the "re-request a judgment" button doing its job. No
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
