defmodule Fleet.Conflict do
  use Boundary, deps: [], exports: [Report]

  @moduledoc """
  Pure text classification and merge candidates for Pilot conflict triage; no Git or I/O.
  The deterministic patterns and confidence trace derive from GitWand, excluding its
  format-aware, structural and LLM resolvers. Attribution: root THIRD_PARTY_NOTICES.md.

  resolve/2 returns {:ok, Report} or an unterminated-conflict error. A non-nil merged
  candidate requires at least one hunk and every hunk to pass both the writable-type gate
  and confidence floor. Any residual discards the entire candidate; no partial merge or
  reconstructed marker labels are returned. A clean file has no hunks and merged: nil.

  Confidence and disjoint text edits do not validate language semantics. Callers remain
  responsible for applying and reviewing a candidate; downstream re-judging is another
  check, not a guarantee that a wrong resolution will be caught.
  """
  alias Fleet.Conflict.{Assemble, Classifier, Parser, Report}

  @confidence_rank %{certain: 4, high: 3, medium: 2, low: 1}

  # Type authorization is independent of confidence. Keep the other patterns for routing,
  # but exclude their semantic guesses: whitespace can change Python/YAML scope; order can
  # change Docker/CSS behavior; insertion union can duplicate keys/definitions; hashes and
  # UUIDs have no "newer" side. Lowering the floor must not authorize those types.
  # delete_no_change without a base is only a heuristic: :medium explicitly permits it.
  @writable_types [:same_change, :one_side_change, :delete_no_change, :non_overlapping]

  @type opt :: {:min_confidence, Fleet.Conflict.ConfidenceScore.label()}

  @doc """
  Classifies `content` (git conflict-marked text) and resolves the trivially-resolvable hunks.
  `:min_confidence` (default `:high`) is the floor below which a resolvable hunk is left as a
  residual rather than applied.
  """
  @spec resolve(String.t(), [opt()]) :: {:ok, Report.t()} | {:error, Parser.error()}
  def resolve(content, opts \\ []) do
    min = Keyword.get(opts, :min_confidence, :high)

    with {:ok, segments} <- Parser.segments(content) do
      {output, hunks_rev, all_resolved?} =
        Enum.reduce(segments, {[], [], true}, &segment_step(&1, &2, min))

      hunks = Enum.reverse(hunks_rev)
      merged = if all_resolved? and hunks != [], do: Enum.join(output, "\n"), else: nil
      {:ok, %Report{merged: merged, hunks: hunks, stats: stats(hunks)}}
    end
  end

  defp segment_step({:text, lines}, {out, hs, ok}, _min), do: {out ++ lines, hs, ok}

  # Residuals discard the whole candidate. Rebuilding markers with fixed labels would lose
  # the branch/revision names a human needs; callers must retain the original content.
  defp segment_step({:conflict, raw}, {out, hs, ok}, min) do
    hunk = Classifier.to_hunk(raw)

    case try_resolve(hunk, min) do
      {:ok, lines} -> {out ++ lines, [hunk | hs], ok}
      :unresolved -> {out, [hunk | hs], false}
    end
  end

  defp try_resolve(hunk, min) do
    if hunk.type in @writable_types and rank(hunk.confidence.label) >= rank(min) do
      case Assemble.resolve_lines(hunk) do
        {:ok, lines, _reason} -> {:ok, lines}
        :skip -> :unresolved
      end
    else
      :unresolved
    end
  end

  defp rank(label), do: Map.fetch!(@confidence_rank, label)

  # writable counts types, not hunks that passed the confidence floor or produced output.
  defp stats(hunks) do
    complex = Enum.count(hunks, &(&1.type == :complex))
    total = length(hunks)
    writable = Enum.count(hunks, &(&1.type in @writable_types))
    %{trivial: total - complex, complex: complex, total: total, writable: writable}
  end
end
