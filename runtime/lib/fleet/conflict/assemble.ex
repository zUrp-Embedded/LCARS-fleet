defmodule Fleet.Conflict.Assemble do
  @moduledoc """
  Builds lines from a classified Hunk, trusting its type and cached merged_lines.
  This module does not enforce Conflict's writable-type or confidence gates: direct calls
  can apply heuristic unions, whitespace/order preferences and default-to-theirs values.
  Unknown types and failed non-overlapping recomputation return :skip.
  """
  alias Fleet.Conflict.{Diff, Hunk}
  alias Fleet.Conflict.Patterns.Utils

  @doc """
  Returns {:ok, lines, reason} or :skip. A result alone is not write authorization;
  use Conflict.resolve/2 for the type and confidence gates.
  """
  @spec resolve_lines(Hunk.t()) :: {:ok, [String.t()], String.t()} | :skip
  def resolve_lines(%Hunk{type: :same_change} = h),
    do: {:ok, h.ours_lines, "Same edit on both sides -- trivial (ours == theirs)."}

  def resolve_lines(%Hunk{type: :one_side_change} = h) do
    base = Enum.join(h.base_lines, "\n")

    if Enum.join(h.ours_lines, "\n") == base do
      {:ok, h.theirs_lines, "ours == base -> only theirs changed. Accept theirs."}
    else
      {:ok, h.ours_lines, "theirs == base -> only ours changed. Accept ours."}
    end
  end

  def resolve_lines(%Hunk{type: :delete_no_change}),
    do: {:ok, [], "One side deleted, the other untouched. Resolution: delete."}

  def resolve_lines(%Hunk{type: :whitespace_only} = h),
    do:
      {:ok, h.ours_lines,
       "Whitespace-only difference -- prefer ours (preserve local indentation)."}

  def resolve_lines(%Hunk{type: :reorder_only} = h) do
    if h.base_lines != [] and Enum.join(h.base_lines, "\n") == Enum.join(h.theirs_lines, "\n") do
      {:ok, h.ours_lines, "Pure permutation; base == theirs -> ours reordered. Accept ours."}
    else
      {:ok, h.theirs_lines, "Pure permutation -- accept theirs order."}
    end
  end

  # Reuse the classifier's expensive merge. Manually built hunks without a cached list
  # recompute and can decline; supplied lists are trusted without verification.
  def resolve_lines(%Hunk{type: :non_overlapping, merged_lines: lines}) when is_list(lines),
    do: {:ok, lines, "3-way LCS merge -- non-overlapping changes combined."}

  def resolve_lines(%Hunk{type: :non_overlapping} = h) do
    case Diff.merge_non_overlapping(h.base_lines, h.ours_lines, h.theirs_lines) do
      {:ok, lines} -> {:ok, lines, "3-way LCS merge -- non-overlapping changes combined."}
      {:error, _} -> :skip
    end
  end

  def resolve_lines(%Hunk{type: :insertion_at_boundary} = h) do
    lines =
      if h.base_lines != [] do
        base_counts = Enum.frequencies(h.base_lines)

        h.base_lines ++
          insertions_of(h.ours_lines, base_counts) ++
          insertions_of(h.theirs_lines, base_counts)
      else
        ours_set = MapSet.new(h.ours_lines)
        h.ours_lines ++ Enum.reject(h.theirs_lines, &MapSet.member?(ours_set, &1))
      end

    {:ok, lines, "Pure insertions -- union of both sides."}
  end

  def resolve_lines(%Hunk{type: :value_only_change} = h) do
    case Utils.pick_newer_side(h.ours_lines, h.theirs_lines) do
      :ours -> {:ok, h.ours_lines, "Volatile values -- highest version is ours."}
      :theirs -> {:ok, h.theirs_lines, "Volatile values -- highest version is theirs."}
      nil -> {:ok, h.theirs_lines, "Volatile values, not orderable -- accept theirs (default)."}
    end
  end

  def resolve_lines(%Hunk{}), do: :skip

  # Consume base occurrences as a multiset: an extra identical line (e.g. `}`) is an insertion.
  defp insertions_of(lines, base_counts) do
    {out, _remaining} =
      Enum.reduce(lines, {[], base_counts}, fn l, {out, rem} ->
        case Map.get(rem, l, 0) do
          n when n > 0 -> {out, Map.put(rem, l, n - 1)}
          _ -> {[l | out], rem}
        end
      end)

    Enum.reverse(out)
  end
end
