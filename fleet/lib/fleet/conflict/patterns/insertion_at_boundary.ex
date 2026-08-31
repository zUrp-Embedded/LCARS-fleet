defmodule Fleet.Conflict.Patterns.InsertionAtBoundary do
  @moduledoc """
  Both branches ONLY added lines relative to base (no removals), at the same boundary where a plain
  LCS 3-way merge fails. Complements `non_overlapping` (priority 40, checked first): this is the case
  where the insertions land at the same point. diff3 = high confidence; diff2 = a subset heuristic.
  """
  @behaviour Fleet.Conflict.Pattern
  alias Fleet.Conflict.{Diff, Score}
  alias Fleet.Conflict.Patterns.Utils

  @impl true
  def type, do: :insertion_at_boundary
  @impl true
  def priority, do: 57
  @impl true
  def requires, do: :both

  @impl true
  @spec detect?(map()) :: boolean()
  def detect?(%{base_lines: []} = h), do: detect_without_base(h)

  def detect?(h) do
    # This pattern reaches `Diff.lcs/2` DIRECTLY, so it carries the budget refusal itself -- a
    # ceiling placed in the three-way merge alone would leave THIS path unbounded beside a bounded
    # neighbour.
    with {:ok, ours_removals} <- lcs_removals(h.base_lines, h.ours_lines),
         {:ok, theirs_removals} <- lcs_removals(h.base_lines, h.theirs_lines),
         {:ok, ours_added} <- lcs_additions(h.base_lines, h.ours_lines),
         {:ok, theirs_added} <- lcs_additions(h.base_lines, h.theirs_lines) do
      ours_removals == [] and theirs_removals == [] and ours_added != [] and theirs_added != [] and
        not overlap?(ours_added, theirs_added)
    else
      {:error, :too_large} -> false
    end
  end

  @impl true
  def confidence(h) do
    total = max(length(h.ours_lines), length(h.theirs_lines))

    if h.base_lines != [] do
      Score.make(90, 8, Score.scope_impact(total),
        boosters: ["Pure insertions -- base intact on both sides"]
      )
    else
      Score.make(68, 20, Score.scope_impact(total),
        penalties: ["No base (diff2) -- union heuristic (-22)"]
      )
    end
  end

  @impl true
  def explanation(_h),
    do: "Both branches only added lines without touching the base. Resolution: union."

  @impl true
  def pass_reason(_h), do: "No removals on either side, disjoint insertions -- pure insertions."
  @impl true
  def fail_reason(_h), do: "At least one side has removals or overlapping insertions."

  # diff2: one side is a strict subset of the other (different sizes) -- a pure addition.
  defp detect_without_base(h) do
    ours = normalized_set(h.ours_lines)
    theirs = normalized_set(h.theirs_lines)

    cond do
      MapSet.size(ours) == 0 or MapSet.size(theirs) == 0 -> false
      MapSet.equal?(ours, theirs) -> false
      MapSet.size(ours) == MapSet.size(theirs) -> false
      MapSet.size(ours) < MapSet.size(theirs) -> MapSet.subset?(ours, theirs)
      true -> MapSet.subset?(theirs, ours)
    end
  end

  defp normalized_set(lines),
    do: lines |> Enum.map(&Utils.normalize_line/1) |> Enum.reject(&(&1 == "")) |> MapSet.new()

  # Lines of `modified` NOT in the LCS with `base` -> additions.
  defp lcs_additions(base, modified), do: outside_lcs(Diff.lcs(modified, base), modified)

  # Lines of `base` no longer in `modified` -> removals.
  defp lcs_removals(base, modified), do: outside_lcs(Diff.lcs(base, modified), base)

  defp outside_lcs({:error, :too_large} = err, _lines), do: err

  defp outside_lcs({:ok, pairs}, lines) do
    in_lcs = pairs |> Enum.map(fn {i, _j} -> i end) |> MapSet.new()

    lines
    |> Enum.with_index()
    |> Enum.reject(fn {_l, i} -> MapSet.member?(in_lcs, i) end)
    |> Enum.map(&elem(&1, 0))
    |> then(&{:ok, &1})
  end

  defp overlap?(a, b) do
    set = MapSet.new(a)
    Enum.any?(b, &MapSet.member?(set, &1))
  end
end
