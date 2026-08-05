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

  **Last revised**: 2026-08-05
  """

  require Logger

  # Writing the human escalation (IMPURE cluster): Remediation DECIDES (rework budget /
  # merge-failure classification), ArchEscalation WRITES (deduplicated gatekeeper comment + `awaits-arch` lock).
  alias Fleet.Pilot.StepDispatcher.ArchEscalation

  alias Fleet.Pilot.ConflictReport
  alias Fleet.Pilot.ForgeClient
  alias Fleet.Pilot.StepDispatcher.ReviewLifecycle.Ctx
  alias Fleet.Workflow.Pinning
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
               ctx.forge.count_change_request_rounds(ctx.repo, pr_number, ctx.forge_opts),
             # The PUBLISH brake (chantier frein-publish) — checked with the SAME budget, on the
             # OTHER counter: `rounds` counts judge verdicts and freezes the moment a rework's
             # publication fails (no delivery → no re-judge), which is exactly when the spend
             # runs away. The streak is the largest same-base `[publish-fail:...]` marker group
             # on the issue (the gate base moves only on a successful push, so same-base ≡
             # consecutive). An unreadable counter escalates like an unreadable budget: never a
             # blind loop.
             {:ok, publish_fails} <-
               count_publish_failures(ctx, issue_n) do
          cond do
            publish_fails > budget ->
              ArchEscalation.escalate_publish_failures(
                arch_seams(ctx),
                pr_number,
                head,
                %{publish_failures: publish_fails, budget: budget}
              )

            rounds <= budget ->
              RoleDispatch.dispatch(:rework, pr_number, head, producer_role, ctx)

            true ->
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
  # Seam-tolerant read of the publish-failure streak: a forge stub without the counter (every
  # pre-brake test, and any minimal seam) reads as ZERO failures — the brake only ever FIRES on a
  # forge that records the markers, it never blocks a rework for lack of instrumentation. A real
  # counter error, though, propagates (the `with` escalates it like an unreadable budget).
  defp count_publish_failures(%Ctx{} = ctx, issue_n) do
    if function_exported?(ctx.forge, :count_publish_failures, 3) do
      ctx.forge.count_publish_failures(ctx.repo, issue_n, ctx.forge_opts)
    else
      {:ok, 0}
    end
  end

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
                    the same PR — needs no forge credentials), tier 2 (ONE outsider pass, the
                    `conflict_resolver` role), tier 3 (honest arch escalation). Flag off → tier 1 → tier 3,
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
  # conflict BEFORE any producer round: an all-semantic one goes to the CHIEF's exception pass (the
  # producer is skipped on evidence — the engine has proven there is nothing shallow to fix — and
  # the chief is not, because composing two jury-approved intentions is its case); an all-trivial
  # one is auto-resolved and pushed by the runtime (the jury re-judges the new head, so a wrong
  # resolution is caught downstream); anything else — and any probe/apply failure — falls through to
  # the legacy producer conflict-rework. The gain only ever SHORTENS a path, never breaks one.
  # Enabled by `:fleet_pilot, :conflict_diagnosis?`; diagnoser/applier are injectable seams
  # (`:conflict_diagnoser` / `:conflict_applier`).
  #
  # The ladder in one line: L1 engine → L2 producer → L3 chief → L4 arch. Tier-0 may skip L2 on
  # evidence; it has none about L3, and it used to skip it anyway — straight to a human.
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
    case diagnoser().probe(ctx.repo, head, conflict_face_opts(ctx)) do
      {:ok, diagnosis} ->
        tier0_act(tier0_decision(diagnosis), pr_number, head, reason, ctx, diagnosis)

      {:error, _} ->
        :fall_through
    end
  end

  # THE ENGINE'S REASONING REACHES A READER. `Fleet.Conflict` names the DecisionTrace its durable
  # value — "the REFUSAL is documented as much as the acceptance" — and it was produced per hunk,
  # carried by every Report, and dropped here: this router read `totals` and nothing else. The engine
  # wrote a machine's worth of reasoning and published a count.
  #
  # Posted UNDER THE CHIEF's identity, while the resolution commit stays authored by
  # `lcars-conflict-engine`. The two are different facts and both are true: the engine held the pen,
  # the chief owns the act (user split — gatekeeper = verdicts, chief = the merge). Signing the
  # report with the engine would name a machine as the responsible party for a call a role answers
  # for.
  #
  # Best-effort by construction: a report that cannot be posted must never turn an auto-resolution
  # into a failure, nor block a hand-off. It logs and the routing continues — the reasoning is a
  # reader's aid, not a precondition of the act it describes.
  defp post_conflict_report(pr_number, diagnosis, outcome, %Ctx{} = ctx) do
    body =
      diagnosis
      |> ConflictReport.render(outcome)
      |> Pinning.render(
        work_dir: conflict_report_work_dir(ctx),
        ref: Fleet.Layout.conflict_ref(pr_number),
        kind: "Rapport",
        label: "conflict"
      )

    case ForgeClient.as_role(ctx.forge_opts, Fleet.Pilot.Roles.conflict_resolver_role()) do
      {:ok, role_opts} ->
        case ctx.forge.post_comment(ctx.repo, pr_number, body, role_opts) do
          {:ok, _} ->
            :ok

          {:error, why} ->
            Logger.warning(
              "Remediation: conflict report NOT posted on #{ctx.repo}##{pr_number} " <>
                "(#{inspect(why)}) — the routing stands, only its explanation is missing"
            )
        end

      {:error, why} ->
        Logger.warning(
          "Remediation: conflict report NOT posted on #{ctx.repo}##{pr_number} — no chief " <>
            "identity (#{inspect(why)}); posting it under the system account would name the " <>
            "wrong owner for the call"
        )
    end
  end

  defp conflict_report_work_dir(%Ctx{} = ctx) do
    dir = Path.join(Fleet.Layout.work_root(), Fleet.Layout.project_name(ctx.repo))
    if File.dir?(dir), do: dir
  end

  @doc false
  # PURE routing decision from the diagnosis totals (isolated so it is unit-testable).
  #
  # `:chief`, NOT `:escalate` (2026-08-05). An all-semantic conflict used to go STRAIGHT to the arch
  # — "rounds skipped" — jumping tiers 2 AND 3 to immobilize a human. Skipping the PRODUCER is right
  # and is the whole point of the deterministic pre-filter: the engine has just proven there is
  # nothing shallow to fix, so a producer round would burn a full run to rediscover it.
  #
  # Skipping the CHIEF was not. Composing two intentions that both passed their jury, on a branch
  # the outsider did not write, IS the chief's case — it is what the exception pass exists for. The
  # ladder is L1 engine → L2 producer → L3 chief → L4 arch, and tier-0 may skip L2 on evidence; it
  # has no evidence about L3. The atom is renamed with the routing so the name cannot outlive the
  # behaviour (`:escalate` would now describe a hand-off that escalates nothing).
  @spec tier0_decision(map()) :: :chief | :apply | :fall_through
  def tier0_decision(%{totals: %{none_trivial?: true}}), do: :chief

  # `all_writable?`, not `all_trivial?`: the write path is authorized by what the machine may safely
  # do alone, not by how shallow the conflict looks. A shallow-but-unwritable conflict (whitespace,
  # reorder, competing insertions) falls through to the producer, which HAS the context to decide
  # whether the indentation, the order or the duplicate mattered.
  def tier0_decision(%{totals: %{all_writable?: true}}), do: :apply
  def tier0_decision(_), do: :fall_through

  # The chief's exception stage is REUSED as-is, marker and all: it reads the forge-visible
  # `[conflict-chief:pr-N` count, so this path cannot loop and cannot spend a second pass if the
  # producer route already spent one. `producer_rounds: 0` is the honest figure on this path — no
  # producer round was run, and the arch escalation message must not claim otherwise.
  defp tier0_act(:chief, pr_number, head, reason, ctx, diagnosis) do
    _ = post_conflict_report(pr_number, diagnosis, :all_semantic, ctx)
    do_tier0_chief(pr_number, head, reason, ctx)
  end

  defp tier0_act(:apply, pr_number, head, reason, ctx, diagnosis) do
    case do_tier0_apply(pr_number, head, reason, ctx) do
      {:handled, _} = handled ->
        # AFTER the write, not before: a report announcing a resolution that then failed to apply
        # would be the only durable trace of something that did not happen.
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

  defp diagnosis_enabled?, do: Application.get_env(:fleet_pilot, :conflict_diagnosis?, false)

  # The FACE of the conflict (chantier face-projet, inventory #7/#8): the probe/apply helpers used
  # to be called with `[]` and fall back to their `origin/main` default IN the code-face worktree —
  # on an ops PR that would resolve a conflict by merging the CODE face into a doc branch, silently,
  # and report `{:ok, :auto_resolved}`. The PR's own base (stamped at dispatch_review) names both
  # the merge target and the worktree the resolution runs in.
  defp conflict_face_opts(%Ctx{} = ctx) do
    base = Keyword.fetch!(ctx.opts, :pr_base_branch)

    dir =
      if Fleet.Layout.ops_branch?(base),
        do: Path.join(Fleet.Layout.work_root(), Fleet.Layout.project_name(ctx.repo)),
        else: Path.join(Fleet.Layout.projects_root(), Fleet.Layout.project_name(ctx.repo))

    [base_branch: "origin/" <> base, dir: dir]
  end

  defp diagnoser,
    do: Application.get_env(:fleet_pilot, :conflict_diagnoser, Fleet.Pilot.ConflictProbe)

  defp applier,
    do: Application.get_env(:fleet_pilot, :conflict_applier, Fleet.Pilot.ConflictApply)

  # Producer conflict-rework budget exhausted. Under the conflict-diagnosis flag this is tier-2: give
  # the OUTSIDER a single inference pass before immobilizing a human (tier-3). Flag off, or that pass
  # already spent → the legacy arch escalation, byte-for-byte unchanged.
  defp producer_exhausted(pr_number, head, reason, %Ctx{} = ctx, producer_rounds) do
    if diagnosis_enabled?() do
      exception_stage(pr_number, head, reason, ctx, producer_rounds)
    else
      escalate_exhausted(pr_number, head, reason, ctx, producer_rounds)
    end
  end

  defp exception_stage(pr_number, head, reason, %Ctx{} = ctx, producer_rounds) do
    marker = "[conflict-chief:pr-#{pr_number}"
    count = ctx.forge.count_comments_marked(ctx.repo, pr_number, marker, ctx.forge_opts)

    case exception_stage_decision(count) do
      :dispatch ->
        # THE LAST RUNG MUST NOT SWALLOW THE CASE. `RoleDispatch.dispatch` answers `{:skipped, _}`
        # when the `conflict_resolver` role does not resolve (absent from the catalogue, typo in a
        # card) or when the head is not a fleet branch. That skip is already LOUD — an unresolvable
        # role goes on the incident rail and its recurrence opens a sysadmin issue — but loud is not
        # the same as handled: the conflict itself would then sit on the PR with nobody left to look
        # at it, because the tier that was supposed to try LAST could not run at all.
        #
        # Pre-existing on the producer-exhausted path, and tier-0 would have extended it to the
        # all-semantic one. A rung that cannot be climbed hands over to the next, it does not end
        # the ladder.
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
  # PURE tier-2 gate: one exception pass, then the arch. Unreadable count → escalate (never a loop).
  @spec exception_stage_decision({:ok, integer()} | {:error, term()}) :: :dispatch | :escalate
  def exception_stage_decision({:ok, spent}) when is_integer(spent) and spent < 1, do: :dispatch
  def exception_stage_decision(_), do: :escalate

  # One inference pass by the OUTSIDER (`conflict_resolver` capability — `chief`) on the SAME proven
  # conflict-rework dispatch as the producer: it clones the feature branch (`base_branch: head`),
  # resolves in its workspace, the SYSTEM pushes, the jury re-judges the new head. The round-1 marker
  # bounds it to a single pass and makes the re-dispatch idempotent (dedup, like the producer's).
  # The brief carries the OUTSIDER voice (`:conflict_rework_exception`), not the producer's: this pass
  # has no brief of its own to resume, and being told "ton brief est INCHANGÉ" invited it to guess at
  # an intention it does not hold. Same mechanics, addressed to who is actually there.
  #
  # MARKER RENAMED `[conflict-gatekeeper:pr-N` → `[conflict-chief:pr-N`. It is FORGE-VISIBLE and
  # load-bearing (`count_comments_marked` reads it to bound the pass to one), so a rename is a
  # migration: a PR already carrying the old marker would count 0 and get a SECOND pass. Safe here
  # because this tier has never fired in production (user, 2026-08-04) — stated as the reason, not
  # measured by me. Had it fired, the correct move was to count both prefixes for one cycle.
  defp dispatch_exception_rework(pr_number, head, %Ctx{} = ctx) do
    signature = "[conflict-chief:pr-#{pr_number}:round-1]"

    body =
      "⚠ Conflit de merge non résolu par le producteur (budget de rework épuisé). Passe " <>
        "d'exception : le **chief** tente une dernière résolution avant escalade humaine — il " <>
        "intègre `origin/main`, résout, et re-livre sur CETTE PR ; les juges re-jugeront le nouveau " <>
        "head.\n\n" <> signature

    comment_opts =
      ctx.forge_opts
      |> Keyword.put(:dedup_signature, signature)
      |> Keyword.put(:dedup_any_author, true)

    case ctx.forge.post_comment(ctx.repo, pr_number, body, comment_opts) do
      {:ok, _} ->
        # `conflict_resolver_role/0`, NOT `gatekeeper_role/0`: this dispatch decides who RESOLVES an
        # exhausted conflict, and the seal decides who SIGNS the merge. One key for both would make
        # substituting the resolver move the signatory too, silently.
        RoleDispatch.dispatch(
          :conflict_rework_exception,
          pr_number,
          head,
          Fleet.Pilot.Roles.conflict_resolver_role(),
          ctx
        )

      {:error, marker_reason} ->
        ArchEscalation.escalate_merge_blocked(
          arch_seams(ctx),
          pr_number,
          head,
          :conflict,
          {:conflict_exception_marker_unpostable, marker_reason}
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
  # honest arch escalation (never a blind loop). Tier 2 (ONE outsider pass before the arch) is
  # CÂBLÉ since the conflict-engine increment: budget-exhausted goes through `exception_stage_decision`
  # and one pass, then the arch — gated by `:conflict_diagnosis?` like tier 0.
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
      {:ok, {issue_n, producer}} ->
        case Fleet.Pilot.GatekeeperSeal.converge_out_of_band_merge(
               ctx.forge,
               ctx.repo,
               pr_number,
               issue_n,
               ctx.forge_opts,
               # The PR's own base (dispatch_review single site): the face worktree to align.
               base_branch: Keyword.fetch!(ctx.opts, :pr_base_branch),
               # The branch already names its producer — the reaping needs no second source.
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
  CI RED before the jury: the producer reworks, and the red is GRAVED on the PR.

  Bounded by construction, and the bound is the marker itself. The comment carries
  `[ci-red:pr-N:<sha8>]`, so:

    * the SAME red sha never dispatches twice — the next tick reads its own marker and stands
      down (a rework is already in flight; re-dispatching every 30 s would burn a producer session
      per tick, the exact shape the publish brake exists to stop);
    * DISTINCT red shas are counted — three of them means the producer is looping against the rail,
      which is no longer a rework, it is an incident: the arch gets it, with the count spent.

  A CI red does NOT consume a jury round: `max_rework_rounds` counts VERDICTS, and no verdict was
  rendered here. Conflating the two would let a mechanical failure eat the budget of the human-ish
  one, and the ticket would escalate saying "judges exhausted" about judges that never ran.
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
            # `dedup_signature` = the marker: the forge itself refuses the double post if two
            # ticks race, so the bound does not depend on our read winning.
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

      # Comments unreadable: we do NOT re-dispatch blind (that is how a tick-loop starts) and we do
      # not swallow it either — the next tick asks again, the reason is named.
      {:error, reason} ->
        {:skipped, {:ci_red_marker_unreadable, reason}}
    end
  end

  @doc """
  CI stuck (`pending`/no status at all) past the gate's deadline: nobody serves this label, or the
  runner is dead. It is escalated LOUD rather than waited on one more tick forever — a silent
  infinite wait is indistinguishable from a working rail, and that is the failure this whole gate
  exists to make impossible.
  """
  @spec ci_stalled(integer(), String.t(), term(), String.t(), Ctx.t()) ::
          {:skipped, term()} | {:error, term()}
  def ci_stalled(pr_number, head, class, message, %Ctx{} = ctx),
    do: escalate_ci(pr_number, head, ctx, class, message)

  defp escalate_ci(pr_number, head, %Ctx{} = ctx, class, message) do
    Logger.warning(
      "StepDispatcher: PR #{ctx.repo}##{pr_number} CI #{inspect(class)} — #{message}"
    )

    ArchEscalation.escalate_merge_blocked(
      arch_seams(ctx),
      pr_number,
      head,
      :ci,
      {class, message}
    )
  end

  defp count_ci_red(bodies, pr_number) do
    prefix = "[ci-red:pr-#{pr_number}:"

    bodies
    |> Enum.filter(&String.contains?(&1, prefix))
    |> length()
  end

  # The sha the gate measured, taken from the message it wrote rather than re-read from the forge:
  # the marker must key on the SAME sha the decision was made on, and a second read could answer a
  # different one (a push between the two calls) — which would silently un-bound the loop.
  defp extract_sha8(message) do
    case Regex.run(~r/\b([0-9a-f]{8})\b/, message) do
      [_, sha8] -> sha8
      _ -> nil
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
  # A policy block has TWO causes and they do not go to the same place. This function used to know
  # only one — the human re-request — so anything else fell through to `{:policy, :no_rerequest}`,
  # summoning a human with a reason that named the absence of a re-request rather than the actual
  # cause. Since the CI became a REQUIRED check (`protect_main`), the other cause is the common one.
  #
  # A red CI is not a human matter and it does NOT re-converge: nothing changes until the producer
  # pushes a new commit. So it routes to the producer, exactly like a REQUEST_CHANGES round, and the
  # rework budget bounds it — a CI that stays red does not loop forever, it ends up escalating with
  # the rounds spent, which is a true statement about what was tried.
  defp reconverge_policy(pr_number, head, %Ctx{} = ctx) do
    case ctx.forge.commit_ci_state(ctx.repo, head_sha(head, pr_number, ctx), ctx.forge_opts) do
      {:ok, :failure} ->
        Logger.info(
          "StepDispatcher: PR #{ctx.repo}##{pr_number} blocked by a RED CI → producer rework"
        )

        dispatch_rework(pr_number, head, ctx)

      {:ok, :pending} ->
        # The rail is still running. Not an incident and not a decision — the next tick asks again.
        {:skipped, :ci_pending}

      # `:success`, `:none`, or an unreadable status: the CI is not what blocks (or we cannot say it
      # is), so the question returns to the one cause this function already knew.
      _ ->
        reconverge_rerequest(pr_number, head, ctx)
    end
  end

  # The head SHA the CI posted its statuses on. `head` is the branch REF; the PR object carries the
  # sha. Falls back to the ref, which Gitea also resolves — a fallback that costs one redirect, not
  # a wrong answer.
  defp head_sha(head, pr_number, %Ctx{} = ctx) do
    case ctx.forge.get_pull(ctx.repo, pr_number, ctx.forge_opts) do
      {:ok, %{"head" => %{"sha" => sha}}} when is_binary(sha) -> sha
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
