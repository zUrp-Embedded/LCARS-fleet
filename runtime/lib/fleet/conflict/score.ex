defmodule Fleet.Conflict.Score do
  @moduledoc """
  Composite classification score and label derivation. Weights live in make/4, label
  thresholds in label_from_score/1. These heuristics are not probabilities or write authorization.
  """
  alias Fleet.Conflict.ConfidenceScore

  @doc "Size penalty by number of lines — a bigger block is a bigger blast radius."
  @spec scope_impact(non_neg_integer()) :: non_neg_integer()
  def scope_impact(lines) when lines <= 2, do: 0
  def scope_impact(lines) when lines <= 10, do: 15
  def scope_impact(lines) when lines <= 30, do: 35
  def scope_impact(_), do: 55

  @doc """
  Maps a score to its routing label. Call this authority rather than copying thresholds.
  """
  @spec label_from_score(number()) :: ConfidenceScore.label()
  def label_from_score(s) when s >= 92, do: :certain
  def label_from_score(s) when s >= 68, do: :high
  def label_from_score(s) when s >= 44, do: :medium
  def label_from_score(_), do: :low

  @doc """
  Weighs dimensions, clamps to 0..100, rounds, then derives the label. Numeric options default
  to zero; values are not validated. Text boosters/penalties are annotations, not score inputs.
  algorithm_stability and post_merge_risk affect the score but are omitted from returned dimensions,
  so that map alone cannot always reproduce the score.
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
