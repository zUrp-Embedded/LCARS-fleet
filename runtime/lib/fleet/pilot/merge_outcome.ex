defmodule Fleet.Pilot.MergeOutcome do
  @moduledoc """
  Classifies supplied PR fields for merge recovery, without inspecting error strings
  or fetching freshness. Draft precedes mergeable:false because drafts can be
  non-mergeable. Categories guide routing; they do not establish the failure's cause.
  """

  alias Fleet.Forge.Payload

  @type class :: :merged | :closed | :draft | :conflict | :policy | :unknown

  @doc """
  Classifies a raw string-keyed PR map in precedence order: merged, closed, draft,
  conflict, policy, unknown. Unexpected mergeable values fall through to unknown;
  non-map input has no clause.
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
