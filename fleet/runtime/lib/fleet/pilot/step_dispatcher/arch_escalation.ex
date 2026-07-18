defmodule Fleet.Pilot.StepDispatcher.ArchEscalation do
  @moduledoc """
  IMPURE cluster "arch escalation" (forge write) extracted from `Fleet.Pilot.StepDispatcher`.

  When `StepDispatcher`'s decision core has ruled that a PR can no longer advance on its own —
  non-convergent rework (rounds budget exhausted, MA-06) or a merge blocked and not auto-resolvable (real
  git conflict / unclassified failure, cf. `Fleet.Pilot.MergeOutcome`) — it DELEGATES here the write of
  the escalation to the only human channel (the architect):

    1. a DEDUPLICATED gatekeeper comment (signed via `as_role`, `dedup_signature`) on the ISSUE;
    2. the `lcars-awaits-arch` lock set on the ISSUE → the poller SKIPS it (`decide/1`,
       `dispatch_review`), no more re-dispatch → end of the churn.

  This module DECIDES NOTHING: the rework budget (`count_change_request_rounds`/forge) and the
  classification of the merge failure (`Fleet.Pilot.MergeOutcome`) stay the core's SINGLE-AUTHORITY
  (`dispatch_rework`/`route_merge_failure`). This module ONLY WRITES — a single forge write point
  shared by the two escalations (`escalate_to_arch`, private), no fork of signature/label.

  ## Boundary: explicit seams struct (not the whole `ctx`)

  The cluster reads ONLY 3 seams of the dispatch (`forge`, `repo`, `forge_opts`). We do NOT pass the
  whole `ctx`/`opts` — that would be a boundary leak. The caller builds a `%Seams{}`
  (narrow, TYPED contract): `@enforce_keys` forces the 3 fields at the call, and an access
  `seams.<other_field>` does not compile (static KeyError) — a bare map would let
  `Map.get(seams, :spawner)` pass silently.

  ## Naming

  The public API is `escalate_rework/4` + `escalate_merge_blocked/5` (not `escalate_rework_to_arch`:
  the `_to_arch` suffix is now carried by the module name — `ArchEscalation.escalate_rework`
  reads without redundancy). `seams` is the 1st argument (the caller builds the contract, THEN
  describes the escalation).

  **Last revised**: 2026-07-18
  """

  # Protocol vocabulary = single source Fleet.Labels (compile-time constant, as in
  # StepDispatcher which keeps ITS @awaits_arch_label for `decide/1` — same source, not a fork).
  require Logger

  @awaits_arch_label Fleet.Labels.awaits_arch()

  defmodule Seams do
    @moduledoc """
    Boundary contract of the arch escalation cluster: the 3 forge-write seams read from the dispatch
    (`forge`/`repo`/`forge_opts`). Built by the caller BEFORE `escalate_rework/4` or
    `escalate_merge_blocked/5` — the cluster never receives the whole `ctx`/`opts`.
    """
    @enforce_keys [:forge, :repo, :forge_opts]
    defstruct [:forge, :repo, :forge_opts]

    @type t :: %__MODULE__{
            # Injected forge client (seam `:forge_client`, prod default `Fleet.Pilot.ForgeClient`).
            forge: module(),
            # The repo's `owner/name` (the escalation writes on this repo's ISSUE).
            repo: String.t(),
            # Forge opts (base_url/token…); gatekeeper `as_role` + dedup are added to it.
            forge_opts: keyword()
          }
  end

  @doc """
  PR rework exhausted (rounds > budget, or unreadable budget) → the arch rules. Symmetric to
  `escalate_merge_blocked/5`: deduplicated gatekeeper comment + `lcars-awaits-arch` lock on
  the ISSUE (the poller SKIPS it, no more re-dispatch). `detail` (map `%{rounds, budget}` or
  `{:budget_unreadable, reason}`) goes INTO the comment, not into the dedup key.

  Returns `{:skipped, {:rework_exhausted_escalated, pr_number}}` (form handled by the poller). Non-fleet
  head (anomaly: the caller already parsed the producer upstream) → `{:skipped,
  :not_fleet_branch}` (defensive).
  """
  @spec escalate_rework(Seams.t(), integer(), String.t(), term()) :: {:skipped, term()}
  def escalate_rework(%Seams{} = seams, pr_number, head, detail) do
    with {:ok, issue_n} <- issue_of_branch_or_skip(head) do
      signature = "[rework-exhausted-escalation:pr-#{pr_number}]"

      body =
        "**Architecte** — ⚠ Rework non convergent sur la PR ##{pr_number} (issue ##{issue_n}) : le budget " <>
          "de rounds de review est épuisé (`#{inspect(detail)}`). Le producteur ne satisfait pas les juges. " <>
          "Reprends : re-cadre le brief, tranche le désaccord, ou ferme la PR. L'issue reste hors-dispatch " <>
          "tant que `lcars-awaits-arch` est posé.\n\n" <> signature

      escalate_to_arch(seams, issue_n, signature, body)
      {:skipped, {:rework_exhausted_escalated, pr_number}}
    end
  end

  @doc """
  Merge blocked and NOT auto-resolvable by the system (real git conflict, or unclassified failure) → the arch
  rules. `class` (`:conflict` | other) comes from `Fleet.Pilot.MergeOutcome`: the message states the REAL
  cause, never "after a rebase attempt" (the system does NOT rebase — forge-blind barrier,
  mechanical resolution = later increment). Deduplicated gatekeeper comment + `lcars-awaits-arch`
  lock on the ISSUE → the poller SKIPS it (out-of-dispatch, no more retry; the label IS the
  throttle). `reason` (forge detail of the failed merge) goes INTO the comment.

  Returns `{:skipped, {:merge_blocked_escalated, pr_number}}` = form HANDLED by the poller
  (`step_process_pulls`) → counted skipped, no crash. An `{:escalated, _}` would be in NO
  clause of the `case do_poll` → CaseClauseError at each tick: a dispatch return MUST be
  `{:ok|:skipped|:error}`, never a 4th form. Non-fleet head → `{:skipped, :not_fleet_branch}`.
  """
  @spec escalate_merge_blocked(Seams.t(), integer(), String.t(), atom(), term()) ::
          {:skipped, term()}
  def escalate_merge_blocked(%Seams{} = seams, pr_number, head, class, reason) do
    with {:ok, issue_n} <- issue_of_branch_or_skip(head) do
      signature = "[merge-blocked-escalation:pr-#{pr_number}]"

      body =
        "**Architecte** — ⚠ Merge bloqué sur la PR ##{pr_number} (issue ##{issue_n}) — " <>
          merge_blocked_cause(class, reason) <>
          " Le système n'y touche PAS (barrière forge-aveugle : le pod n'a pas de credentials pour " <>
          "rebaser). Reprends : résous/rebase la PR sur `main` (ou re-cadre). L'issue reste hors-dispatch " <>
          "tant que `lcars-awaits-arch` est posé.\n\n" <> signature

      escalate_to_arch(seams, issue_n, signature, body)
      {:skipped, {:merge_blocked_escalated, pr_number}}
    end
  end

  # HONEST cause per the REAL class (MergeOutcome) — never "after a rebase attempt" that we did
  # NOT do (the mechanical resolution is a later increment; here we ESCALATE, we claim nothing).
  defp merge_blocked_cause(:conflict, _reason),
    do:
      "conflit git (les deux côtés touchent les mêmes lignes) → le merge automatique est impossible, résolution manuelle requise."

  defp merge_blocked_cause(:policy, _reason),
    do:
      "blocage de branch-protection non levable mécaniquement (commits signés requis, ou une approbation manquante hors re-request) → à débloquer manuellement."

  defp merge_blocked_cause(_unknown, reason),
    do:
      "échec de merge non classifié par le système (`#{inspect(reason)}`) → à trancher manuellement."

  # CORE of arch escalation (factored — conflict AND exhausted rework): DEDUPLICATED gatekeeper comment
  # (signed via `as_role`) + `lcars-awaits-arch` lock on the ISSUE → the poller SKIPS it
  # (out-of-dispatch). We surface to the human channel (the arch), we do not mask: the LABEL is the
  # load-bearing effect (its failure is logged error below), the comment is explanatory only. A single
  # forge write point for all PR arch escalations (no fork of signature/label).
  defp escalate_to_arch(%Seams{} = seams, issue_n, signature, body) do
    # Gatekeeper-signed comment (EXPLANATORY, not load-bearing) via the UNIQUE writer
    # `GatekeeperSeal.as_gatekeeper/1`. Fail-CLOSED on the token: if the gatekeeper role token is
    # unavailable, SKIP the comment (do not post it under the system account) but STILL post the
    # load-bearing `lcars-awaits-arch` label (system, the poller throttle) — the escalation's effect
    # (out-of-dispatch) holds regardless of the comment. A failed/skipped post is LOGGED (never
    # retried: once the label sticks, `decide/1` skips → no re-post path exists) — the arch would
    # otherwise see the throttle label with no explanation and no trace of why.
    case Fleet.Pilot.GatekeeperSeal.as_gatekeeper(seams.forge_opts) do
      {:ok, gk} ->
        gk_opts =
          gk |> Keyword.put(:dedup_signature, signature) |> Keyword.put(:dedup_any_author, true)

        case seams.forge.post_comment(seams.repo, issue_n, body, gk_opts) do
          {:ok, _} ->
            :ok

          {:error, reason} ->
            Logger.warning(
              "ArchEscalation: issue ##{issue_n} escalation comment NOT posted (#{inspect(reason)}) — " <>
                "the arch will see the awaits-arch label without its explanation (no re-post rail)"
            )
        end

      {:error, reason} ->
        Logger.warning(
          "ArchEscalation: issue ##{issue_n} escalation comment SKIPPED (gatekeeper token: " <>
            "#{inspect(reason)}) — label-only escalation, no explanation on the issue"
        )
    end

    case seams.forge.add_label(seams.repo, issue_n, @awaits_arch_label, seams.forge_opts) do
      {:error, reason} ->
        # `lcars-awaits-arch` IS the throttle (`decide/1` / `dispatch_review` skip on it). A failed label →
        # the PR is re-dispatched every tick (the exact churn this escalation exists to STOP), while we report
        # `{:skipped, _escalated}`. NOT silent → LOG LOUD (an operator must know the escalation did not throttle).
        Logger.error(
          "ArchEscalation: issue ##{issue_n} escalated but throttle label #{inspect(@awaits_arch_label)} " <>
            "NOT added (#{inspect(reason)}) — the PR will re-dispatch (churn) until the label sticks"
        )

      _ ->
        :ok
    end

    :ok
  end

  # Extracts the parent ISSUE number from the feature-branch (`lcars/issue-<n>-<role>`) via the
  # UNIQUE parser `Fleet.Pilot.ForgeProtocol.parse_feature_branch/1` (not a homemade re-parse). Local
  # adapter `{:ok, issue_n} | {:skipped, :not_fleet_branch}` — the producer does not interest
  # the escalation (it writes on the issue), hence a narrower return than
  # `RoleDispatch.parse_feature_branch_or_skip` (which returns the full `{n, role}` tuple for the review dispatch).
  defp issue_of_branch_or_skip(head) do
    case Fleet.Pilot.ForgeProtocol.parse_feature_branch(head) do
      {:ok, {issue_n, _producer}} -> {:ok, issue_n}
      :error -> {:skipped, :not_fleet_branch}
    end
  end
end
