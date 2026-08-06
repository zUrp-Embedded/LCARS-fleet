defmodule Fleet.Pilot.MergeOutcome do
  @moduledoc """
  Total structural classification of merge failures from fresh forge PR fields,
  never version-specific error strings. Draft precedes `mergeable: false` because
  drafts also report non-mergeable.
  """

  @type class :: :merged | :closed | :draft | :conflict | :policy | :unknown

  @doc """
  Classifies a fresh raw forge pull-request object.
  """
  @spec classify(map()) :: class()
  def classify(pull) when is_map(pull) do
    cond do
      Map.get(pull, "merged") == true -> :merged
      Map.get(pull, "state") == "closed" -> :closed
      Map.get(pull, "draft") == true -> :draft
      Map.get(pull, "mergeable") == false -> :conflict
      Map.get(pull, "mergeable") == true -> :policy
      true -> :unknown
    end
  end
end
