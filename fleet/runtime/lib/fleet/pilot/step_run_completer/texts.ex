defmodule Fleet.Pilot.StepRunCompleter.Texts do
  @moduledoc """
  DEFAULT texts of the step-run-completion (PR body, review body, signed comment),
  extracted from `Fleet.Pilot.StepRunCompleter`: the WORDING authority when the caller does not
  supply one (`:pr_body` / `:review_body` / `:comment_body` always take precedence).

  PURE generators (inputs → markdown binary), zero I/O, zero seam: the system's honest trace
  ("WHO did WHAT") is read directly on the forge. The completer keeps the
  SEQUENCE (write order, idempotence); here lives only the textual material.

  NO MORE `Closes #N` (removed 2026-07-07, chronology QoL): Gitea auto-closes the issue AT THE MOMENT
  OF MERGE, before the system could post its seal comment ("✅ livrée et fusionnée" on an
  already-closed ticket — incoherent chronology, comment posted after the fact on a closed one). The close is
  now EXPLICIT, set by `GatekeeperSeal.seal_and_merge` AFTER the comment (last act
  visible on the issue) — see its doc for the full sequence.

  **Last revised**: 2026-07-18
  """

  @doc """
  Default PR body — descriptive (honest trace: WHO did WHAT). `has_note?` (default `false`)
  adds the POINTER to the producer's note (posted separately by `Emissions.post_eng_summary` on
  the ISSUE — the FULL note lives ONCE, over there; this body carries only the link, not the blob):
  folded INTO the opening body rather than a 2nd separate comment posted right after — a single "as
  engineer" post instead of two (QoL, uncovered by reading the real forge rendering of a delivered PR).
  """
  @spec pr_body(integer(), String.t(), boolean()) :: String.t()
  def pr_body(n, role, has_note? \\ false) do
    base =
      "Livrable de la brique ##{n}, produit par **#{role}**. Le système a poussé le commit " <>
        "(le producteur code dans son workspace, le système publie — barrière forge-aveugle, le pod n'a pas de " <>
        "token forge). Reviews demandées aux juges ; merge à l'approbation."

    if has_note?,
      do: base <> "\n\n🔧 Note de l'#{role} (livrable) → détail sur le ticket ##{n}.",
      else: base
  end

  @doc """
  Default review body — descriptive (judge role + verdict + what is judged,
  readable directly on the PR). Any non-decisive event → "pending" wording.
  """
  @spec review_body(String.t(), :approve | :request_changes | atom()) :: String.t()
  def review_body(role, event) do
    case event do
      :approve ->
        "Verdict du juge **#{role}** : **APPROUVÉ** — la brique satisfait son critère de revue."

      :request_changes ->
        "Verdict du juge **#{role}** : **CHANGEMENTS DEMANDÉS** — la brique ne satisfait pas " <>
          "son critère ; le producteur doit corriger et re-pousser sur la même PR."

      _ ->
        "Commentaire du juge **#{role}** : verdict non concluant (en attente)."
    end
  end

  @doc """
  Default body of the signed `[step_run:role:sha]` comment of the in-house sequence
  (the machine signature is appended by the completer, not here).
  """
  @spec step_run_comment(String.t(), String.t()) :: String.t()
  def step_run_comment(role, sha) do
    "Livrable de **#{role}** poussé par le système (fin-de-step-run). Source: `#{sha}`."
  end
end
