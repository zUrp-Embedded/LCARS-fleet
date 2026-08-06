defmodule Fleet.Conflict.ConfidenceScore do
  @moduledoc """
  Composite confidence for one automatic resolution: a multi-dimensional score, not a flat label.

  The score and its label are derived in ONE place (`Fleet.Conflict.Score`). The engine this was
  ported from carried THREE divergent copies of the formula; a hunk silently lost a penalty the
  first time a secondary path re-scored it. Callers pass dimensions, never a pre-rolled score.

  **Last revised**: 2026-07-30
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
  Structured trace of a hunk classification. Every evaluated pattern is recorded -- the REFUSAL is
  documented as much as the acceptance. This trace is the durable audit artifact (doctrine D1: the
  trace precedes the routing action), never a debug afterthought.

  **Last revised**: 2026-07-30
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
  One classified conflict block: the three sides, the detected type, the composite confidence, and
  the decision trace. Pure data -- produced by the classifier, consumed by the assembler and by the
  router upstream (`Fleet.Pilot.StepDispatcher.ReviewLifecycle.Remediation`).

  **Last revised**: 2026-07-30
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
    zdiff3: false
  ]
end

defmodule Fleet.Conflict.Report do
  @moduledoc """
  Result of classifying (and, where trivially resolvable, resolving) one conflict-marked file.

  `merged` is non-nil ONLY when every hunk was auto-resolved above the confidence threshold -- the
  contract for "the runtime may write this back". Any residual (a `:complex` hunk, or a resolvable
  hunk below threshold) leaves `merged: nil` and the caller routes to the producer / gatekeeper.

  **Last revised**: 2026-07-30
  """
  alias Fleet.Conflict.Hunk

  @type stats :: %{
          trivial: non_neg_integer(),
          complex: non_neg_integer(),
          total: non_neg_integer()
        }
  @type t :: %__MODULE__{merged: String.t() | nil, hunks: [Hunk.t()], stats: stats()}
  @enforce_keys [:hunks, :stats]
  defstruct merged: nil, hunks: [], stats: %{trivial: 0, complex: 0, total: 0}
end
