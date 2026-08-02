defmodule Fleet.Labels do
  use Boundary, deps: [], exports: []

  @moduledoc """
  Label vocabulary of the forge-state-machine **wire-protocol**: the forge IS the state machine,
  these labels are its thread. SINGLE SOURCE.

  A foundation boundary (`deps: []`) because BOTH `Fleet.Pilot` (poller/dispatcher/completer/consumer)
  AND `Fleet.MCP` (the arch's delegation reads `stage/merged` / `lcars-awaits-arch`) must name these
  labels byte-for-byte — and MCP cannot depend upward on Pilot: the shared vocabulary lives BELOW both.

  These constants ARE NOT config: they ARE the protocol. Re-declaring one as a local `@attr` or
  literal = silent drift on a rename. Centralized here, consumed everywhere.

  Compile-time usage (preserves the constant semantics, usable in `cond`/pattern):

      @in_flight_label Fleet.Labels.in_flight()

  or runtime direct (`Fleet.Labels.awaits_arch()`).

  FOUR families, and the split that matters is scoped-vs-flat, because Gitea reads it: a name
  containing `/` is created `exclusive:true` (setting one removes the others of its scope), a flat
  name accumulates.

    * FLAT LOCKS `lcars-in-flight` / `lcars-awaits-arch` — concurrency / escalation.
    * SCOPED POSITION `wfmap/<map>` + `stage/<step>` — the workflow_map position; the state lives
      in the label and the mutex is native.
    * SCOPED GENRE `genre/ops` — an INPUT to the burn (which card gets engraved).
    * FLAT VISUAL `type:*` — decoration, `:` and not `/` so the namespace cannot be mistaken for a
      routing scope. Nothing mechanical reads it back.

  The first three MEAN something to the machine; the fourth means something only to a human. That
  asymmetry is a trap, not a detail: a wrong routing label breaks something and gets found, a wrong
  visual label breaks nothing and simply misinforms every reader (measured 2026-08-03 — a doc
  ticket wearing `type:feature`). Hence `type_for_genre/1`: the decoration is DERIVED from the
  routing decision, never posted as its own constant.

  This list said "two families" until 2026-08-03, and closed with "outside these two families, a
  label does not exist" — while `genre/ops` had been shipping for a chantier and `type:feature` was
  posted on every issue ever created. Keep it counted right: the sentence that bounds a vocabulary
  is the first thing a reader trusts and the last thing anyone updates.

  **Last revised**: 2026-08-03
  """

  @in_flight "lcars-in-flight"
  @awaits_arch "lcars-awaits-arch"
  @genre_ops "genre/ops"

  @doc "\"Pod in flight\" lock: set BEFORE the spawn (anti double-spawn), lifted at end-of-step-run."
  @spec in_flight() :: String.t()
  def in_flight, do: @in_flight

  @doc "HUMAN lock: the issue awaits an action via the arch (escalate/halt/redirect verdict)."
  @spec awaits_arch() :: String.t()
  def awaits_arch, do: @awaits_arch

  @doc """
  Genre marker of a DOCUMENTARY ticket (`genre/ops`, chantier face-projet): an INPUT to the
  workflow-map burn — present on a routeless issue, the poller engraves the ops card instead of
  the project's declared card; absent, nothing changes. Read ONCE at burn time: the engraved
  `wfmap/*` stays the only route (the forge is the state machine). Distinct namespace from
  `type:*` on purpose — those are documented visual-never-routing, and this one routes.
  """
  @spec genre_ops() :: String.t()
  def genre_ops, do: @genre_ops

  @doc """
  VISUAL type of a ticket, derived from its genre — `type:doc` for a documentary ticket
  (`genre/ops`), `type:feature` otherwise. Flat and NON-routing by construction: `:` and not `/`,
  so Gitea creates it non-exclusive and no code reads it back. It exists for the human who scans
  a list of issues and wants to know what kind of thing each one is.

  DERIVED, never posted as a constant: the genre is resolved at create time, and a visual type
  contradicting it is a lie told by the interface — a doc ticket wearing `type:feature` (measured
  2026-08-03) says "feature" to every human who reads the list, while the burn routes it to the
  ops card. One decision, one source; the label follows.
  """
  @spec type_for_genre(String.t() | nil) :: String.t()
  def type_for_genre("ops"), do: "type:doc"
  def type_for_genre(_), do: "type:feature"

  @doc "The visual types, for the seeding that must create them before anyone can wear them."
  @spec visual_types() :: [String.t()]
  def visual_types, do: ["type:feature", "type:doc"]

  # --- workflow_map position: 2 mutex label scopes (via `exclusive:true`, set PER-REPO by
  # ForgeClient.ensure_repo_label). `wfmap/<map>` = WHICH map (data, per-issue → multi-map);
  # `stage/<step>` = the CURRENT step, mobile. brief-review/build values come from the MAP (data);
  # review/merged = phases of the PR LIFECYCLE (post-map mechanism, human-only: the machine does not re-read
  # get_route on an issue in review [PR-backed → skip] nor merged [closed]).
  @stage_prefix "stage/"
  @wfmap_prefix "wfmap/"
  @stage_review "review"
  @stage_merged "merged"

  @doc "Scoped prefix of the current step (`stage/`). Scoped → exclusive (mutex)."
  @spec stage_prefix() :: String.t()
  def stage_prefix, do: @stage_prefix

  @doc "Scoped prefix of the tracked map (`wfmap/`)."
  @spec wfmap_prefix() :: String.t()
  def wfmap_prefix, do: @wfmap_prefix

  @doc "PR LIFECYCLE step: the issue enters review (deliverable PR opened). Mechanism, not a map step."
  @spec stage_review() :: String.t()
  def stage_review, do: @stage_review

  @doc "PR LIFECYCLE step: the brick is merged (terminal). Mechanism, not a map step."
  @spec stage_merged() :: String.t()
  def stage_merged, do: @stage_merged
end
