defmodule Fleet.Conflict.Patterns.OneSideChange do
  @moduledoc """
  Exactly one side changed relative to base (XOR) -> take the changed side. diff3 only.
  """
  @behaviour Fleet.Conflict.Pattern
  alias Fleet.Conflict.Score

  @impl true
  def type, do: :one_side_change
  @impl true
  def priority, do: 30
  @impl true
  def requires, do: :diff3

  @impl true
  def detect?(h) do
    base = Enum.join(h.base_lines, "\n")
    ours_matches = Enum.join(h.ours_lines, "\n") == base
    theirs_matches = Enum.join(h.theirs_lines, "\n") == base
    ours_matches != theirs_matches
  end

  @impl true
  def confidence(h) do
    base = Enum.join(h.base_lines, "\n")
    changed = if Enum.join(h.ours_lines, "\n") == base, do: h.theirs_lines, else: h.ours_lines

    Score.make(100, 0, Score.scope_impact(length(changed)),
      boosters: ["Base available -- only one side changed"]
    )
  end

  @impl true
  def explanation(_h),
    do: "Only one branch changed this block. Resolution: accept the changed side."

  @impl true
  def pass_reason(_h), do: "One side equals base, the other changed."
  @impl true
  def fail_reason(_h), do: "Both branches changed the block relative to base."
end
