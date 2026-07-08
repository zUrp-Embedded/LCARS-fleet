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
  Parses a step issue_id `"issue-<n>"` → `{:ok, n}`; otherwise `:error`. STRICT inverse of
  `compose/1`: the suffix must be a complete integer (`"issue-7x"` / `"issue-"` → `:error`).
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
