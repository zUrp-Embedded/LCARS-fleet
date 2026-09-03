defmodule Fleet.Conflict.Patterns.ValueOnlyChange do
  @moduledoc """
  Same structure, only volatile value(s) differ (hash / version / timestamp). `both` since the
  ported engine's v2.7: with a base, a UNILATERAL value change is already `one_side_change` (priority
  30), so this pattern only ever sees the both-sides-changed case. Delegates to
  `Utils.detect_value_only_change/3`.
  """
  @behaviour Fleet.Conflict.Pattern
  alias Fleet.Conflict.Patterns.Utils
  alias Fleet.Conflict.Score

  @impl true
  def type, do: :value_only_change
  @impl true
  def priority, do: 60
  @impl true
  def requires, do: :both

  @impl true
  def detect?(h) do
    length(h.ours_lines) == length(h.theirs_lines) and detect(h) != nil
  end

  @impl true
  def confidence(h) do
    case detect(h) do
      %{confidence: cs} -> cs
      nil -> Score.make(0, 100, 0, penalties: ["internal: confidence/1 called without a match"])
    end
  end

  @impl true
  def explanation(h) do
    case detect(h) do
      %{explanation: e} -> e
      nil -> "Volatile values differ."
    end
  end

  @impl true
  def pass_reason(h) do
    case detect(h) do
      %{trace_reason: r} -> r
      nil -> "Atomic values identified as volatile."
    end
  end

  @impl true
  def fail_reason(h) do
    if length(h.ours_lines) != length(h.theirs_lines) do
      "Ours and theirs have a different number of lines -- different structure."
    else
      "Differences between ours and theirs are not limited to volatile values."
    end
  end

  defp detect(h),
    do: Utils.detect_value_only_change(h.ours_lines, h.theirs_lines, h.base_lines != [])
end
