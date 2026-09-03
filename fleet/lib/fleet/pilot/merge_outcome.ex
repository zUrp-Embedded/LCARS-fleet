defmodule Fleet.Pilot.MergeOutcome do
  @moduledoc """
  Total structural classification of merge failures from fresh forge PR fields,
  never version-specific error strings. Draft precedes `mergeable: false` because
  drafts also report non-mergeable.
  """

  alias Fleet.Forge.Payload

  @type class :: :merged | :closed | :draft | :conflict | :policy | :unknown

  @doc """
  Classifies a fresh raw forge pull-request object.
  """
  @spec classify(map()) :: class()
  def classify(pull) when is_map(pull) do
    cond do
      Payload.merged?(pull) -> :merged
      Map.get(pull, "state") == "closed" -> :closed
      Payload.draft?(pull) -> :draft
      Payload.mergeable(pull) == false -> :conflict
      Payload.mergeable(pull) == true -> :policy
      true -> :unknown
    end
  end
end
