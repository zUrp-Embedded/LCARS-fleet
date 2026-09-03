defmodule Fleet.Conflict.Assemble do
  @moduledoc """
  Textual merge per conflict type -- turns a resolvable `Hunk` into merged lines. `:complex` (and any
  type this engine does not settle) returns `:skip`; the caller then drops its whole merged output
  and routes upstream, WITHOUT rebuilding any marker block. Never guesses.
  """
  alias Fleet.Conflict.{Diff, Hunk}
  alias Fleet.Conflict.Patterns.Utils

  @doc """
  Resolved lines for a hunk the engine can settle mechanically, with the sentence explaining WHY.

  `:skip` for every hunk whose type carries a real disagreement — the explanation is not decoration
  there either: a resolution nobody can read is a merge nobody can review.
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

  # The merge was already performed to CLASSIFY this hunk, and its result travels on the hunk. The
  # clause below is what happens when it does not: a hunk built by hand (a test, a future caller
  # that skips the classifier) still gets a correct answer, at the price of the computation.
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

  # MULTISET insertions: a line equal to a base line is a REAL insertion (a duplicated `}`, a
  # repeated line) -- a plain Set would filter it and silently drop it from the result. Consume base
  # occurrences before counting a line as new.
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
