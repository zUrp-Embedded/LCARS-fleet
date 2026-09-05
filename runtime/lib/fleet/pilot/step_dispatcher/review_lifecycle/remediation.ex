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
  """

  require Logger

  # Writing the human escalation (IMPURE cluster): Remediation DECIDES (rework budget /
  # merge-failure classification), ArchEscalation WRITES (deduplicated gatekeeper comment + `awaits-arch` lock).
  alias Fleet.Forge.Payload
  alias Fleet.Forge.Protocol
  alias Fleet.Layout
  alias Fleet.Pilot.StepDispatcher.ArchEscalation

  alias Fleet.Forge.Client, as: ForgeClient
  alias Fleet.Pilot.ConflictReport
  alias Fleet.Pilot.StepDispatcher.ReviewLifecycle.CiGate
  alias Fleet.Pilot.StepDispatcher.ReviewLifecycle.Ctx
  alias Fleet.Pilot.StepDispatcher.ReviewLifecycle.RoleDispatch
  alias Fleet.Workflow.Pinning

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
        with {:ok, budget} <- pr_rework_budget(ctx, issue_n),
             {:ok, rounds} <-
               ctx.forge.count_change_request_rounds(ctx.repo, pr_number, ctx.forge_opts),
             # Same budget bounds consecutive same-base publish failures.
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
          # Unverifiable brake escalates instead of looping blind.
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

  defp ci_pending_or_stalled(pr_number, head, %Ctx{} = ctx) do
    case CiGate.pending_stalled?(pr_number, head, ctx) do
      :stalled ->
        Logger.info(
          "StepDispatcher: PR #{ctx.repo}##{pr_number} — CI PENDANTE au-delà de la borne → arch"
        )

        ArchEscalation.escalate_merge_blocked(
          arch_seams(ctx),
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
        with {:ok, budget} <- pr_rework_budget(ctx, issue_n),
             {:ok, spent} <-
               ctx.forge.count_comments_marked(
                 ctx.repo,
                 issue_n,
                 Protocol.ci_rework_prefix(issue_n),
                 ctx.forge_opts
               ) do
          if spent >= budget do
            ArchEscalation.escalate_rework(
              arch_seams(ctx),
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
           Fleet.Pilot.WorkflowMapNav.safe_load(
             ctx.workflow_map_loader,
             map_name,
             Fleet.Workflow.Loader.card_opts_for_repo(ctx.repo)
           ) do
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
        conflict_rework(pr_number, head, reason, ctx)

      :unknown ->
        ArchEscalation.escalate_merge_blocked(arch_seams(ctx), pr_number, head, :unknown, reason)
    end
  end

  # Traitement de conflit deterministe, gate par config et ETEINT par defaut : le diagnostic route
  # AVANT toute ronde de producteur. Un conflit tout-semantique va a la passe d'exception — le
  # producteur est saute SUR PREUVE, le moteur ayant etabli qu'il n'y a rien de superficiel a
  # reparer ; un tout-trivial est resolu par le runtime, le jury rejugeant la tete neuve, donc une
  # mauvaise resolution est rattrapee en aval ; tout le reste retombe sur la voie longue.
  #
  # ⚠ LE GAIN NE FAIT QUE RACCOURCIR UN CHEMIN, JAMAIS EN CASSER UN. Sauter le producteur se fait
  # sur preuve ; il n'y en a AUCUNE sur l'echelon suivant, qu'il ne faut donc pas sauter — sans quoi
  # on va droit a un humain.
  #
  # ⚠ UNE SEULE NUMEROTATION, ET LES ECHELONS SONT NOMMES : un echelon mal compte route vers le
  # MAUVAIS acteur.
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
      # TRIPWIRE — the two readers disagree. We are on this path because the FORGE reported a
      # conflict; a probe that merges clean (0 hunks) is contradicting it, and that contradiction
      # has a known face: the probe reading a stale base (measured on the bench, PR#30, fixed in
      # ConflictProbe by the full fetch) — or a forge mergeable flag lagging a rework. Either way
      # the honest move is the same (fall through to the producer, who re-merges against the real
      # main) but it must be SAID: this exact silence is what let a dead tier 0 look like a
      # deliberate routing for a whole play.
      {:ok, %{totals: %{total: 0}}} ->
        Logger.warning(
          "ConflictProbe: PR ##{pr_number} — the forge reports a conflict, the probe merges " <>
            "clean (0 hunks). Stale probe base or lagging forge flag; falling through to " <>
            "producer rework."
        )

        :fall_through

      {:ok, diagnosis} ->
        tier0_act(tier0_decision(diagnosis), pr_number, head, reason, ctx, diagnosis)

      # A probe failure demotes tier 0 for THIS conflict — by design (the gain only ever shortens
      # a path). But a demotion nobody can see is indistinguishable from an engine nobody armed:
      # say why the rail got longer.
      {:error, reason_probe} ->
        Logger.warning(
          "ConflictProbe: probe failed on PR ##{pr_number} (#{inspect(reason_probe)}) — " <>
            "tier 0 unavailable, falling through to producer rework."
        )

        :fall_through
    end
  end

  # THE ENGINE'S REASONING REACHES A READER. `Fleet.Conflict` names the DecisionTrace its durable
  # value — "the REFUSAL is documented as much as the acceptance" — and it is produced per hunk and
  # carried by every Report. Dropped here, with this router reading `totals` and nothing else, the
  # engine writes a machine's worth of reasoning and publishes a count.
  #
  # Posted UNDER THE CHIEF's identity, while the resolution commit stays authored by the runtime
  # (`system_starfleet`, ForgeIdentity's single authority — A2). The two are different facts and both
  # are true: the engine held the pen, the chief owns the act (signature model rev 2-4: merged_by
  # says which FUNCTION closed the PR, the commit author says which SUBSTRATE wrote). Signing the
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
        ref: Layout.conflict_ref(pr_number),
        kind: "Rapport",
        label: "conflict",
        repo: ctx.repo
      )

    # A0 — the engine's STABLE marker. The seal chooses its merge method by reading the conflict
    # rail's forge-visible marks; tiers 1-2 post theirs at dispatch, tier 0 resolves WITHOUT a
    # dispatch — this report is the only place its mark can live. Appended OUTSIDE
    # `ConflictReport.render` (the report is a human text; the marker is protocol), and OUTSIDE
    # the pinning (a pinned body is summarized — the marker must survive on the comment itself).
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

  # On the AUTO-RESOLVED path the lost report is not just a missing explanation: the engine has no
  # dispatch, so the report's `[conflict-engine:pr-N]` mark is the seal's ONLY conflict signal for
  # this PR — without it the merge goes out in `rebase` and dies misclassified (`:policy`). The
  # other outcomes keep their own dispatch-time marks; their loss stays cosmetic.
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
  # PURE routing decision from the diagnosis totals (isolated so it is unit-testable).
  #
  # `:chief`, NOT `:escalate`. Sending an all-semantic conflict STRAIGHT to the arch — "rounds
  # skipped" — jumps tiers 1 AND 2, the PRODUCER and the CHIEF, to immobilize a human. Skipping the
  # producer is right and is the whole point of the deterministic pre-filter: the
  # engine has just proven there is nothing shallow to fix, so a producer round would burn a full
  # run to rediscover it.
  #
  # Skipping the CHIEF is not. Composing two intentions that both passed their jury, on a branch
  # the outsider did not write, IS the chief's case — it is what the exception pass exists for. The
  # ladder is tier 0 engine → tier 1 producer → tier 2 chief → tier 3 arch, and tier 0 may skip the
  # PRODUCER on evidence; it has none about the CHIEF. `:chief` names the routing; `:escalate`
  # would describe a hand-off that escalates nothing.
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

  defp diagnosis_enabled?,
    do: Application.get_env(:lcars_fleet, :pilot_conflict_diagnosis?, false)

  # The FACE of the conflict (face-projet, inventory #7/#8): called with `[]`, the
  # probe/apply helpers fall back to their `origin/main` default IN the code-face worktree — on an
  # ops PR that would resolve a conflict by merging the CODE face into a doc branch, silently, and
  # report `{:ok, :auto_resolved}`. The PR's own base (stamped at dispatch_review) names both
  # the merge target and the worktree the resolution runs in.
  defp conflict_face_opts(%Ctx{} = ctx) do
    base = Keyword.fetch!(ctx.opts, :pr_base_branch)

    name = Layout.project_name(ctx.repo)

    # ⚠ ON DELEGUE A L'AUTORITE DES FACES PLUTOT QUE DE LES ENUMERER ICI. Une enumeration ecrite a
    # la main en oublie une : la PR basee sur cette face-la tombe sur un `case` sans clause —
    # CaseClauseError, sur le chemin de remediation d'un conflit. L'intention est juste,
    # l'inventaire incomplet, et c'est exactement ce qu'une liste tenue a la main coute.
    #
    # Le `nil` reste une decision ecrite : ce n'est PAS une face, c'est une PR empilee sur une
    # branche de travail, resolue dans le worktree de code — la seule reponse disponible, la base ne
    # disant pas sur quelle face vit la branche dont elle fourche.
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

  # Producer conflict-rework budget exhausted → tier-2: give the OUTSIDER a single inference pass
  # before immobilizing a human (tier-3). The gate lives INSIDE `exception_stage` (its own flag,
  # A1) — this call site decides nothing.
  #
  # A1 — ET SURTOUT PAS LE COMMUTATEUR GITWAND, qui serait un defaut de propriete :
  # `pilot_conflict_diagnosis?` est le coupe-circuit de l'ADMIN pour un moteur d'origine externe
  # (tier 0), tandis que la passe du chief est un barreau de l'echelle d'escalade de la FLOTTE. Un
  # commutateur, deux proprietaires — le choix GitWand de l'admin retirerait en silence un barreau
  # qui n'a rien a voir avec GitWand (la passe ne consomme ni probe ni applier : elle compte des
  # marqueurs forge et dispatche un pod).
  defp producer_exhausted(pr_number, head, reason, %Ctx{} = ctx, producer_rounds) do
    exception_stage(pr_number, head, reason, ctx, producer_rounds)
  end

  defp exception_stage(pr_number, head, reason, %Ctx{} = ctx, producer_rounds) do
    # Self-gated (A1): BOTH callers land here — budget exhausted, and tier-0's all-semantic
    # shortcut — so the flag is read at ONE point. Off → the honest immediate escalation, with a
    # reason that NAMES the disabled rung: an arch reading the freeze must be able to tell "the
    # pass failed" from "the pass is not armed on this box".
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
        # THE LAST RUNG MUST NOT SWALLOW THE CASE. `RoleDispatch.dispatch` answers `{:skipped, _}`
        # when the `conflict_resolver` role does not resolve (absent from the catalogue, typo in a
        # card) or when the head is not a fleet branch. That skip is already LOUD — an unresolvable
        # role goes on the incident rail and its recurrence opens a sysadmin issue — but loud is not
        # the same as handled: the conflict itself would then sit on the PR with nobody left to look
        # at it, because the tier meant to try LAST could not run at all.
        #
        # A rung that cannot be climbed hands over to the next, it does not end the ladder.
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
  # ⚠ CE MARQUEUR EST FORGE-VISIBLE ET PORTANT (`count_comments_marked` le lit pour borner la passe
  # a une), donc le RENOMMER est une migration : une PR portant deja l'ancien compterait 0 et
  # obtiendrait une SECONDE passe. Le geste sur un tier qui tire : compter les deux prefixes
  # pendant un cycle.
  defp dispatch_exception_rework(pr_number, head, %Ctx{} = ctx) do
    signature = "[conflict-chief:pr-#{pr_number}:round-1]"

    # La BASE REELLE, pas `main` : ce commentaire est lu par un humain sur la PR, et `main` y decrit
    # une commande inexecutable des que la PR ne vise pas la face code. Meme valeur validee que celle
    # qui choisit le worktree (`conflict_face_opts/1`).
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
        # `conflict_resolver_role/0`, NOT `gatekeeper_role/0`: this dispatch decides who RESOLVES an
        # exhausted conflict, and the seal decides who SIGNS the merge. One key for both would make
        # substituting the resolver move the signatory too, silently.
        RoleDispatch.dispatch(
          :conflict_rework_exception,
          pr_number,
          head,
          Fleet.Project.Roles.conflict_resolver_role(),
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

  # Tier 1 of the conflict model (⚖ user): the producer resolves ON ITS PR — it has
  # the workspace, the brief unchanged, and the review budget; the judges then re-review the new
  # head (commit-scoped verdicts). Bounded by the SAME `max_rework_rounds` policy as the judge
  # rework, counted via the `[conflict-rework:pr-N` markers this path posts (round-numbered →
  # dedup makes the count replay-safe). Any unreadable read → tier 3, the honest arch escalation
  # (never a blind loop). Budget exhausted → tier 2 (ONE outsider pass, `exception_stage/5`, gated
  # by its OWN flag `:pilot_conflict_exception_pass?` — never by `:pilot_conflict_diagnosis?`),
  # then the arch.
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
    {:ok, {_issue_n, producer}} = Protocol.parse_feature_branch(head)
    producer
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
    ArchEscalation.escalate_merge_blocked(arch_seams(ctx), pr_number, head, class, message)
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
          :rerequest_read_failed,
          reason
        )
    end
  end

  # Boundary contract of the escalation writing: Remediation decides, ArchEscalation writes. We pass
  # it ONLY the 3 forge seams (`@enforce_keys` → an out-of-3-seams access does not compile), never the whole ctx.
  defp arch_seams(%Ctx{} = ctx),
    do: %ArchEscalation.Seams{forge: ctx.forge, repo: ctx.repo, forge_opts: ctx.forge_opts}
end
