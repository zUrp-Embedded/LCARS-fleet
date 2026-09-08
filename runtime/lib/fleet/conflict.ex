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

  The origin is indexed at the ROOT (`THIRD_PARTY_NOTICES.md`), not only here. A credit that lives solely in the
  prose of the file it applies to is one refactor away from disappearing with it, and the question
  it answers -- does anything in this repository come from somewhere else -- is asked from outside,
  by someone who has no reason to open this module.

  ## Contract

  `resolve/2` returns a `Fleet.Conflict.Report`. `merged` is non-nil ONLY when every hunk is of an
  auto-WRITABLE type (cf. `@writable_types` -- a blast-radius judgement the confidence score does
  not carry) AND resolved at or above `:min_confidence` (default `:high`). That pair is the single
  "safe to write back" signal; confidence alone was not enough, and the gap wrote Python indentation
  and duplicate YAML keys at `:high`. Any residual (`:complex`, or a resolvable hunk below threshold) leaves `merged: nil`; the
  caller then routes to the producer conflict-rework / chief exception pass, never writing on a partial guess.

  `resolve/2` returns `{:error, {:unterminated_conflict, state, line}}` when the markers do not
  close. Returning an empty report there would be the EXACT report of a file with no conflict, so
  "I could not read this" and "there is nothing here" would be the same answer. It is an error and
  not an empty report because the two demand opposite moves from every caller: one aborts, the other
  proceeds.

  Even when `merged` is set, the LCARS pipeline re-judges the pushed head, so a wrong trivial
  resolution is caught downstream -- the guard the standalone engine lacked.
  """
  alias Fleet.Conflict.{Assemble, Classifier, Parser, Report}

  @confidence_rank %{certain: 4, high: 3, medium: 2, low: 1}

  # WRITE-SAFETY, a dimension the confidence score does NOT carry. The score answers "how sure am I
  # of this classification"; it says nothing about what being wrong COSTS. Two patterns can both
  # score `:high` and sit above the write floor -- `whitespace_only` and `non_overlapping` do -- yet
  # being wrong about the first rewrites Python indentation while being wrong about the second is
  # near-impossible (the base proves the two sides touch disjoint lines).
  #
  # A pattern is auto-WRITABLE only when its correctness follows from the base and the two sides
  # ALONE, with no assumption about the language:
  #
  #   * same_change      -- the sides are identical; there is nothing to choose.
  #   * one_side_change  -- the base proves only one side moved.
  #   * delete_no_change -- the base proves the deletion is unilateral.
  #   * non_overlapping  -- the base proves the two changes touch disjoint regions.
  #
  # The rest each need a semantic assumption this engine cannot check, because it is deliberately
  # FORMAT-BLIND (the audited engine's format-aware resolvers were dropped for being unreliable --
  # dropping them and then keeping patterns that silently assume a format is the same bug wearing
  # the opposite mask). What they assume, and where it is false, measured:
  #
  #   * whitespace_only       assumes whitespace is insignificant -> Python indent/dedent changes
  #                           scope, YAML indent changes which key owns a value.
  #   * reorder_only          assumes order is insignificant -> `RUN apt update` after `install`,
  #                           CSS last-wins, `log()` before `auth()`.
  #   * insertion_at_boundary assumes two insertions at one place are ADDITIVE -> when they are
  #                           alternatives it keeps both: duplicate YAML key (invalid file),
  #                           duplicate `def` (dead clause), duplicate CSS property (ours lost).
  #   * value_only_change     picks the "newer" value -- and for an UNORDERABLE volatile (a sha, a
  #                           uuid) `Assemble` itself records "not orderable -- accept theirs
  #                           (default)". A coin flip must not ride a `:high` label to disk.
  #
  # These stay CLASSIFIED (the diagnosis "this is shallow, a producer fixes it in one round" is real
  # and drives tier-0 routing) but are never WRITTEN by the machine. Keeping the classifier without
  # this line is the shape of the bug: a diagnosis that quietly becomes a write authorisation.
  @writable_types [:same_change, :one_side_change, :delete_no_change, :non_overlapping]

  @type opt :: {:min_confidence, Fleet.Conflict.ConfidenceScore.label()}

  @doc """
  Classifies `content` (git conflict-marked text) and resolves the trivially-resolvable hunks.
  `:min_confidence` (default `:high`) is the floor below which a resolvable hunk is left as a
  residual rather than applied.
  """
  @spec resolve(String.t(), [opt()]) :: {:ok, Report.t()} | {:error, Parser.error()}
  def resolve(content, opts \\ []) do
    min = Keyword.get(opts, :min_confidence, :high)

    with {:ok, segments} <- Parser.segments(content) do
      {output, hunks_rev, all_resolved?} =
        Enum.reduce(segments, {[], [], true}, &segment_step(&1, &2, min))

      hunks = Enum.reverse(hunks_rev)
      merged = if all_resolved? and hunks != [], do: Enum.join(output, "\n"), else: nil
      {:ok, %Report{merged: merged, hunks: hunks, stats: stats(hunks)}}
    end
  end

  defp segment_step({:text, lines}, {out, hs, ok}, _min), do: {out ++ lines, hs, ok}

  # An unresolved hunk forces `merged` to nil, so `out` is discarded WHOLE from here on: nothing may
  # be appended for this hunk. ⚠ ET SURTOUT PAS UNE RECONSTRUCTION DU BLOC DE MARQUEURS : elle
  # ecrirait des labels FIXES (`<<<<<<< ours`) la ou git ecrit la BRANCHE ou la revision, donc le
  # jour ou quelqu'un consommerait ce `out`, un merge partiel expedierait des fichiers dont les
  # marqueurs ont perdu LES NOMS PAR LESQUELS UN HUMAIN RESOUT.
  defp segment_step({:conflict, raw}, {out, hs, ok}, min) do
    hunk = Classifier.to_hunk(raw)

    case try_resolve(hunk, min) do
      {:ok, lines} -> {out ++ lines, [hunk | hs], ok}
      :unresolved -> {out, [hunk | hs], false}
    end
  end

  defp try_resolve(hunk, min) do
    if hunk.type in @writable_types and rank(hunk.confidence.label) >= rank(min) do
      case Assemble.resolve_lines(hunk) do
        {:ok, lines, _reason} -> {:ok, lines}
        :skip -> :unresolved
      end
    else
      :unresolved
    end
  end

  defp rank(label), do: Map.fetch!(@confidence_rank, label)

  # Trivial routes work; writable separately authorizes disk mutation.
  defp stats(hunks) do
    complex = Enum.count(hunks, &(&1.type == :complex))
    total = length(hunks)
    writable = Enum.count(hunks, &(&1.type in @writable_types))
    %{trivial: total - complex, complex: complex, total: total, writable: writable}
  end
end
