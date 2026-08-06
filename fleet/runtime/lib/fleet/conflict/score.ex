defmodule Fleet.Conflict.Score do
  @moduledoc """
  THE composite-score formula and label derivation -- the single authority.

  The ported engine kept three divergent copies (a seven-dimension formula in one place, a
  five-dimension recompute in two others); a hunk lost a penalty silently the first time a secondary
  path re-scored it. Here it lives once. Patterns pass dimensions; the score is derived here or
  nowhere.

      score = type_classification
              - data_risk           * 0.40
              - scope_impact        * 0.15
              - file_frequency      * 0.10
              + base_availability   * 0.05
              - algorithm_stability * 0.10
              - post_merge_risk     * 0.20

  Labels by threshold: >= 92 certain, >= 68 high, >= 44 medium, else low.

  **Last revised**: 2026-07-30
  """
  alias Fleet.Conflict.ConfidenceScore

  @doc "Size penalty by number of lines: 1-2 -> 0, 3-10 -> 15, 11-30 -> 35, >30 -> 55."
  @spec scope_impact(non_neg_integer()) :: non_neg_integer()
  def scope_impact(lines) when lines <= 2, do: 0
  def scope_impact(lines) when lines <= 10, do: 15
  def scope_impact(lines) when lines <= 30, do: 35
  def scope_impact(_), do: 55

  @spec label_from_score(number()) :: ConfidenceScore.label()
  def label_from_score(s) when s >= 92, do: :certain
  def label_from_score(s) when s >= 68, do: :high
  def label_from_score(s) when s >= 44, do: :medium
  def label_from_score(_), do: :low

  @doc """
  Builds a `ConfidenceScore` from dimensions. `type_classification`, `data_risk` and `scope_impact`
  are positional (always meaningful); the rest default to 0 (absent = no effect), which the
  additive/subtractive formula makes exact.
  """
  @spec make(non_neg_integer(), non_neg_integer(), non_neg_integer(), keyword()) ::
          ConfidenceScore.t()
  def make(type_classification, data_risk, scope_impact, opts \\ []) do
    file_frequency = Keyword.get(opts, :file_frequency, 0)
    base_availability = Keyword.get(opts, :base_availability, 0)
    algorithm_stability = Keyword.get(opts, :algorithm_stability, 0)
    post_merge_risk = Keyword.get(opts, :post_merge_risk, 0)

    raw =
      type_classification -
        data_risk * 0.40 -
        scope_impact * 0.15 -
        file_frequency * 0.10 +
        base_availability * 0.05 -
        algorithm_stability * 0.10 -
        post_merge_risk * 0.20

    score = raw |> max(0) |> min(100) |> round()

    %ConfidenceScore{
      score: score,
      label: label_from_score(score),
      dimensions: %{
        type_classification: type_classification,
        data_risk: data_risk,
        scope_impact: scope_impact,
        file_frequency: file_frequency,
        base_availability: base_availability
      },
      boosters: Keyword.get(opts, :boosters, []),
      penalties: Keyword.get(opts, :penalties, [])
    }
  end
end
