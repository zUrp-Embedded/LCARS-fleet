defmodule Fleet.Conflict.Patterns.SameChange do
  @moduledoc """
  Both branches made the exact same edit -> trivial (ours == theirs).

  **Last revised**: 2026-07-30
  """
  @behaviour Fleet.Conflict.Pattern
  alias Fleet.Conflict.Score

  @impl true
  def type, do: :same_change
  @impl true
  def priority, do: 10
  @impl true
  def requires, do: :both

  @impl true
  def detect?(h), do: Enum.join(h.ours_lines, "\n") == Enum.join(h.theirs_lines, "\n")

  @impl true
  def confidence(h),
    do:
      Score.make(100, 0, Score.scope_impact(length(h.ours_lines)),
        boosters: ["Both branches carry identical content"]
      )

  @impl true
  def explanation(_h), do: "Both branches made the exact same change."
  @impl true
  def pass_reason(_h), do: "Both sides carry identical content -- same edit on both branches."
  @impl true
  def fail_reason(_h), do: "The two branches carry different content."
end
