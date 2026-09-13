defmodule Fleet.Pilot.StepDispatcher.ReviewLifecycle.VerdictException do
  @moduledoc """
  Arbitrates a gray zone: favorable jury opinions whose findings exceed the card's tolerance.

  A favorable opinion is not final acceptance, even though the forge review state is
  `APPROVED`. The gatekeeper writes an ordinary PR review, read by the same jury
  predicate on subsequent polls. This module does not run the CI gate.

  The `:pilot_verdict_exception_pass?` flag and forge `[verdict-gatekeeper:pr-N`
  counter bound admission. The marker survives restarts but is posted before dispatch:
  busy/failed dispatch can consume the pass. Count/post/dispatch are not atomic;
  comment deduplication alone does not prevent concurrent dispatches.
  """

  require Logger

  alias Fleet.Pilot.StepDispatcher.ArchEscalation
  alias Fleet.Pilot.StepDispatcher.ReviewLifecycle.Ctx
  alias Fleet.Pilot.StepDispatcher.ReviewLifecycle.RoleDispatch

  @doc """
  Attempts arbitration, escalating when disabled, spent/unreadable or dispatch returns a skip.

  A marker write error returns `{:skipped, {:verdict_marker_unposted, reason}}`
  without escalation. Other dispatch errors return unchanged; exceptions propagate.
  """
  @spec dispatch(integer(), String.t(), map(), map() | nil, Ctx.t()) ::
          {:ok, tuple()} | {:skipped, term()} | {:error, term()}
  def dispatch(pr_number, head, findings, policy, %Ctx{} = ctx) do
    # Code default is off; a disabled stage has a distinct escalation reason.
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
  # Unreadable counts share the spent-pass escalation reason.
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
        # Reuse judge execution; the exception's findings and policy travel in :gray_zone.
        case RoleDispatch.dispatch(
               :judge,
               pr_number,
               head,
               role,
               with_gray_zone(ctx, findings, policy)
             ) do
          {:skipped, why} ->
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
        # Do not dispatch an unrecorded pass: future counts would still allow it.
        Logger.warning(
          "VerdictException: PR #{ctx.repo}##{pr_number} marker NOT posted (#{inspect(reason)}) — " <>
            "arbitration not dispatched (an unrecorded pass is an unbounded one)"
        )

        {:skipped, {:verdict_marker_unposted, reason}}
    end
  end

  # Quote the caller's findings and policy in the brief without re-reading them here.
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
