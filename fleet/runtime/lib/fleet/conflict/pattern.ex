defmodule Fleet.Conflict.Pattern do
  @moduledoc """
  Contract of a classification pattern (the registry plugin).

  The classifier evaluates patterns in `priority` order (lowest first), filtered by `requires`
  (does the hunk carry a diff3 base?), and takes the first `detect?/1` that matches. Adding a
  pattern = one module implementing this behaviour + one line in `Fleet.Conflict.Classifier`'s
  registry.

  The refusal path is part of the contract: `fail_reason/1` feeds the decision trace so a pattern
  that did NOT match is documented as clearly as the one that did.

  **Last revised**: 2026-07-30
  """
  alias Fleet.Conflict.ConfidenceScore

  @type input :: %{
          ours_lines: [String.t()],
          base_lines: [String.t()],
          theirs_lines: [String.t()],
          start_line: pos_integer(),
          end_line: pos_integer()
        }

  @callback type() :: atom()
  @callback priority() :: non_neg_integer()
  @callback requires() :: :diff3 | :diff2 | :both
  @callback detect?(input()) :: boolean()
  @callback confidence(input()) :: ConfidenceScore.t()
  @callback explanation(input()) :: String.t()
  @callback pass_reason(input()) :: String.t()
  @callback fail_reason(input()) :: String.t()
end
