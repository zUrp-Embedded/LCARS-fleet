defmodule Fleet.Conflict.Classifier do
  @moduledoc """
  Evaluates eligible patterns by ascending priority; first match wins. Base availability
  means non-empty base_lines, so an empty diff3 base is treated as absent. DecisionTrace
  records skipped/failed patterns only up to the winner. Reason/score callbacks may
  recompute detection; NonOverlapping specifically reuses its cached merge.
  Add patterns through Fleet.Conflict.Pattern and @registry.
  """
  alias Fleet.Conflict.{DecisionTrace, Hunk, Parser}

  alias Fleet.Conflict.Patterns.{
    Complex,
    DeleteNoChange,
    InsertionAtBoundary,
    NonOverlapping,
    OneSideChange,
    ReorderOnly,
    SameChange,
    ValueOnlyChange,
    WhitespaceOnly
  }

  @registry [
    SameChange,
    DeleteNoChange,
    OneSideChange,
    NonOverlapping,
    WhitespaceOnly,
    ReorderOnly,
    InsertionAtBoundary,
    ValueOnlyChange,
    Complex
  ]

  @doc "Classifies a raw conflict and wraps it as a `Hunk`, applying the zdiff3 adjustment."
  @spec to_hunk(Parser.raw_conflict()) :: Hunk.t()
  def to_hunk(raw) do
    %{
      type: type,
      confidence: confidence,
      explanation: explanation,
      trace: trace,
      merged_lines: merged_lines
    } = classify(raw)

    zdiff3? = Parser.zdiff3?(raw)

    confidence =
      if zdiff3? do
        # Heuristic annotation only: the score and label remain unchanged.
        %{
          confidence
          | boosters: confidence.boosters ++ ["zdiff3 -- base truncated to diverging lines"]
        }
      else
        confidence
      end

    %Hunk{
      base_lines: raw.base_lines,
      ours_lines: raw.ours_lines,
      theirs_lines: raw.theirs_lines,
      start_line: raw.start_line,
      type: type,
      confidence: confidence,
      explanation: explanation,
      trace: trace,
      merged_lines: merged_lines,
      zdiff3: zdiff3?
    }
  end

  @doc "Pure classification of a raw conflict (no zdiff3 wrapping)."
  @spec classify(Parser.raw_conflict()) :: %{
          type: atom(),
          confidence: Fleet.Conflict.ConfidenceScore.t(),
          explanation: String.t(),
          trace: DecisionTrace.t(),
          merged_lines: [String.t()] | nil
        }
  def classify(raw) do
    has_base = raw.base_lines != []
    all_sorted = Enum.sort_by(@registry, fn mod -> mod.priority() end)
    eligible = Enum.filter(all_sorted, fn mod -> eligible?(mod, has_base) end)

    # Complex requires :both and detect?/1 = true, so it is always eligible and always matches last.
    {matched, merged_lines} = Enum.find_value(eligible, fn mod -> detect(mod, raw) end)

    %{
      type: matched.type(),
      confidence: matched.confidence(raw),
      explanation: matched.explanation(raw),
      trace: build_trace(raw, eligible, all_sorted, matched, has_base),
      merged_lines: merged_lines
    }
  end

  # Cache NonOverlapping's merge payload despite the boolean behavior callback. Lazy selection
  # avoids this computation entirely when an earlier pattern wins.
  defp detect(NonOverlapping, raw) do
    case NonOverlapping.merge(raw) do
      {:ok, lines} -> {NonOverlapping, lines}
      {:error, _} -> nil
    end
  end

  defp detect(mod, raw), do: if(mod.detect?(raw), do: {mod, nil})

  @spec eligible?(module(), boolean()) :: boolean()
  defp eligible?(mod, has_base) do
    case mod.requires() do
      :both -> true
      :diff3 -> has_base
      :diff2 -> not has_base
    end
  end

  defp build_trace(raw, eligible, all_sorted, matched, has_base) do
    steps =
      Enum.reduce_while(all_sorted, [], fn mod, acc ->
        cond do
          mod not in eligible ->
            {:cont, [%{type: mod.type(), passed: false, reason: skip_reason(mod)} | acc]}

          mod == matched ->
            {:halt, [%{type: mod.type(), passed: true, reason: mod.pass_reason(raw)} | acc]}

          true ->
            {:cont, [%{type: mod.type(), passed: false, reason: mod.fail_reason(raw)} | acc]}
        end
      end)

    %DecisionTrace{
      steps: Enum.reverse(steps),
      selected: matched.type(),
      summary: summary(matched.type()),
      has_base: has_base
    }
  end

  @spec skip_reason(module()) :: String.t()
  defp skip_reason(mod) do
    case mod.requires() do
      :diff3 -> "Base (diff3) unavailable -- #{mod.type()} requires diff3, skipped."
      :diff2 -> "Base present -- #{mod.type()} requires diff2, skipped."
      :both -> "skipped"
    end
  end

  defp summary(:same_change), do: "Same edit on both sides -- trivial."
  defp summary(:delete_no_change), do: "One side deleted, the other untouched -- delete."
  defp summary(:one_side_change), do: "Only one side changed -- take the changed side."
  defp summary(:non_overlapping), do: "Non-overlapping changes -- 3-way LCS merge."
  defp summary(:whitespace_only), do: "Whitespace-only difference."
  defp summary(:reorder_only), do: "Pure permutation -- same lines, different order."
  defp summary(:insertion_at_boundary), do: "Pure insertions on both sides -- union."
  defp summary(:value_only_change), do: "Volatile value(s) differ."
  defp summary(:complex), do: "Complex conflict -- all automatic heuristics declined."
  defp summary(other), do: "Detected: #{other}."
end
