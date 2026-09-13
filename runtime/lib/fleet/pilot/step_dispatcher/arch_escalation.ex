defmodule Fleet.Pilot.StepDispatcher.ArchEscalation do
  @moduledoc """
  Writes PR-side escalations selected by review, publish and merge policy callers.
  Posts an explanatory decision-role comment, adds awaits-arch on the parent issue,
  then removes its in-flight label. Comment failures are logged; returned label errors
  become :escalation_incomplete. Unexpected exceptions can interrupt this sequence.

  Missing role credentials skip the comment without using system identity in its place;
  labels still use the supplied forge options. There is no separate comment-repair job.
  Once awaits-arch is visible to the poller, it suppresses this PR path, including a
  possible retry after in-flight removal failed. An error return alone schedules no retry.

  Keep this separate from StepRunCompleter.await_arch: that issue-side comment is the
  judge's verdict record, whereas this decision-role comment is explanatory. Both paths
  must report label failures. Fleet.Pilot documents the escalation layers.
  """

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
            forge: module(),
            repo: String.t(),
            # Transport options; decision-role signing and dedup options are added for the comment.
            forge_opts: keyword()
          }
  end

  @doc """
  Escalates exhausted or unreadable rework budget supplied by the caller.
  Detail appears in the comment, not the dedup marker. Returns a rework-exhausted
  skip after successful label operations, :escalation_incomplete on returned label
  errors, or :not_fleet_branch when the parent issue cannot be parsed.
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
  Escalates repeated publish failures with a separate marker from exhausted review
  rounds: failed publication creates no new judge verdict and cannot advance that budget.
  Uses the same comment and label sequence as the other escalations.
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
  Escalates the supplied merge, CI, provenance or arbitration cause on the parent issue.
  Reason text must preserve the caller's diagnosis without inventing a resolution attempt.
  Returns a merge-blocked skip after successful label operations, an incomplete-escalation
  error on returned label failures, or :not_fleet_branch. Keep these standard dispatch
  result shapes: the poller has no separate :escalated result branch.
  """
  @spec escalate_merge_blocked(Seams.t(), integer(), String.t(), atom() | tuple(), term()) ::
          {:skipped, term()} | {:error, term()}
  def escalate_merge_blocked(%Seams{} = seams, pr_number, head, class, reason) do
    with {:ok, issue_n} <- issue_of_branch_or_skip(head) do
      signature = "[merge-blocked-escalation:pr-#{pr_number}]"

      # Match the suggested action to the cause; CI and provenance failures need no rebase.
      body =
        "**Architecte** — ⚠ Merge bloqué sur la PR ##{pr_number} (issue ##{issue_n}) — " <>
          merge_blocked_cause(class, reason) <>
          merge_blocked_gesture(class) <>
          " L'issue reste hors-dispatch tant que `lcars-awaits-arch` est posé.\n\n" <> signature

      case escalate_to_arch(seams, issue_n, signature, body) do
        :ok -> {:skipped, {:merge_blocked_escalated, pr_number}}
        {:error, reason} -> {:error, {:escalation_incomplete, pr_number, reason}}
      end
    end
  end

  # Preserve conflict budget/marker failures and distinguish an unavailable exception pass
  # from one that ran without convergence.
  defp merge_blocked_cause(:conflict, {:conflict_rework_exhausted, rounds, detail}),
    do:
      "conflit git, et le producteur a dépensé ses #{rounds} passe(s) de rework-conflit sans " <>
        "converger ; passe chief : `#{inspect(detail)}` → résolution manuelle requise."

  defp merge_blocked_cause(:conflict, {:conflict_budget_unreadable, why}),
    do:
      "conflit git, et le budget de rework-conflit est ILLISIBLE sur la forge " <>
        "(`#{inspect(why)}`) → le rail ne peut pas borner une passe de plus, résolution manuelle."

  defp merge_blocked_cause(:conflict, {marker, why})
       when marker in [:conflict_marker_unpostable, :conflict_exception_marker_unpostable],
       do:
         "conflit git, et le marqueur qui borne la passe n'a pas pu être posté " <>
           "(`#{inspect(why)}`) — une passe non enregistrée n'est pas bornée, donc pas jouée : " <>
           "résolution manuelle."

  defp merge_blocked_cause(:conflict, _reason),
    do:
      "conflit git (les deux côtés touchent les mêmes lignes) → le merge automatique est impossible, résolution manuelle requise."

  # A forge read that failed is a NAMED cause, not « non classifié ».
  defp merge_blocked_cause(:rerequest_read_failed, why),
    do:
      "la liste des juges re-demandés est ILLISIBLE sur la forge (`#{inspect(why)}`) → le rail " <>
        "ne sait pas qui re-convoquer. Relis la PR et re-demande la review toi-même."

  defp merge_blocked_cause(:policy, _reason),
    do:
      "blocage de branch-protection non levable mécaniquement (commits signés requis, ou une approbation manquante hors re-request) → à débloquer manuellement."

  # A favorable jury with policy-rejected findings needs arbitration, not an invented Git conflict.
  defp merge_blocked_cause(:verdict_gray_zone, reason),
    do:
      "zone grise du verdict — le jury a rendu un AVIS FAVORABLE, la courbe de tolérance de la " <>
        "carte refuse sur " <>
        "les findings rendus par ces mêmes juges, et #{gray_zone_detail(reason)} Aucun conflit " <>
        "git, aucun refus de juge : c'est un arbitrage qui manque, et il te revient."

  # Pending CI is an infrastructure diagnosis, not a failed merge or disputed verdict.
  defp merge_blocked_cause(:ci_stalled, reason),
    do:
      "la CI est PENDANTE au-delà de la borne (#{reason}) → aucun verdict ne viendra tant qu'un " <>
        "runner ne sert pas ce label. Rien à rebaser, rien à arbitrer : vérifie le runner et ses " <>
        "labels, ou le `runs-on:` du workflow."

  # The gate's own classes (`CiGate.decide/4` → `Remediation.ci_stalled/5`), each with its gesture.
  # `message` is the gate's sentence, already naming the label, the delay or the missing workflow.
  defp merge_blocked_cause({:ci_stalled, :unclaimed}, message),
    do:
      "la CI est BLOQUÉE — #{message} Aucun verdict ne viendra tant qu'un runner ne sert pas " <>
        "ce label. Rien à rebaser, rien à arbitrer : vérifie le runner et ses labels, ou le " <>
        "`runs-on:` du workflow."

  defp merge_blocked_cause({:ci_stalled, _state}, message),
    do: merge_blocked_cause(:ci_stalled, message)

  defp merge_blocked_cause({:ci_impossible, :no_workflow}, message),
    do:
      "la CI est IMPOSSIBLE sur cette PR — #{message} Aucun workflow ne peut rendre de verdict : " <>
        "ajoute ou répare le rail CI du projet (`project_reset_ci_rail`). Rien à rebaser."

  defp merge_blocked_cause(:ci_red_loop, message),
    do:
      "la CI est ROUGE sur deux têtes successives — #{message} Le producteur n'arrive pas à la " <>
        "remettre au vert : reprends le rail ou re-cadre le ticket. Rien à rebaser."

  # Provenance refusal requires intervention rather than repeating the same failed seal.
  defp merge_blocked_cause(:provenance_incoherent, reason),
    do:
      "la PROVENANCE de la brique est INCOHÉRENTE (`#{inspect(reason)}`) → le mur déterministe " <>
        "refuse le merge tant que l'attestation ment sur la brique. Aucun conflit git : relis le " <>
        "statement `refs/lcars/provenance/<sha>` et la base du livrable, puis re-cadre ou fais " <>
        "re-livrer."

  defp merge_blocked_cause(_unknown, reason),
    do:
      "échec de merge non classifié par le système (`#{inspect(reason)}`) → à trancher manuellement."

  # Only conflict and protection causes receive their specific Git/protection instruction.
  defp merge_blocked_gesture(:conflict),
    do:
      " Le système n'y touche PAS (barrière forge-aveugle : le pod n'a pas de credentials pour " <>
        "rebaser). Reprends : résous/rebase la PR sur `main` (ou re-cadre)."

  defp merge_blocked_gesture(:policy),
    do:
      " Le système n'y touche PAS (barrière forge-aveugle : le pod n'a pas de credentials pour " <>
        "rebaser). Reprends : lève le blocage de protection ou re-demande la review."

  defp merge_blocked_gesture(_other), do: " Le système n'y touche PAS."

  defp gray_zone_detail(:verdict_pass_disabled),
    do: "la passe d'arbitrage du gatekeeper n'est PAS armée sur ce conteneur."

  defp gray_zone_detail(:verdict_pass_spent),
    do: "la passe d'arbitrage unique du gatekeeper a déjà été dépensée sans convergence."

  defp gray_zone_detail({:verdict_pass_undispatchable, why}),
    do: "la passe d'arbitrage n'a pas pu être convoquée (`#{inspect(why)}`)."

  defp gray_zone_detail(other), do: "l'arbitrage n'a pas abouti (`#{inspect(other)}`)."

  # The explanatory comment is best-effort; returned label errors determine the escalation result.
  defp escalate_to_arch(%Seams{} = seams, issue_n, signature, body) do
    # Decision role signs the escalation; the exception role signs its own resolution work.
    # Missing credentials skip the comment, never substitute system authorship.
    # A posted throttle can prevent this path from retrying a failed or skipped comment.
    case Fleet.Forge.Client.as_role(
           seams.forge_opts,
           Fleet.Project.Roles.gatekeeper_role()
         ) do
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

    # Adding awaits-arch throttles dispatch once the poller sees it. A returned error
    # surfaces in the tally; this function itself schedules no retry.
    case seams.forge.add_label(seams.repo, issue_n, @awaits_arch_label, seams.forge_opts) do
      {:error, reason} ->
        Logger.error(
          "ArchEscalation: issue ##{issue_n} escalated but throttle label #{inspect(@awaits_arch_label)} " <>
            "NOT added (#{inspect(reason)}) — the PR will re-dispatch (churn) until the label sticks"
        )

        # Leave in-flight intact if awaits-arch was not confirmed; do not remove both guards.
        {:error, {:awaits_arch_label_failed, reason}}

      _ ->
        # After awaits-arch, remove stale in-flight. Failure leaves contradictory labels
        # and returns an error, but the new throttle can prevent retry through this PR path.
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

  # Use the shared feature-branch parser; escalation needs only the parent issue number.
  defp issue_of_branch_or_skip(head) do
    case Fleet.Forge.Protocol.parse_feature_branch(head) do
      {:ok, {issue_n, _producer}} -> {:ok, issue_n}
      :error -> {:skipped, :not_fleet_branch}
    end
  end
end
