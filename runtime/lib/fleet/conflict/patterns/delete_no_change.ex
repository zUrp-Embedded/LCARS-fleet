defmodule Fleet.Conflict.Patterns.DeleteNoChange do
  @moduledoc """
  With a non-empty base, matches unilateral deletion while the other side equals base (:certain).
  Without a base, one empty side is only a deletion heuristic (:medium). The default :high
  floor refuses that candidate, but lowering min_confidence to :medium permits deletion.
  """
  @behaviour Fleet.Conflict.Pattern
  alias Fleet.Conflict.Score

  @impl true
  def type, do: :delete_no_change
  @impl true
  def priority, do: 20
  @impl true
  def requires, do: :both

  @impl true
  @spec detect?(map()) :: boolean()
  def detect?(%{base_lines: []} = h) do
    (h.ours_lines == [] and h.theirs_lines != []) or (h.theirs_lines == [] and h.ours_lines != [])
  end

  def detect?(h) do
    base = Enum.join(h.base_lines, "\n")

    (h.ours_lines == [] and Enum.join(h.theirs_lines, "\n") == base) or
      (h.theirs_lines == [] and Enum.join(h.ours_lines, "\n") == base)
  end

  @impl true
  @spec confidence(map()) :: Fleet.Conflict.ConfidenceScore.t()
  def confidence(%{base_lines: []}),
    do:
      Score.make(60, 30, 0,
        penalties: ["No base (diff2) -- deletion not confirmed against the common ancestor"]
      )

  def confidence(_h),
    do:
      Score.make(100, 5, 0,
        boosters: ["Base available -- one side deleted, the other matches base"]
      )

  @impl true
  def explanation(_h),
    do: "One side deleted this block and the other did not touch it. Resolution: delete."

  @impl true
  def pass_reason(_h),
    do: "Unilateral deletion with the other side equal to base (or empty in diff2)."

  @impl true
  def fail_reason(_h), do: "Neither side is a clean unilateral deletion."
end
