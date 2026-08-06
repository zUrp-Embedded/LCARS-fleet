defmodule Fleet.Pilot.IssueId do
  @moduledoc """
  SINGLE source of the step-mode `issue_id` format `"issue-<n>"`.

  `compose/1` and `parse/1` live here → the writer (`Fleet.Pilot.StepDispatcher`) and the parser
  (`Fleet.Pilot.StepRunConsumer.parse_issue_number`, which delegates) cannot drift apart from
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
  Parses a step issue_id `"issue-<n>"` → `{:ok, n}`; otherwise `:error`. The STRICT inverse of
  `compose/1`: it accepts ONLY the canonical spelling `compose` emits (`Integer.to_string(n)`), so
  `"issue-007"` and `"issue-+7"` are `:error` — `Integer.parse/1` alone tolerates leading zeros and an
  explicit sign, but `compose(7)` only ever yields `"issue-7"`. One issue ⇒ exactly one issue_id
  spelling, safe even if an issue_id from OUTSIDE ever becomes a KEY (dedup/mutex/lookup) — no two
  spellings for one issue. The suffix must be a COMPLETE canonical integer (`"issue-7x"` / `"issue-"` /
  `"issue-x"` → `:error`).

  Round-trip both ways (locked by property): `parse(compose(n)) == {:ok, n}` (negatives included) and,
  for every accepted string, `compose(n) ==` that string.
  '''
  @spec parse(String.t()) :: {:ok, integer()} | :error
  def parse(@prefix <> rest) do
    case Integer.parse(rest) do
      # STRICT: accept only the canonical spelling — `Integer.to_string(n)` is exactly what compose/1
      # wrote, so a non-canonical `rest` ("007", "+7") that would parse to the SAME n is refused.
      {n, ""} -> if Integer.to_string(n) == rest, do: {:ok, n}, else: :error
      _ -> :error
    end
  end

  def parse(_), do: :error
end
