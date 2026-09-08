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

  # THE TABLE IS THE COST, AND NOTHING BOUNDS IT ON ITS OWN. `lcs/2` fills one persistent-map entry
  # per `{i, j}` couple -- `n * m` entries in time AND in memory, for a hunk whose size no caller
  # limits. MEASURED on this build (two sequences of n lines each, strings of ~50 chars):
  #
  #     n=100    10 000 cells     3.4 ms      ~1 MiB
  #     n=200    40 000 cells    17.4 ms      ~7 MiB
  #     n=500   250 000 cells   178.6 ms     ~21 MiB
  #
  # ~91 bytes and ~0.71 us per cell, quadratic in n. A 5 000-line hunk -- a lockfile, a generated
  # file, a snapshot, i.e. EXACTLY what produces big conflicts -- is 25 million cells: ~2.2 GiB and
  # ~18 s for ONE table, and a three-way merge builds TWO. The BEAM does not refuse it; it swaps and
  # freezes the calling process, during CLASSIFICATION, before any decision to resolve was taken.
  #
  # The ceiling is set where an automatic merge stops being reasonable rather than where the machine
  # stops coping: 500x500 costs 21 MiB and 179 ms per table, twice per hunk. A conflict block bigger
  # than that is a human's, not the engine's.
  @max_lcs_cells 250_000

  @doc """
  LCS as ordered `{i, j}` index pairs where `a[i] == b[j]` (both strictly increasing).

  `{:error, :too_large}` when the DP table would exceed #{@max_lcs_cells} cells. It is a RETURN and
  not a silent empty result because the two are indistinguishable downstream: an empty LCS means
  "these sequences share nothing", which would make a bounded merge produce a confident WRONG diff.
  Callers cannot forget to read it, which is the point -- a budget the caller must remember to check
  is a budget the next caller will not check.
  """
  @spec lcs([String.t()], [String.t()]) ::
          {:ok, [{non_neg_integer(), non_neg_integer()}]} | {:error, :too_large}
  def lcs(a, b) do
    av = List.to_tuple(a)
    bv = List.to_tuple(b)
    n = tuple_size(av)
    m = tuple_size(bv)

    if n * m > @max_lcs_cells, do: {:error, :too_large}, else: {:ok, do_lcs(av, bv, n, m)}
  end

  @doc "The ceiling above which `lcs/2` declines, in DP cells."
  @spec max_lcs_cells() :: pos_integer()
  def max_lcs_cells, do: @max_lcs_cells

  @doc """
  Whether `lcs/2` would decline this pair -- O(1) on the two lengths.

  It exists so a caller can NAME the refusal without paying for it. The decision trace records a
  reason for every pattern it rejected; deriving that reason by re-running the merge would make the
  trace, which is pure narration, the most expensive step of the classification.
  """
  @spec over_lcs_budget?([String.t()], [String.t()]) :: boolean()
  def over_lcs_budget?(a, b), do: length(a) * length(b) > @max_lcs_cells

  defp do_lcs(av, bv, n, m) do
    dp =
      Enum.reduce(1..n//1, %{}, fn i, dp ->
        Enum.reduce(1..m//1, dp, fn j, dp ->
          Map.put(dp, {i, j}, lcs_cell(dp, av, bv, i, j))
        end)
      end)

    backtrack(av, bv, dp, n, m, [])
  end

  # UNE CELLULE DE LA MATRICE LCS : egalite -> la diagonale plus un, sinon le meilleur des deux
  # voisins. Sortie de la double reduction pour que celle-ci ne porte plus que le parcours.
  defp lcs_cell(dp, av, bv, i, j) do
    if elem(av, i - 1) == elem(bv, j - 1) do
      Map.get(dp, {i - 1, j - 1}, 0) + 1
    else
      max(Map.get(dp, {i - 1, j}, 0), Map.get(dp, {i, j - 1}, 0))
    end
  end

  # L'index de base d'une operation ANCREE (`:keep` ou `:remove`) — une insertion n'en a pas.
  defp anchored_index(%{type: t, index: i}) when t in [:keep, :remove], do: i + 1
  defp anchored_index(_op), do: nil

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
  @spec compute_diff([String.t()], [String.t()]) :: {:ok, [op()]} | {:error, :too_large}
  def compute_diff(base, branch) do
    with {:ok, common} <- lcs(base, branch), do: {:ok, do_compute_diff(base, branch, common)}
  end

  defp do_compute_diff(base, branch, common) do
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
        Enum.find_value((len - 1)..0//-1, &anchored_index(elem(diff_v, &1))) || 0

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

  @doc """
  Merges non-overlapping ours/theirs edits over `base`.

  `{:error, :overlap}` when a pair of edits touches the same base interval, `{:error, :too_large}`
  when a side exceeds the LCS budget. The two are kept APART: both mean "the engine will not merge
  this", but only the first is a statement about the CONTENT. Collapsing them onto one `nil` made
  the decision trace say "both branches touched the same lines" about a block nobody had compared.
  """
  @spec merge_non_overlapping([String.t()], [String.t()], [String.t()]) ::
          {:ok, [String.t()]} | {:error, :overlap | :too_large}
  def merge_non_overlapping(base, ours, theirs) do
    with {:ok, ours_diff} <- compute_diff(base, ours),
         {:ok, theirs_diff} <- compute_diff(base, theirs) do
      ours_edits = extract_edits(ours_diff, :ours)
      theirs_edits = extract_edits(theirs_diff, :theirs)

      overlap? = Enum.any?(ours_edits, &overlapped?(&1, theirs_edits))

      if overlap? do
        {:error, :overlap}
      else
        all = Enum.sort_by(ours_edits ++ theirs_edits, &{&1.base_start, &1.base_end})
        {:ok, reconstruct(all, List.to_tuple(base), 0, [])}
      end
    end
  end

  # Un seul intervalle commun suffit : la fusion est refusee des la premiere paire qui se touche.
  defp overlapped?(ours_edit, theirs_edits),
    do: Enum.any?(theirs_edits, &edits_overlap?(ours_edit, &1))

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
