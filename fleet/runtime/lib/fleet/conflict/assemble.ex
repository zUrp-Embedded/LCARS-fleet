defmodule Fleet.Conflict.Assemble do
  @moduledoc """
  Textual merge per conflict type -- turns a resolvable `Hunk` into merged lines. Only the trivial
  types are handled here; `:complex` (and any not-yet-ported type) returns `:skip`, so the caller
  restores the conflict markers and routes upstream. Never guesses.

  **Last revised**: 2026-07-30
  """
  alias Fleet.Conflict.Hunk

  @spec resolve_lines(Hunk.t()) :: {:ok, [String.t()], String.t()} | :skip
  def resolve_lines(%Hunk{type: :same_change} = h),
    do: {:ok, h.ours_lines, "Same edit on both sides -- trivial (ours == theirs)."}

  def resolve_lines(%Hunk{type: :one_side_change} = h) do
    base = Enum.join(h.base_lines, "\n")

    if Enum.join(h.ours_lines, "\n") == base do
      {:ok, h.theirs_lines, "ours == base -> only theirs changed. Accept theirs."}
    else
      {:ok, h.ours_lines, "theirs == base -> only ours changed. Accept ours."}
    end
  end

  def resolve_lines(%Hunk{type: :delete_no_change}),
    do: {:ok, [], "One side deleted, the other untouched. Resolution: delete."}

  def resolve_lines(%Hunk{}), do: :skip
end
