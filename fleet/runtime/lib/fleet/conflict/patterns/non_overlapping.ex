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

  @impl true
  def detect?(h),
    do: Diff.merge_non_overlapping(h.base_lines, h.ours_lines, h.theirs_lines) != nil

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
  def fail_reason(_h),
    do: "3-way LCS merge detects an overlap -- both branches touched the same lines."
end
