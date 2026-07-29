defmodule Fleet.Conflict.Classifier do
  @moduledoc """
  Pattern registry + classification. Evaluates patterns in priority order (lowest first), filtered
  by `requires` against base availability, first `detect?/1` wins. The DecisionTrace is built by
  replaying the FULL registry so a skipped or failed pattern is recorded as clearly as the match.

  Adding a pattern = implement `Fleet.Conflict.Pattern` + one entry in `@registry` (a visible,
  reviewable gesture -- the priority ordering is the contract).

  **Last revised**: 2026-07-30
  """
  alias Fleet.Conflict.{DecisionTrace, Hunk, Parser}
  alias Fleet.Conflict.Patterns.{Complex, DeleteNoChange, OneSideChange, SameChange}

  @registry [SameChange, DeleteNoChange, OneSideChange, Complex]

  @doc "Classifies a raw conflict and wraps it as a `Hunk`, applying the zdiff3 adjustment."
  @spec to_hunk(Parser.raw_conflict()) :: Hunk.t()
  def to_hunk(raw) do
    %{type: type, confidence: confidence, explanation: explanation, trace: trace} = classify(raw)
    zdiff3? = Parser.zdiff3?(raw)

    confidence =
      if zdiff3? do
        # zdiff3's base is TRUNCATED but PRESENT -> it is a real diff3 base for our purposes.
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
      zdiff3: zdiff3?
    }
  end

  @doc "Pure classification of a raw conflict (no zdiff3 wrapping)."
  @spec classify(Parser.raw_conflict()) :: %{
          type: atom(),
          confidence: Fleet.Conflict.ConfidenceScore.t(),
          explanation: String.t(),
          trace: DecisionTrace.t()
        }
  def classify(raw) do
    has_base = raw.base_lines != []
    all_sorted = Enum.sort_by(@registry, fn mod -> mod.priority() end)
    eligible = Enum.filter(all_sorted, fn mod -> eligible?(mod, has_base) end)

    # Complex requires :both and detect?/1 = true, so it is always eligible and always matches last.
    matched = Enum.find(eligible, fn mod -> mod.detect?(raw) end)

    %{
      type: matched.type(),
      confidence: matched.confidence(raw),
      explanation: matched.explanation(raw),
      trace: build_trace(raw, eligible, all_sorted, matched, has_base)
    }
  end

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
  defp summary(:complex), do: "Complex conflict -- all automatic heuristics declined."
  defp summary(other), do: "Detected: #{other}."
end
