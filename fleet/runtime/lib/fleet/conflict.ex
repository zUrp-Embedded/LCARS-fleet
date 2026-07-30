defmodule Fleet.Conflict do
  use Boundary, deps: [], exports: [Report]

  @moduledoc """
  Deterministic classifier and trivial-merge engine for git conflicts -- pure text -> classification
  (+ resolution). No git, no I/O, no process: a `foundation` primitive (`deps: []`), consumed by
  `Fleet.Pilot` to triage a merge conflict BEFORE spending a producer round or escalating to a human.

  Ported from the sane deterministic core of an external engine (GitWand) -- the trivial patterns
  and their composite-confidence trace, none of the format-aware / structural / LLM machinery an
  audit flagged as unreliable. The durable value is the DecisionTrace: every classification records
  WHY, and the refusal is traced as clearly as the resolution.

  ## Contract

  `resolve/2` returns a `Fleet.Conflict.Report`. `merged` is non-nil ONLY when every hunk was
  resolved at or above `:min_confidence` (default `:high`) -- the single "safe to write back"
  signal. Any residual (`:complex`, or a resolvable hunk below threshold) leaves `merged: nil`; the
  caller then routes to the producer conflict-rework / gatekeeper, never writing on a partial guess.

  Even when `merged` is set, the LCARS pipeline re-judges the pushed head, so a wrong trivial
  resolution is caught downstream -- the guard the standalone engine lacked.

  **Last revised**: 2026-07-30
  """
  alias Fleet.Conflict.{Assemble, Classifier, Parser, Report}

  @confidence_rank %{certain: 4, high: 3, medium: 2, low: 1}

  @type opt :: {:min_confidence, Fleet.Conflict.ConfidenceScore.label()}

  @doc """
  Classifies `content` (git conflict-marked text) and resolves the trivially-resolvable hunks.
  `:min_confidence` (default `:high`) is the floor below which a resolvable hunk is left as a
  residual rather than applied.
  """
  @spec resolve(String.t(), [opt()]) :: {:ok, Report.t()}
  def resolve(content, opts \\ []) do
    min = Keyword.get(opts, :min_confidence, :high)

    {output, hunks_rev, all_resolved?} =
      content
      |> Parser.segments()
      |> Enum.reduce({[], [], true}, fn
        {:text, lines}, {out, hs, ok} ->
          {out ++ lines, hs, ok}

        {:conflict, raw}, {out, hs, ok} ->
          hunk = Classifier.to_hunk(raw)

          case try_resolve(hunk, min) do
            {:ok, lines} -> {out ++ lines, [hunk | hs], ok}
            :unresolved -> {out ++ restore_markers(hunk), [hunk | hs], false}
          end
      end)

    hunks = Enum.reverse(hunks_rev)
    merged = if all_resolved? and hunks != [], do: Enum.join(output, "\n"), else: nil
    {:ok, %Report{merged: merged, hunks: hunks, stats: stats(hunks)}}
  end

  defp try_resolve(hunk, min) do
    if rank(hunk.confidence.label) >= rank(min) do
      case Assemble.resolve_lines(hunk) do
        {:ok, lines, _reason} -> {:ok, lines}
        :skip -> :unresolved
      end
    else
      :unresolved
    end
  end

  defp rank(label), do: Map.fetch!(@confidence_rank, label)

  # Restores the conflict block verbatim (diff3 shape when a base is present) so an unresolved hunk
  # goes back to the working tree exactly as git would leave it.
  defp restore_markers(hunk) do
    base = if hunk.base_lines != [], do: ["||||||| base" | hunk.base_lines], else: []

    ["<<<<<<< ours" | hunk.ours_lines] ++
      base ++ ["=======" | hunk.theirs_lines] ++ [">>>>>>> theirs"]
  end

  # `trivial` = hunks classified as a resolvable type; `complex` = the residual that needs a human
  # or the producer. Classification-based, not resolution-based: a resolvable type kept below the
  # confidence floor still counts trivial (it is recoverable, just not at this threshold).
  defp stats(hunks) do
    complex = Enum.count(hunks, &(&1.type == :complex))
    total = length(hunks)
    %{trivial: total - complex, complex: complex, total: total}
  end
end
