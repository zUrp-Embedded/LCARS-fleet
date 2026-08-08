defmodule Fleet.Conflict.Score do
  @moduledoc """
  Single authority for composite confidence scoring and label derivation.

      score = type_classification
              - data_risk           * 0.40
              - scope_impact        * 0.15
              - file_frequency      * 0.10
              + base_availability   * 0.05
              - algorithm_stability * 0.10
              - post_merge_risk     * 0.20

  Labels: >=92 certain, >=68 high, >=44 medium, otherwise low.
  """
  alias Fleet.Conflict.ConfidenceScore

  @doc "Size penalty by number of lines: 1-2 -> 0, 3-10 -> 15, 11-30 -> 35, >30 -> 55."
  @spec scope_impact(non_neg_integer()) :: non_neg_integer()
  def scope_impact(lines) when lines <= 2, do: 0
  def scope_impact(lines) when lines <= 10, do: 15
  def scope_impact(lines) when lines <= 30, do: 35
  def scope_impact(_), do: 55

  @doc """
  Folds a numeric confidence into the label the rest of the engine routes on.

  The thresholds live HERE and nowhere else: a second table would let a report say `:high` while the
  gate read the number as medium, and the two would disagree without either being wrong.
  """
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
