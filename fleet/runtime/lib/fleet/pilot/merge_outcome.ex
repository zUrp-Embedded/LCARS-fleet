defmodule Fleet.Pilot.MergeOutcome do
  @moduledoc """
  STRUCTURAL classification of a merge failure — pure, from the forge's PR object (never from the
  error message). A merge can fail for NATURALLY DISTINCT reasons that the code until now handled
  in a catch-all "conflict" (→ dispatch the eng to rebase, IMPOSSIBLE because forge-blind,
  → wall observed live 2026-07-07 on a mere policy window). We re-read the source of truth (the
  PR's `state`/`merged`/`draft`/`mergeable` fields) and decide the REAL class.

  Why structural and not by message: the Gitea error labels ("Does not have enough
  approvals", "Work in progress PRs cannot be merged", "Please try again later") are
  version-specific and fragile; the PR object's fields are the fact carried by the forge itself.
  Verified on forge (2026-07-07): policy → `mergeable: true`; real git conflict → `mergeable: false` +
  `draft: false`; draft → `draft: true` (+ `mergeable: false`, hence the test ORDER: draft BEFORE
  mergeable). This is the application of "make the false state unconstructible / read the single source" to the
  merge DECISION: the class is a TOTAL function of the fields, not a string heuristic.

  Classes (closed sum):
    * `:merged`   — already merged (multi-actor race / replay) → idempotent no-op.
    * `:closed`   — PR closed WITHOUT merge (human cancellation) → the brick is dead, don't persist.
    * `:draft`    — PR reverted to draft (parked by a human) → wait, NOT a conflict.
    * `:conflict` — real git conflict (`mergeable: false`, not draft) → resolution required.
    * `:policy`   — git mergeable (`mergeable: true`) but the forge refuses: branch-protection
                    (approvals removed by a re-request, CI required…) → re-converge, NOT a conflict.
    * `:unknown`  — `mergeable` indeterminate (null, forge computation in progress) → invent nothing, escalate honestly.
  """

  @type class :: :merged | :closed | :draft | :conflict | :policy | :unknown

  @doc """
  Classifies a PR (raw Gitea map, as returned by `ForgeClient.get_pull/3`) by the REAL cause
  of a merge failure. TOTAL and PURE function (no I/O): the caller re-reads the fresh PR then passes
  the object. LOAD-BEARING guard order: `merged`/`closed` first (the terminal state takes precedence),
  `draft` BEFORE `mergeable` (a draft also carries `mergeable: false` — without this order a draft would be
  falsely classified as a conflict, exactly the wall this module exists to kill).
  """
  @spec classify(map()) :: class()
  def classify(pull) when is_map(pull) do
    cond do
      Map.get(pull, "merged") == true -> :merged
      Map.get(pull, "state") == "closed" -> :closed
      Map.get(pull, "draft") == true -> :draft
      Map.get(pull, "mergeable") == false -> :conflict
      Map.get(pull, "mergeable") == true -> :policy
      true -> :unknown
    end
  end
end
