defmodule Fleet.Conflict.Diff do
  @moduledoc """
  LCS and three-way non-overlapping merge primitives. Conflicting edit ranges
  return `nil`; deterministic tie-breaking keeps index pairs stable.
  """

  @type op :: %{type: :keep | :add | :remove, line: String.t(), index: non_neg_integer()}
  @type edit :: %{
          base_start: non_neg_integer(),
          base_end: non_neg_integer(),
          added_lines: [String.t()],
          source: :ours | :theirs
        }

  @doc "LCS as ordered `{i, j}` index pairs where `a[i] == b[j]` (both strictly increasing)."
  @spec lcs([String.t()], [String.t()]) :: [{non_neg_integer(), non_neg_integer()}]
  def lcs(a, b) do
    av = List.to_tuple(a)
    bv = List.to_tuple(b)
    n = tuple_size(av)
    m = tuple_size(bv)

    dp =
      Enum.reduce(1..n//1, %{}, fn i, dp ->
        Enum.reduce(1..m//1, dp, fn j, dp ->
          val =
            if elem(av, i - 1) == elem(bv, j - 1) do
              Map.get(dp, {i - 1, j - 1}, 0) + 1
            else
              max(Map.get(dp, {i - 1, j}, 0), Map.get(dp, {i, j - 1}, 0))
            end

          Map.put(dp, {i, j}, val)
        end)
      end)

    backtrack(av, bv, dp, n, m, [])
  end

  defp backtrack(_av, _bv, _dp, 0, _j, acc), do: acc
  defp backtrack(_av, _bv, _dp, _i, 0, acc), do: acc

  defp backtrack(av, bv, dp, i, j, acc) do
    cond do
      elem(av, i - 1) == elem(bv, j - 1) ->
        backtrack(av, bv, dp, i - 1, j - 1, [{i - 1, j - 1} | acc])

      Map.get(dp, {i - 1, j}, 0) > Map.get(dp, {i, j - 1}, 0) ->
        backtrack(av, bv, dp, i - 1, j, acc)

      true ->
        backtrack(av, bv, dp, i, j - 1, acc)
    end
  end

  @doc "Diff of `base` against `branch` as an ordered list of keep/add/remove ops."
  @spec compute_diff([String.t()], [String.t()]) :: [op()]
  def compute_diff(base, branch) do
    common = lcs(base, branch)
    base_v = List.to_tuple(base)
    branch_v = List.to_tuple(branch)

    {ops, bi, ri} =
      Enum.reduce(common, {[], 0, 0}, fn {b_idx, r_idx}, {ops, bi, ri} ->
        ops = emit_removes(ops, base_v, bi, b_idx)
        ops = emit_adds(ops, branch_v, ri, r_idx)
        ops = [%{type: :keep, line: elem(base_v, b_idx), index: b_idx} | ops]
        {ops, b_idx + 1, r_idx + 1}
      end)

    ops = emit_removes(ops, base_v, bi, tuple_size(base_v))
    ops = emit_adds(ops, branch_v, ri, tuple_size(branch_v))
    Enum.reverse(ops)
  end

  defp emit_removes(ops, base_v, from, upto) do
    Enum.reduce(from..(upto - 1)//1, ops, fn idx, ops ->
      [%{type: :remove, line: elem(base_v, idx), index: idx} | ops]
    end)
  end

  defp emit_adds(ops, branch_v, from, upto) do
    Enum.reduce(from..(upto - 1)//1, ops, fn idx, ops ->
      [%{type: :add, line: elem(branch_v, idx), index: idx} | ops]
    end)
  end

  @doc "Groups contiguous non-keep ops into edits (base interval + added lines)."
  @spec extract_edits([op()], :ours | :theirs) :: [edit()]
  def extract_edits(diff, source) do
    diff_v = List.to_tuple(diff)
    do_extract(diff_v, 0, tuple_size(diff_v), source, [])
  end

  defp do_extract(_diff_v, i, len, _source, edits) when i >= len, do: Enum.reverse(edits)

  defp do_extract(diff_v, i, len, source, edits) do
    if elem(diff_v, i).type == :keep do
      do_extract(diff_v, i + 1, len, source, edits)
    else
      {removed, added, next_i} = collect_run(diff_v, i, len, [], [])

      base_start =
        case removed do
          [first | _] -> first
          [] -> find_next_keep_base_index(diff_v, next_i, len)
        end

      base_end =
        case removed do
          [] -> base_start
          _ -> List.last(removed) + 1
        end

      edit = %{base_start: base_start, base_end: base_end, added_lines: added, source: source}
      do_extract(diff_v, next_i, len, source, [edit | edits])
    end
  end

  defp collect_run(diff_v, i, len, removed, added) do
    if i >= len or elem(diff_v, i).type == :keep do
      {Enum.reverse(removed), Enum.reverse(added), i}
    else
      op = elem(diff_v, i)

      case op.type do
        :remove -> collect_run(diff_v, i + 1, len, [op.index | removed], added)
        :add -> collect_run(diff_v, i + 1, len, removed, [op.line | added])
      end
    end
  end

  # Base index for a PURE addition (no removed lines): the next keep's base index, else just past
  # the last keep/remove, else 0 (addition at the very start of an empty base).
  defp find_next_keep_base_index(diff_v, from, len) do
    forward =
      Enum.find_value(from..(len - 1)//1, fn j ->
        op = elem(diff_v, j)
        if op.type == :keep, do: op.index, else: nil
      end)

    case forward do
      nil ->
        backward =
          Enum.find_value((len - 1)..0//-1, fn j ->
            op = elem(diff_v, j)
            if op.type in [:keep, :remove], do: op.index + 1, else: nil
          end)

        backward || 0

      idx ->
        idx
    end
  end

  @doc "True when two edits touch overlapping base intervals (pure insertions handled specially)."
  @spec edits_overlap?(edit(), edit()) :: boolean()
  def edits_overlap?(a, b) do
    cond do
      a.base_start == a.base_end and b.base_start == b.base_end ->
        a.base_start == b.base_start

      a.base_start == a.base_end ->
        a.base_start >= b.base_start and a.base_start < b.base_end

      b.base_start == b.base_end ->
        b.base_start >= a.base_start and b.base_start < a.base_end

      true ->
        a.base_start < b.base_end and b.base_start < a.base_end
    end
  end

  @doc "Merges non-overlapping ours/theirs edits over `base`; `nil` if any pair overlaps."
  @spec merge_non_overlapping([String.t()], [String.t()], [String.t()]) :: [String.t()] | nil
  def merge_non_overlapping(base, ours, theirs) do
    ours_edits = extract_edits(compute_diff(base, ours), :ours)
    theirs_edits = extract_edits(compute_diff(base, theirs), :theirs)

    overlap? =
      Enum.any?(ours_edits, fn oe ->
        Enum.any?(theirs_edits, fn te -> edits_overlap?(oe, te) end)
      end)

    if overlap? do
      nil
    else
      all = Enum.sort_by(ours_edits ++ theirs_edits, fn e -> {e.base_start, e.base_end} end)
      reconstruct(all, List.to_tuple(base), 0, [])
    end
  end

  defp reconstruct([], base_v, base_idx, acc) do
    tail = Enum.map(base_idx..(tuple_size(base_v) - 1)//1, &elem(base_v, &1))
    Enum.reverse(acc) ++ tail
  end

  defp reconstruct([edit | rest], base_v, base_idx, acc) do
    {acc, base_idx} = copy_base(acc, base_v, base_idx, edit.base_start)
    acc = Enum.reduce(edit.added_lines, acc, fn l, a -> [l | a] end)
    base_idx = if edit.base_end > base_idx, do: edit.base_end, else: base_idx
    reconstruct(rest, base_v, base_idx, acc)
  end

  defp copy_base(acc, base_v, base_idx, upto) when base_idx < upto,
    do: copy_base([elem(base_v, base_idx) | acc], base_v, base_idx + 1, upto)

  defp copy_base(acc, _base_v, base_idx, _upto), do: {acc, base_idx}
end
