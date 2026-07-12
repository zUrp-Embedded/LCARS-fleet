defmodule Fleet.Pilot.IssueId do
  @moduledoc """
  SINGLE source of the step-mode `issue_id` format `"issue-<n>"`.

  `compose/1` and `parse/1` live here → the writer (`Fleet.Pilot.StepDispatcher`) and the parser
  (`Fleet.Pilot.StepRunConsumer.parse_issue_number`, which delegates) can no longer drift apart from
  each other. The `issue_id` correlates a pod to its forge issue throughout the step_run (enqueue → end-of-step-run).
  """

  @prefix "issue-"

  @doc ~S'''
  Composes the step issue_id from a forge issue number: `compose(42) => "issue-42"`.

  Tolerant: semantically `"issue-" <> to_string(number)` (direct interpolation), so any term
  is accepted; the expected `number` remains the integer `issue["number"]`.
  '''
  @spec compose(integer()) :: String.t()
  def compose(number), do: @prefix <> to_string(number)

  @doc ~S'''
  Parses a step issue_id `"issue-<n>"` → `{:ok, n}`; otherwise `:error`. The suffix must be a
  COMPLETE integer (`"issue-7x"` / `"issue-"` / `"issue-x"` → `:error`).

  `parse ∘ compose == id` (round-trip guaranteed, negatives included — locked by property).
  The converse does NOT hold: `Integer.parse/1` accepts leading zeros and an explicit sign, so
  `"issue-007"` and `"issue-+7"` both parse to `7` while `compose(7)` only ever yields `"issue-7"`.
  Several DISTINCT issue_ids therefore denote the same issue. Harmless while the issue_id is a
  correlator that is only ever READ (its writer is `compose/1`, single-source); it would NOT be
  harmless the day an issue_id coming from OUTSIDE becomes a KEY (dedup, mutex, lookup) — two
  spellings would then be two different keys for one issue. Stated here rather than silently
  tightened: the tolerance is the current, tested behaviour.
  '''
  @spec parse(String.t()) :: {:ok, integer()} | :error
  def parse(@prefix <> rest) do
    case Integer.parse(rest) do
      {n, ""} -> {:ok, n}
      _ -> :error
    end
  end

  def parse(_), do: :error
end
