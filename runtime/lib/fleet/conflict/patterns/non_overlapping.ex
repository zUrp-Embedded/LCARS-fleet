defmodule Fleet.Conflict.Patterns.NonOverlapping do
  @moduledoc """
  Both branches changed DIFFERENT regions of the same block -> automatic 3-way LCS merge. diff3 only.
  `detect?/1` runs the actual merge (detection IS the resolution attempted): it matches iff the merge
  succeeds without overlap.
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
  The merge itself -- this pattern's detection and its resolution are the SAME computation.

  Public so the classifier can keep the result instead of asking for it a second time: the
  behaviour's `detect?/1` can only answer a boolean, and the answer here costs two quadratic LCS
  tables. `{:error, :too_large}` is the LCS budget declining, not a statement about the content.
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
  # The trace must not say "both branches touched the same lines" about a block the engine never
  # compared: over the LCS budget, nothing was measured, and a refusal that invents its own motive
  # is worse than a refusal.
  @impl true
  def fail_reason(h) do
    # O(1) on the lengths, NEVER `merge/1`: the trace calls this for every pattern it rejected, so
    # deriving the sentence from the merge would run the subsystem's costliest computation a third
    # time -- to write prose about a hunk this pattern did not win.
    if Diff.over_lcs_budget?(h.base_lines, h.ours_lines) or
         Diff.over_lcs_budget?(h.base_lines, h.theirs_lines) do
      "Block too large for the 3-way LCS budget (#{Diff.max_lcs_cells()} cells) -- not compared."
    else
      "3-way LCS merge detects an overlap -- both branches touched the same lines."
    end
  end
end
