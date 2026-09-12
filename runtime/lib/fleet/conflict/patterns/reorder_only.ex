defmodule Fleet.Conflict.Patterns.ReorderOnly do
  @moduledoc """
  Same multiset of normalized nonblank lines, different order; duplicates lower confidence.
  Normalization can also hide whitespace changes within quotes. Conflict excludes this type
  from writing; a direct Assemble call prefers theirs, or ours when theirs equals non-empty base.
  """
  @behaviour Fleet.Conflict.Pattern
  alias Fleet.Conflict.Patterns.Utils
  alias Fleet.Conflict.Score

  @impl true
  def type, do: :reorder_only
  @impl true
  def priority, do: 55
  @impl true
  def requires, do: :both

  @impl true
  def detect?(h) do
    ours = normalized(h.ours_lines)
    theirs = normalized(h.theirs_lines)

    ours != [] and theirs != [] and Enum.join(ours, "\n") != Enum.join(theirs, "\n") and
      multiset_equal?(ours, theirs)
  end

  @impl true
  def confidence(h) do
    ours = normalized(h.ours_lines)
    dups? = length(Enum.uniq(ours)) != length(ours)
    tc = if dups?, do: 82, else: 92
    penalties = if dups?, do: ["Duplicated lines -- ambiguous order (-10)"], else: []

    Score.make(tc, 5, Score.scope_impact(length(h.ours_lines)),
      boosters: ["Pure permutation -- same lines, different order"],
      penalties: penalties
    )
  end

  @impl true
  def explanation(_h), do: "Both branches carry the same lines in a different order."
  @impl true
  def pass_reason(_h),
    do: "The two sides are permutations of each other -- same lines, different order."

  @impl true
  def fail_reason(_h), do: "The lines are not a simple permutation -- there are adds or removals."

  defp normalized(lines),
    do: lines |> Enum.map(&Utils.normalize_line/1) |> Enum.reject(&(&1 == ""))

  defp multiset_equal?(a, b),
    do: length(a) == length(b) and Enum.frequencies(a) == Enum.frequencies(b)
end
