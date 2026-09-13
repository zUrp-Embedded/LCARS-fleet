defmodule Fleet.Conflict.Patterns.WhitespaceOnly do
  @moduledoc """
  Equal normalized sides plus equal quote-scanner contents. The scanner approximates strings;
  it is not a language lexer. Base presence changes the score without comparing base content.
  Conflict never auto-writes this type because whitespace can carry language semantics.
  """
  @behaviour Fleet.Conflict.Pattern
  alias Fleet.Conflict.Patterns.Utils
  alias Fleet.Conflict.Score

  @impl true
  def type, do: :whitespace_only
  @impl true
  def priority, do: 50
  @impl true
  def requires, do: :both

  @impl true
  def detect?(h) do
    Utils.normalize_for_whitespace_check(h.ours_lines) ==
      Utils.normalize_for_whitespace_check(h.theirs_lines) and
      Utils.extract_quoted_segments(h.ours_lines) == Utils.extract_quoted_segments(h.theirs_lines)
  end

  @impl true
  def confidence(h) do
    lines = max(length(h.ours_lines), length(h.theirs_lines))

    if h.base_lines != [] do
      Score.make(95, 10, Score.scope_impact(lines),
        boosters: [
          "Base available -- whitespace confirmed against ancestor",
          "Only whitespace differs after normalization"
        ]
      )
    else
      Score.make(80, 10, Score.scope_impact(lines),
        boosters: ["Only whitespace differs after normalization (trim)"],
        penalties: ["No base (diff2) -- normalization-only hypothesis"]
      )
    end
  end

  @impl true
  def explanation(_h), do: "Both branches carry the same code with whitespace differences only."
  @impl true
  def pass_reason(_h),
    do: "After normalization the two versions are identical -- only whitespace differs."

  @impl true
  def fail_reason(_h), do: "After normalization the versions still differ -- not whitespace only."
end
