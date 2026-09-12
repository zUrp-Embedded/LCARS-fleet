defmodule Fleet.Conflict.ConfidenceScore do
  @moduledoc """
  Classification score and explanatory metadata, normally built by Fleet.Conflict.Score.
  Direct structs can supply inconsistent scores/labels; key enforcement does not validate them.
  """
  @type label :: :certain | :high | :medium | :low
  @type t :: %__MODULE__{
          score: non_neg_integer(),
          label: label(),
          dimensions: map(),
          boosters: [String.t()],
          penalties: [String.t()]
        }
  @enforce_keys [:score, :label]
  defstruct score: 0, label: :low, dimensions: %{}, boosters: [], penalties: []
end

defmodule Fleet.Conflict.DecisionTrace do
  @moduledoc """
  Classification trace through the winning pattern, including skipped and failed predecessors.
  Pure data for routing/audit consumers; persistence is their responsibility.
  """
  @type step :: %{type: atom(), passed: boolean(), reason: String.t()}
  @type t :: %__MODULE__{
          steps: [step()],
          selected: atom(),
          summary: String.t(),
          has_base: boolean()
        }
  @enforce_keys [:selected, :summary, :has_base]
  defstruct steps: [], selected: :complex, summary: "", has_base: false
end

defmodule Fleet.Conflict.Hunk do
  @moduledoc """
  Classified block for Assemble and Pilot conflict routing: sides, type, score and trace.
  Manually constructed fields are not validated; zdiff3 is a heuristic annotation.
  """
  alias Fleet.Conflict.{ConfidenceScore, DecisionTrace}

  @type t :: %__MODULE__{
          base_lines: [String.t()],
          ours_lines: [String.t()],
          theirs_lines: [String.t()],
          start_line: pos_integer(),
          type: atom(),
          confidence: ConfidenceScore.t(),
          explanation: String.t(),
          trace: DecisionTrace.t(),
          merged_lines: [String.t()] | nil,
          zdiff3: boolean()
        }
  @enforce_keys [
    :base_lines,
    :ours_lines,
    :theirs_lines,
    :start_line,
    :type,
    :confidence,
    :explanation,
    :trace
  ]
  defstruct [
    :base_lines,
    :ours_lines,
    :theirs_lines,
    :start_line,
    :type,
    :confidence,
    :explanation,
    :trace,
    # Classifier carries NonOverlapping's result to avoid two more LCS tables. Nil by default;
    # Assemble trusts a supplied list, including one from a manual struct.
    :merged_lines,
    zdiff3: false
  ]
end

defmodule Fleet.Conflict.Report do
  @moduledoc """
  Conflict.resolve/2 result: merged is a candidate only when at least one hunk exists and
  every hunk passes the writable-type gate, confidence floor and assembly. Any residual
  discards the whole candidate; a clean file also has merged: nil, with no hunks.
  This describes resolver output; manual structs do not enforce these relationships.
  """
  alias Fleet.Conflict.Hunk

  # writable counts allowed types regardless of confidence/assembly; trivial counts non-complex
  # diagnoses. Neither count alone authorizes writing: consumers must check merged.
  @type stats :: %{
          trivial: non_neg_integer(),
          complex: non_neg_integer(),
          total: non_neg_integer(),
          writable: non_neg_integer()
        }
  @type t :: %__MODULE__{merged: String.t() | nil, hunks: [Hunk.t()], stats: stats()}
  @enforce_keys [:hunks, :stats]
  defstruct merged: nil, hunks: [], stats: %{trivial: 0, complex: 0, total: 0, writable: 0}
end
