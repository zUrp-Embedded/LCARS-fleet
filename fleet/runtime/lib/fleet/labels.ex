defmodule Fleet.Labels do
  use Boundary, deps: [], exports: []

  @moduledoc """
  Label vocabulary of the forge-state-machine **wire-protocol**: the forge IS the state machine,
  these labels are its thread. SINGLE SOURCE.

  RING-0 (DR-011): the vocabulary is a shared SUBSTRATE concern — the forge protocol that BOTH `Fleet.Pilot`
  (poller/dispatcher/completer/consumer) AND `Fleet.MCP` (the arch's delegation reads `stage/merged` /
  `lcars-awaits-arch`) must name byte-for-byte. It lived under `Fleet.Pilot` and MCP could not depend upward
  on Pilot (forbidden compile edge) → MCP re-declared the literals, a silent-drift risk on a rename. Now at
  Foundation (`deps: []`), a single authority both domains DEPEND ON — the literals are gone from MCP.

  These constants ARE NOT config: they ARE the protocol. Re-declaring them as `@attr` per module = silent
  drift on a rename. Centralized here, consumed everywhere.

  Compile-time usage (preserves the constant semantics, usable in `cond`/pattern):

      @in_flight_label Fleet.Labels.in_flight()

  or runtime direct (`Fleet.Labels.awaits_arch()`).

  Two families: the FLAT LOCKS `lcars-in-flight` / `lcars-awaits-arch` (concurrency / escalation,
  unscoped), and the workflow_map POSITION as SCOPED labels `wfmap/<map>` + `stage/<step>` (WS2: the state
  lives in the label, native Gitea mutex `exclusive:true` — no longer in a route comment). `lcars-dispatched`
  (a legacy poller's lock) has been removed. Outside these families, a label does not exist.
  """

  @in_flight "lcars-in-flight"
  @awaits_arch "lcars-awaits-arch"

  @doc "\"Pod in flight\" lock: set BEFORE the spawn (anti double-spawn), lifted at end-of-step-run."
  @spec in_flight() :: String.t()
  def in_flight, do: @in_flight

  @doc "HUMAN lock: the issue awaits an action via the arch (escalate/halt/redirect verdict)."
  @spec awaits_arch() :: String.t()
  def awaits_arch, do: @awaits_arch

  # --- workflow_map position (WS2): 2 mutex label scopes (via `exclusive:true`, set PER-REPO by
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
