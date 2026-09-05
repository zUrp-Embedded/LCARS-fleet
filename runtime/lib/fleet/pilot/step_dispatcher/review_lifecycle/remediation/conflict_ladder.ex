defmodule Fleet.Pilot.StepDispatcher.ReviewLifecycle.Remediation.ConflictLadder do
  @moduledoc """
  The CONFLICT ladder of a PR that cannot merge — one machine, four rungs, entered by
  `Remediation.route_merge_failure/4` on a real git conflict and nowhere else:

    * **tier 0** — the deterministic engine (`:pilot_conflict_diagnosis?`, off by default): probe
      (`ConflictProbe`), then `tier0_decision/1` — all-semantic → the chief, all-writable → the
      runtime writes (`ConflictApply`) and the jury re-judges the new head, else fall through;
    * **tier 1** — the producer resolves ON ITS PR, bounded by the card's `max_rework_rounds`,
      counted on the forge (`[conflict-rework:pr-N`);
    * **tier 2** — ONE outsider pass by the `conflict_resolver` (`:pilot_conflict_exception_pass?`),
      bounded by `[conflict-chief:pr-N`;
    * **tier 3** — the architect, through `ArchEscalation`, with the rung that stopped named.

  The rung markers and the tier-0 report (`[conflict-engine:pr-N:<outcome>]`, signed chief) are
  this module's own forge writes: they are the ladder's protocol — the seal reads them to choose
  its merge method — not an escalation. Every budget is forge-native; a restart buys no extra pass.
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
    # pass failed" from "the pass is not armed on this container".
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

      # Budget/counter unreadable → the arch rules (symmetric to dispatch_rework's stance):
      # never a blind loop, never a guessed round.
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
          Ctx.arch_seams(ctx),
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
end
