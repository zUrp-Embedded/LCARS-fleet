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
  conflict / unknown. Each has its own routing. A REAL conflict goes to
  `Remediation.ConflictLadder.run/4` — four rungs, engine → producer → chief → arch, bounded on
  the forge by the same `max_rework_rounds` as the judge rework.
  The throttle for escalated cases = the `lcars-awaits-arch` lock laid by `ArchEscalation` (the poller
  SKIPS the issue), not an IncidentRegistry (there is no resolution loop to bound here).

  The DECISION lives here; the EXECUTION of the re-spawn descends to `RoleDispatch` (leaf shared with the
  judge spawn — no fork of the mechanics); the WRITING of the human escalation descends to
  `ArchEscalation` (narrow seams rebuilt HERE, never the whole `Ctx`). What this module writes on
  the forge ITSELF is its own protocol, not an escalation: the rung markers that bound each pass
  (`[ci-red:`, `[conflict-rework:`, `[conflict-chief:`) and the tier-0 conflict report
  (private `post_conflict_report/4`, signed chief).
  """

  require Logger

  alias Fleet.Pilot.StepDispatcher.ReviewLifecycle.Remediation.ConflictLadder

  # Writing the HUMAN escalation (IMPURE cluster): Remediation DECIDES (rework budget /
  # merge-failure classification), ArchEscalation WRITES it (deduplicated gatekeeper comment +
  # `awaits-arch` lock). The rung markers and the conflict report are this module's own writes.
  alias Fleet.Forge.Payload
  alias Fleet.Forge.Protocol
  alias Fleet.Pilot.StepDispatcher.ArchEscalation

  alias Fleet.Pilot.StepDispatcher.ReviewLifecycle.CiGate
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
    case Protocol.parse_feature_branch(head) do
      {:ok, {issue_n, producer_role}} ->
        with {:ok, budget} <- Ctx.rework_budget(ctx, issue_n),
             {:ok, rounds} <-
               ctx.forge.count_change_request_rounds(ctx.repo, pr_number, ctx.forge_opts),
             # Same budget bounds consecutive same-base publish failures.
             {:ok, publish_fails} <-
               count_publish_failures(ctx, issue_n) do
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

  # ⚠ LE BUDGET DE `dispatch_rework` NE BORNE PAS CE CHEMIN, et c'est pourquoi ce détour existe.
  # Il compare `count_change_request_rounds` — des reviews REQUEST_CHANGES — au budget de la carte.
  # Un CI rouge n'en pose AUCUNE : le compteur reste immobile, `rounds <= budget` reste vrai, et le
  # producteur est redispatché à chaque fois que le label `in_flight` retombe. Le label empêche la
  # tempête de ticks ; rien n'empêche la suite infinie de rounds, chacun coûtant un pod.
  #
  # Le round dépensé est donc ENREGISTRÉ sur le ticket (`ci_rework_marker`), forge-natif comme les
  # freins voisins : pas d'état en RAM, un compteur qu'un humain peut lire sur l'issue. Il se compte
  # par `count_comments_marked/4`, le même compteur que le rail conflit — un seul mécanisme.
  #
  # ⚠ LE MARQUEUR EST POSÉ APRÈS UN SPAWN RÉEL, jamais avant. `dispatch_rework` rend
  # `{:skipped, :role_busy}` ou `{:skipped, :role_at_capacity}` sans rien lancer : marquer là
  # dépenserait un round que personne n'a joué, et le budget se viderait sur une file d'attente.
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
        else
          # Un frein invérifiable escalade, il ne boucle pas en aveugle — même posture que
          # `dispatch_rework`.
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
        # Le round est JOUÉ (le pod tourne) et non compté : le frein sous-compte, il ne sur-compte
        # pas. On le DIT plutôt que de refuser un rework déjà lancé.
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
    * `:conflict` → the 4-tier ladder of `ConflictLadder.run/4`, tier 0 gated by `:pilot_conflict_diagnosis?`:
                    tier 0 (deterministic diagnosis + auto-resolution of an all-trivial conflict,
                    runtime, no pod), tier 1 (BOUNDED producer conflict-rework: local resolution on
                    the same PR — needs no forge credentials), tier 2 (ONE outsider pass, the
                    `conflict_resolver` role, gated by its OWN flag `:pilot_conflict_exception_pass?`),
                    tier 3 (honest arch escalation). Flag off → tiers 1, 2, 3 without the engine.
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

      # A REAL git conflict is mechanically recoverable by the PRODUCER (tier 1 — measured live, a
      # full re-delegated chain costs 4 agent passes and ~7 min for what a local merge-resolve on
      # the SAME PR handles): bounded conflict-rework, budget exhausted →
      # honest escalation (tier 3). `:unknown` stays a straight escalation (we don't guess).
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

    # THE CLASS, NOT A LITERAL `:ci`: `merge_blocked_cause/2` has a clause per CI class, and the
    # architect must read « no runner serves this label » or « no workflow can render a verdict »,
    # never the catch-all (2026-09-05).
    ArchEscalation.escalate_merge_blocked(Ctx.arch_seams(ctx), pr_number, head, class, message)
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

  # `:policy` = git-mergeable but the forge refuses. The CI is read FIRST (`reconverge_on_ci/3`:
  # red → producer, pending → bounded wait); then the human cause: a RE-REQUEST reset the
  # branch-protection approval counter. We read the timeline (`pr_rerequested_reviewers`) → the
  # re-requested judge(s) → we re-dispatch the first (spawn re-review, serialized by the PR lock;
  # the rest on the next tick). It's the "re-request a judgment" button doing its job. No
  # re-requested = policy block not mechanically liftable (signed commits required) → honest
  # escalation rather than a silent wedge.
  # ⚠ UN BLOCAGE POLICY A DEUX CAUSES, ET ELLES NE VONT PAS AU MEME ENDROIT. N'en connaitre qu'une —
  # la re-demande humaine — fait tomber l'autre dans un fourre-tout qui convoque un humain en nommant
  # l'ABSENCE de re-demande plutot que la cause reelle.
  #
  # Une CI rouge n'est pas une affaire humaine et NE RE-CONVERGE PAS : rien ne change tant que le
  # producteur ne pousse pas. Elle route donc vers lui, comme une ronde de revue, et le budget de
  # rework la borne — une CI qui reste rouge finit par escalader AVEC les rondes depensees, ce qui
  # est un enonce vrai de ce qui a ete tente.
  #
  # ⚠ ET CE SITE LIT TOUJOURS L'ETAT REEL DE LA CI, MEME QUAND LA CARTE DIT DE L'IGNORER : la carte
  # gouverne le JURY — convoquer ou non des juges — tandis que la protection de branche est un FAIT
  # de la forge, que la carte ne peut pas abroger. Court-circuiter la lecture sur la foi de la carte
  # classe en `:policy` un refus TRANSITOIRE — le runner n'a pas encore couru sur le sha neuf — et
  # immobilise un humain pour une attente de trente secondes.
  #
  # Le cas « aucun runner n'a jamais repondu » tombe dans le catch-all et re-demande, donc rien ne
  # se bloque : seuls un rail EN COURS (on retick) et un rouge sur la tete (le producteur repare)
  # changent de traitement.
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
        # Le rail tourne encore — ni incident ni décision, le tick suivant redemande. MAIS PAS
        # INDÉFINIMENT : sous une carte `ci: ignore`, ce site est le SEUL lecteur de la CI (le gate
        # ne s'applique pas), et un job qu'aucun runner ne réclame y attendait en silence pour
        # toujours. La borne est celle du gate, pas une seconde.
        ci_pending_or_stalled(pr_number, head, ctx)

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
