defmodule Fleet.Conflict.Patterns.NonOverlapping do
  @moduledoc """
  Eligible with a non-empty base. Detection performs the merge and matches when cross-side
  edit intervals do not overlap within the LCS budget; this is a textual, not semantic check.
  """
  @behaviour Fleet.Conflict.Pattern
  alias Fleet.Conflict.{Diff, Score}

  @impl true
  def type, do: :non_overlapping
  @impl true
  def priority, do: 40
  @impl true
  def requires, do: :diff3

  @doc """
  Returns the merge payload for classifier caching, avoiding a second pair of LCS tables
  in Assemble. {:error, :too_large} is a budget refusal, not evidence of overlapping edits.
  """
  @spec merge(Fleet.Conflict.Parser.raw_conflict() | Fleet.Conflict.Hunk.t()) ::
          {:ok, [String.t()]} | {:error, :overlap | :too_large}
  def merge(h), do: Diff.merge_non_overlapping(h.base_lines, h.ours_lines, h.theirs_lines)

  @impl true
  def detect?(h), do: match?({:ok, _}, merge(h))

  @impl true
  def confidence(h) do
    merged_size = max(length(h.ours_lines), length(h.theirs_lines))

    Score.make(90, 20, Score.scope_impact(merged_size),
      boosters: ["Base available", "3-way LCS merge succeeded without overlap"]
    )
  end

  @impl true
  def explanation(_h),
    do: "Both branches changed different regions of the block -- automatic merge."

  @impl true
  def pass_reason(_h), do: "3-way LCS merge succeeded -- the changes do not overlap."
  @impl true
  def fail_reason(h) do
    # Name budget refusal without rerunning the merge; the check only traverses the lists.
    if Diff.over_lcs_budget?(h.base_lines, h.ours_lines) or
         Diff.over_lcs_budget?(h.base_lines, h.theirs_lines) do
      "Block too large for the 3-way LCS budget (#{Diff.max_lcs_cells()} cells) -- not compared."
    else
      "3-way LCS merge detects an overlap -- both branches touched the same lines."
    end
  end
end
