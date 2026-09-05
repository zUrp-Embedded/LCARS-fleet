defmodule Fleet.Pilot.StepDispatcher.ReviewLifecycle.VerdictException do
  @moduledoc """
  Tier 2 of the VERDICT rail: ONE arbitration pass by the gatekeeper on a gray zone, before a human
  is immobilized.

  Structural twin of the conflict rail's chief pass (`Remediation.exception_stage/5`), deliberately:
  same forge-native marker bounding it to one pass, same self-gating flag, same handover to the arch
  when the rung cannot be climbed. The two ladders answer different questions — "who resolves a
  conflict" vs "who settles a contradiction" — and share their SHAPE, which is what makes either one
  readable to someone who has learnt the other.

  ## What a gray zone is, and what the gatekeeper is asked

  The jury returned a unanimously FAVOURABLE OPINION; the card's tolerance curve refuses on findings
  those same judges wrote (`Jury.review_outcome/5` → `:gray_zone`). Nobody is wrong yet: the judge
  may have waved through a real defect, or measured severely something this deliverable can live
  with.

  ⚖ « OPINION », NOT « APPROVAL », AND THE WORD IS LOAD-BEARING. The truth taxonomy
  (moon-shot `iec-like-rigor`) tags a judge's verdict JUDGED — soft gate, "never an acceptance on
  its own". The acceptance belongs to the rail: a green CI (PROVEN) as a floor, then the seal.
  Writing "the jury approved" credited the judges with an act that is not theirs, and it told the
  arbiter its own decision had already been taken by others — the opposite of its mandate. The
  forge keeps its own word (`APPROVED` stays the review state: branch protection counts them and
  the seal reads them back); it is the PROSE a human reads that must tell the truth.

  The gatekeeper is the OUTSIDER who settles it — and its verdict is a plain review on the PR, so the
  next tick reads it through the same predicate as everything else. No new resumption machinery, no
  second decision channel.

  ## Why it is bounded to exactly one pass

  The marker is the budget, and it lives ON THE FORGE (`[verdict-gatekeeper:pr-N`) rather than in
  the pilot's memory: a restart must not buy a second arbitration, and a human must be able to see
  on the PR that this rung was spent. Beyond it, the arch — an arbitration that did not converge is
  precisely the case a human has to look at.
  """

  require Logger

  alias Fleet.Pilot.StepDispatcher.ArchEscalation
  alias Fleet.Pilot.StepDispatcher.ReviewLifecycle.Ctx
  alias Fleet.Pilot.StepDispatcher.ReviewLifecycle.RoleDispatch

  @doc """
  Summons the gatekeeper on a gray-zone PR, or escalates.

  Returns the dispatch result, or `{:skipped, _}` when the pass is unavailable — every exit lands
  somewhere a human or a producer can act on; none of them drops the PR.
  """
  @spec dispatch(integer(), String.t(), map(), map() | nil, Ctx.t()) ::
          {:ok, tuple()} | {:skipped, term()} | {:error, term()}
  def dispatch(pr_number, head, findings, policy, %Ctx{} = ctx) do
    # Self-gated like the chief pass: `:pilot_verdict_exception_pass?` is armed by the shipped
    # config (`config/config.exs`) and off by the code default, so a box that drops the config
    # line loses the rung without a crash. The disabled path is not a silent no-op — it names the
    # unarmed rung in the escalation, so an arch reading the freeze can tell "the pass failed"
    # from "the pass is not armed on this box".
    if enabled?() do
      do_dispatch(pr_number, head, findings, policy, ctx)
    else
      escalate(pr_number, head, :verdict_pass_disabled, ctx)
    end
  end

  defp enabled?, do: Application.get_env(:lcars_fleet, :pilot_verdict_exception_pass?, false)

  defp do_dispatch(pr_number, head, findings, policy, %Ctx{} = ctx) do
    marker = "[verdict-gatekeeper:pr-#{pr_number}"

    case decision(ctx.forge.count_comments_marked(ctx.repo, pr_number, marker, ctx.forge_opts)) do
      :dispatch -> summon(pr_number, head, findings, policy, ctx)
      :escalate -> escalate(pr_number, head, :verdict_pass_spent, ctx)
    end
  end

  @doc false
  # PURE gate: one arbitration, then the arch. An UNREADABLE count escalates rather than dispatches
  # — the same direction the conflict rail chose, and for the same reason: not knowing how many
  # passes were spent must never buy another one.
  @spec decision({:ok, integer()} | {:error, term()}) :: :dispatch | :escalate
  def decision({:ok, spent}) when is_integer(spent) and spent < 1, do: :dispatch
  def decision(_), do: :escalate

  defp summon(pr_number, head, findings, policy, %Ctx{} = ctx) do
    signature = "[verdict-gatekeeper:pr-#{pr_number}:round-1]"
    role = Fleet.Project.Roles.gatekeeper_role(ctx.opts)

    body =
      "⚖ **Zone grise du verdict** — les juges ont rendu un AVIS FAVORABLE sur cette PR, et la " <>
        "carte du projet la refuse sur les mesures que ces mêmes juges ont produites (seuil " <>
        "`#{block_at(policy)}`). Aucun juge ne s'oppose : c'est une contradiction, pas un refus — " <>
        "et personne n'a encore accepté quoi que ce soit.\n\n" <>
        "Passe d'arbitrage unique : le **#{role}** relit le livrable et les rapports, puis rend un " <>
        "verdict qui tranche — approuver malgré la courbe, ou confirmer le renvoi au producteur. " <>
        "Au-delà de cette passe, l'arbitrage revient à l'architecte.\n\n" <> signature

    comment_opts =
      ctx.forge_opts
      |> Keyword.put(:dedup_signature, signature)
      |> Keyword.put(:dedup_any_author, true)

    case ctx.forge.post_comment(ctx.repo, pr_number, body, comment_opts) do
      {:ok, _} ->
        # `:judge`, not a kind of its own: the gatekeeper JUDGES the deliverable, and every judge
        # dispatch on a PR already builds the right brief, posts through the right token and lands
        # its verdict as a review the next tick reads. What makes this pass an exception is not how
        # the pod works — it is WHY it was summoned, and that lives in the brief (`:gray_zone`) and
        # on the PR (the marker above), where a reader can see both.
        case RoleDispatch.dispatch(
               :judge,
               pr_number,
               head,
               role,
               with_gray_zone(ctx, findings, policy)
             ) do
          {:skipped, why} ->
            # A rung that cannot be climbed hands over to the next; it does not end the ladder.
            # Same lesson the chief pass wrote: `RoleDispatch` skips loudly when a role does not
            # resolve, and loud is not handled — the PR would sit there with nobody left to look
            # at it.
            Logger.warning(
              "VerdictException: PR #{ctx.repo}##{pr_number} gatekeeper arbitration NOT " <>
                "dispatched (#{inspect(why)}) — escalating to the arch rather than leaving a " <>
                "gray zone nobody owns"
            )

            escalate(pr_number, head, {:verdict_pass_undispatchable, why}, ctx)

          other ->
            other
        end

      {:error, reason} ->
        # The marker IS the budget. Failing to post it and dispatching anyway would buy an
        # unbounded number of arbitrations — every tick would read zero markers and summon again.
        Logger.warning(
          "VerdictException: PR #{ctx.repo}##{pr_number} marker NOT posted (#{inspect(reason)}) — " <>
            "arbitration not dispatched (an unrecorded pass is an unbounded one)"
        )

        {:skipped, {:verdict_marker_unposted, reason}}
    end
  end

  # The facts the gatekeeper arbitrates on, threaded like `:ci_fact` before them: measured by the
  # gate, quoted by the brief. Re-reading them pod-side would be a second truth on one dispatch.
  defp with_gray_zone(%Ctx{} = ctx, findings, policy) do
    %{ctx | opts: Keyword.put(ctx.opts, :gray_zone, %{findings: findings, policy: policy})}
  end

  defp block_at(%{"block_at" => at}) when is_binary(at), do: at
  defp block_at(_), do: "—"

  defp escalate(pr_number, head, reason, %Ctx{} = ctx) do
    ArchEscalation.escalate_merge_blocked(
      Ctx.arch_seams(ctx),
      pr_number,
      head,
      :verdict_gray_zone,
      reason
    )
  end
end
