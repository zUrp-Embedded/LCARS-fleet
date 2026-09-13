defmodule Fleet.Conflict.Pattern do
  @moduledoc """
  Classification callbacks for modules registered in Fleet.Conflict.Classifier.
  Ascending priority, filtered by requires (:diff3 means non-empty base), first match wins.
  pass_reason/fail_reason feed the trace through the winner; refusal explanations should
  not repeat expensive detection. NonOverlapping carries a cached merge via a classifier special case.
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
