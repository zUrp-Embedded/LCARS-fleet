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

  Two families: the FLAT LOCKS `lcars-in-flight` / `lcars-awaits-arch` (concurrency / escalation,
  unscoped), and the workflow_map POSITION as SCOPED labels `wfmap/<map>` + `stage/<step>` (the state
  lives in the label, native Gitea mutex `exclusive:true`). Outside these two families, a label
  does not exist.

  **Last revised**: 2026-07-18
  """

  @in_flight "lcars-in-flight"
  @awaits_arch "lcars-awaits-arch"

  @doc "\"Pod in flight\" lock: set BEFORE the spawn (anti double-spawn), lifted at end-of-step-run."
  @spec in_flight() :: String.t()
  def in_flight, do: @in_flight

  @doc "HUMAN lock: the issue awaits an action via the arch (escalate/halt/redirect verdict)."
  @spec awaits_arch() :: String.t()
  def awaits_arch, do: @awaits_arch

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
