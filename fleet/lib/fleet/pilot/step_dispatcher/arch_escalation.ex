defmodule Fleet.Pilot.StepDispatcher.ArchEscalation do
  @moduledoc """
  IMPURE cluster "arch escalation" (forge write) of `Fleet.Pilot.StepDispatcher`.

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

  ## Family

  One of FOUR escalation exits. The family register — the four exits, the overlap under watch and
  its COUNT — lives once, in `Fleet.Pilot`'s moduledoc. Read it before adding a fifth: the standing
  decision is to merge the two overlapping ones when a fifth appears, and that threshold only works
  if the count is kept in one place.

  ## Boundary: explicit seams struct (not the whole `ctx`)

  The cluster reads ONLY 3 seams of the dispatch (`forge`, `repo`, `forge_opts`). We do NOT pass the
  whole `ctx`/`opts` — that would be a boundary leak. The caller builds a `%Seams{}`
  (narrow, TYPED contract): `@enforce_keys` forces the 3 fields at the call, and an access
  `seams.<other_field>` does not compile (static KeyError) — a bare map would let
  `Map.get(seams, :spawner)` pass silently.

  ## Naming

  The public API is `escalate_rework/4` + `escalate_merge_blocked/5` (not `escalate_rework_to_arch`:
  the `_to_arch` suffix is carried by the module name — `ArchEscalation.escalate_rework`
  reads without redundancy). `seams` is the 1st argument (the caller builds the contract, THEN
  describes the escalation).

  ## Two freeze rails, ONE invariant discipline (CI-04) — deliberate, NOT merged

  This PR-side freeze and the issue-side `StepRunCompleter.await_arch` share the SAME shape —
  dedup comment addressed to the arch → `lcars-awaits-arch` throttle (load-bearing) → `lcars-in-flight`
  removal (invariant maintenance) — and now the SAME integrity discipline: the throttle is verified and
  surfaces on failure (C-02), the in-flight retrait is verified and surfaces on failure (CI-04, `escalate_to_arch`
  below). They stay SEPARATE functions on purpose: the SIGNATORY differs (gatekeeper here — a ruling on
  rework/merge — vs the JUDGE on `await_arch`, whose comment IS the verdict record), and so does the
  comment's WEIGHT (explanatory here, load-bearing verdict there). Folding both into one primitive
  parameterized by signatory/text/weight/return would relocate the divergence into a parameter soup, not
  remove it. The convergence that matters is the shared invariant discipline, enforced identically on both
  rails — not a physical merge.
  """

  # Protocol vocabulary = single source Fleet.Labels (compile-time constant, as in
  # StepDispatcher which keeps ITS @awaits_arch_label for `decide/1` — same source, not a fork).
  require Logger

  @awaits_arch_label Fleet.Labels.awaits_arch()
  @in_flight_label Fleet.Labels.in_flight()

  defmodule Seams do
    @moduledoc """
    Narrow forge-write dependency boundary.
    """
    @enforce_keys [:forge, :repo, :forge_opts]
    defstruct [:forge, :repo, :forge_opts]

    @type t :: %__MODULE__{
            # Injected forge client (seam `:forge_client`, prod default `Fleet.Forge.Client`).
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

  Returns `{:skipped, {:rework_exhausted_escalated, pr_number}}` when the throttle label took (form
  handled by the poller), or `{:error, {:escalation_incomplete, pr_number, reason}}` when it did NOT
  (C-02: honest error tally, not a lying skip — the poller re-attempts next tick). Non-fleet head
  (anomaly: the caller already parsed the producer upstream) → `{:skipped, :not_fleet_branch}` (defensive).
  """
  @spec escalate_rework(Seams.t(), integer(), String.t(), term()) ::
          {:skipped, term()} | {:error, term()}
  def escalate_rework(%Seams{} = seams, pr_number, head, detail) do
    with {:ok, issue_n} <- issue_of_branch_or_skip(head) do
      signature = Fleet.Forge.Protocol.rework_exhausted_marker(pr_number)

      body =
        "**Architecte** — ⚠ Rework non convergent sur la PR ##{pr_number} (issue ##{issue_n}) : le budget " <>
          "de rounds de review est épuisé (`#{inspect(detail)}`). Le producteur ne satisfait pas les juges. " <>
          "Reprends : re-cadre le brief, tranche le désaccord, ou ferme la PR. L'issue reste hors-dispatch " <>
          "tant que `lcars-awaits-arch` est posé.\n\n" <> signature

      case escalate_to_arch(seams, issue_n, signature, body) do
        :ok -> {:skipped, {:rework_exhausted_escalated, pr_number}}
        {:error, reason} -> {:error, {:escalation_incomplete, pr_number, reason}}
      end
    end
  end

  @doc """
  Publish brake tripped (chantier frein-publish): the producer's deliverable REPEATEDLY failed to
  publish on the same gate base — the work never reaches the forge, the judges never re-judge, and
  without this brake the rework loop burns a real producer session per tick with `max_rework_rounds`
  frozen (it counts VERDICTS, and a failed publish produces none — measured on the faceproof
  bench, 5 identical rounds). Own signature: a publish brake and a rework-exhausted are different
  failure modes and each deserves its own trace. Same mechanism as every escalation: dedup comment
  + `lcars-awaits-arch` on the ISSUE — the label IS the throttle.
  """
  @spec escalate_publish_failures(Seams.t(), integer(), String.t(), map()) ::
          {:skipped, term()} | {:error, term()}
  def escalate_publish_failures(%Seams{} = seams, pr_number, head, detail) do
    with {:ok, issue_n} <- issue_of_branch_or_skip(head) do
      signature = "[publish-brake-escalation:pr-#{pr_number}]"

      body =
        "**Architecte** — ⚠ Frein publish : le livrable du producteur échoue à se publier en " <>
          "boucle sur la PR ##{pr_number} (issue ##{issue_n}) — #{inspect(detail)}. Le travail " <>
          "du pod n'atteint jamais la forge (les juges ne re-jugent donc jamais). Les marqueurs " <>
          "`[publish-fail:...]` de l'issue portent chaque échec avec sa raison. Reprends : lis le " <>
          "dernier échec (le diagnostic nomme HEAD et son parent), tranche, ou ferme la PR. " <>
          "L'issue reste hors-dispatch tant que `lcars-awaits-arch` est posé.\n\n" <> signature

      case escalate_to_arch(seams, issue_n, signature, body) do
        :ok -> {:skipped, {:publish_brake_escalated, pr_number}}
        {:error, reason} -> {:error, {:escalation_incomplete, pr_number, reason}}
      end
    end
  end

  @doc """
  Merge blocked and NOT auto-resolvable by the system (real git conflict, or unclassified failure) → the arch
  rules. `class` (`:conflict` | other) comes from `Fleet.Pilot.MergeOutcome`: the message states the REAL
  cause, never "after a rebase attempt" (the system does NOT rebase — forge-blind barrier,
  mechanical resolution = later increment). Deduplicated gatekeeper comment + `lcars-awaits-arch`
  lock on the ISSUE → the poller SKIPS it (out-of-dispatch, no more retry; the label IS the
  throttle). `reason` (forge detail of the failed merge) goes INTO the comment.

  Returns `{:skipped, {:merge_blocked_escalated, pr_number}}` when the throttle label took, or
  `{:error, {:escalation_incomplete, pr_number, reason}}` when it did NOT (C-02: honest tally,
  re-attempted next tick). Both forms are HANDLED by the poller (`step_process_pulls` folds
  `:skipped`/`:error`) → no crash. An `{:escalated, _}` would be in NO clause of the `case do_poll`
  → CaseClauseError: a dispatch return MUST be `{:ok|:skipped|:error}`, never a 4th form. Non-fleet
  head → `{:skipped, :not_fleet_branch}`.
  """
  @spec escalate_merge_blocked(Seams.t(), integer(), String.t(), atom(), term()) ::
          {:skipped, term()} | {:error, term()}
  def escalate_merge_blocked(%Seams{} = seams, pr_number, head, class, reason) do
    with {:ok, issue_n} <- issue_of_branch_or_skip(head) do
      signature = "[merge-blocked-escalation:pr-#{pr_number}]"

      body =
        "**Architecte** — ⚠ Merge bloqué sur la PR ##{pr_number} (issue ##{issue_n}) — " <>
          merge_blocked_cause(class, reason) <>
          " Le système n'y touche PAS (barrière forge-aveugle : le pod n'a pas de credentials pour " <>
          "rebaser). Reprends : résous/rebase la PR sur `main` (ou re-cadre). L'issue reste hors-dispatch " <>
          "tant que `lcars-awaits-arch` est posé.\n\n" <> signature

      case escalate_to_arch(seams, issue_n, signature, body) do
        :ok -> {:skipped, {:merge_blocked_escalated, pr_number}}
        {:error, reason} -> {:error, {:escalation_incomplete, pr_number, reason}}
      end
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

  # C3 — ET CETTE CLASSE N'EST PAS UN ÉCHEC DE MERGE, ce qui est la raison même d'avoir sa clause :
  # tombée dans le fourre-tout `_unknown`, une zone grise se serait annoncée à l'architecte comme un
  # « échec de merge non classifié », et il aurait cherché un conflit git qui n'existe pas. Ici rien
  # n'a échoué : le jury a approuvé, et la carte refuse sur les mesures de ces mêmes juges. Ce qui
  # manque est un ARBITRAGE, et le sous-motif dit lequel des trois chemins y a mené.
  defp merge_blocked_cause(:verdict_gray_zone, reason),
    do:
      "zone grise du verdict — le jury a approuvé, la courbe de tolérance de la carte refuse sur " <>
        "les findings rendus par ces mêmes juges, et #{gray_zone_detail(reason)} Aucun conflit " <>
        "git, aucun refus de juge : c'est un arbitrage qui manque, et il te revient."

  defp merge_blocked_cause(_unknown, reason),
    do:
      "échec de merge non classifié par le système (`#{inspect(reason)}`) → à trancher manuellement."

  defp gray_zone_detail(:verdict_pass_disabled),
    do: "la passe d'arbitrage du gatekeeper n'est PAS armée sur cette boîte."

  defp gray_zone_detail(:verdict_pass_spent),
    do: "la passe d'arbitrage unique du gatekeeper a déjà été dépensée sans convergence."

  defp gray_zone_detail({:verdict_pass_undispatchable, why}),
    do: "la passe d'arbitrage n'a pas pu être convoquée (`#{inspect(why)}`)."

  defp gray_zone_detail(other), do: "l'arbitrage n'a pas abouti (`#{inspect(other)}`)."

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

    # `lcars-awaits-arch` IS the throttle (`decide/1` / `dispatch_review` skip on it). A failed label →
    # the PR is re-dispatched every tick (the exact churn this escalation exists to STOP). We SURFACE it
    # (C-02): return `{:error, ...}` so the caller reports an error tally,
    # NOT a lying `{:skipped, _escalated}` (the escalation did NOT durably take). The poller folds this as
    # `tally.errors` (`step_process_pulls`, F-037: telemetry only, never a backoff) and re-attempts next
    # tick (idempotent: dedup comment + idempotent add_label). LOG LOUD stays — the operator sees the churn.
    case seams.forge.add_label(seams.repo, issue_n, @awaits_arch_label, seams.forge_opts) do
      {:error, reason} ->
        Logger.error(
          "ArchEscalation: issue ##{issue_n} escalated but throttle label #{inspect(@awaits_arch_label)} " <>
            "NOT added (#{inspect(reason)}) — the PR will re-dispatch (churn) until the label sticks"
        )

        # The throttle did NOT take → we KEEP `lcars-in-flight` (do NOT remove it here): removing it now
        # would leave the object with NEITHER lock → a pod could grab it AND the poller would re-dispatch
        # (worse than the churn). in-flight holds the object until a later tick re-adds awaits-arch.
        {:error, {:awaits_arch_label_failed, reason}}

      _ ->
        # INVARIANT (live 2026-07-19, fleet/hello#3): awaits-arch ⇒ NO `lcars-in-flight` on the issue —
        # "parked, nobody works" and "someone works" are contradictory, and a stale in-flight also shields
        # the brick's pods from the quiesced-pod reap for the whole (human-timescale) park. The throttle
        # took, so we now maintain the invariant: remove in-flight. VERIFIED, no more silent `_ =` (CI-04:
        # the audit flagged "removes in-flight without verifying that removal" while the comment ASSERTS
        # invariant). Same standard as `StepRunCompleter.await_arch` (which verifies its remove in the
        # `with`). `remove_label` is idempotent (`{:ok, :already_absent}`); on failure we SURFACE — both
        # labels present contradicts the invariant AND the stale in-flight leaks the reap-shield — so the
        # poller re-attempts next tick (idempotent add+remove), same honest tally as the throttle failure.
        case seams.forge.remove_label(seams.repo, issue_n, @in_flight_label, seams.forge_opts) do
          {:error, reason} ->
            Logger.error(
              "ArchEscalation: issue ##{issue_n} awaits-arch SET but #{inspect(@in_flight_label)} NOT removed " <>
                "(#{inspect(reason)}) — invariant awaits-arch⇒¬in-flight violated (both labels present, stale " <>
                "in-flight shields pods from reap); poller re-attempts next tick (idempotent)"
            )

            {:error, {:in_flight_removal_failed, reason}}

          _ ->
            :ok
        end
    end
  end

  # Extracts the parent ISSUE number from the feature-branch (`lcars/issue-<n>-<role>`) via the
  # UNIQUE parser `Fleet.Forge.Protocol.parse_feature_branch/1` (not a homemade re-parse). Local
  # adapter `{:ok, issue_n} | {:skipped, :not_fleet_branch}` — the producer does not interest
  # the escalation (it writes on the issue), hence a narrower return than
  # `RoleDispatch.parse_feature_branch_or_skip` (which returns the full `{n, role}` tuple for the review dispatch).
  defp issue_of_branch_or_skip(head) do
    case Fleet.Forge.Protocol.parse_feature_branch(head) do
      {:ok, {issue_n, _producer}} -> {:ok, issue_n}
      :error -> {:skipped, :not_fleet_branch}
    end
  end
end
