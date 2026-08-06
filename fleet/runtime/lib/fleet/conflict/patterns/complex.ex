defmodule Fleet.Conflict.Patterns.Complex do
  @moduledoc """
  Fallback pattern: always matches, never resolves. The total-function guard at the tail of the
  registry -- its `detect?/1` is `true`, so classification is total, but its confidence floors the
  score so it is never auto-resolved.

  **Last revised**: 2026-07-30
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
