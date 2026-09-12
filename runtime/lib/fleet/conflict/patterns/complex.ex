defmodule Fleet.Conflict.Patterns.Complex do
  @moduledoc """
  Always-eligible fallback at the end of the registry. Conflict excludes this type from
  writing at every confidence floor; Assemble returns :skip. Its score alone is not that gate.
  """
  @behaviour Fleet.Conflict.Pattern
  alias Fleet.Conflict.Score

  @impl true
  def type, do: :complex
  @impl true
  def priority, do: 999
  @impl true
  def requires, do: :both
  @impl true
  def detect?(_h), do: true
  @impl true
  def confidence(_h), do: Score.make(100, 100, 0, penalties: ["No automatic heuristic applies"])
  @impl true
  def explanation(_h), do: "Complex conflict -- manual resolution required."
  @impl true
  def pass_reason(_h), do: "No automatic pattern applies -- manual resolution required."
  @impl true
  def fail_reason(_h), do: ""
end
