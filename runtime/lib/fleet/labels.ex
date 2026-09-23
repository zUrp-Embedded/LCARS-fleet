defmodule Fleet.Labels do
  use Boundary, deps: [], exports: []

  @moduledoc """
  Forge label protocol shared by Pilot and MCP through foundation. Names are protocol constants,
  not configuration. Derive consumer attributes here when compile-time values are needed:

      @in_flight_label Fleet.Labels.in_flight()

  Or call the functions directly. Families include flat locks (in-flight, arch/admin escalation),
  workflow position (wfmap/stage), destination, wait reason and visual type labels.
  type:* is presentation only, derived from destination so the UI agrees with routing.

  Forge.Client creates names containing / with exclusive: true; Gitea enforces the field,
  not the spelling alone. Labels created through other routes may lack exclusivity, and existing
  labels are not reconciled here. A colon in type:* keeps visual labels outside that convention.
  """

  @in_flight "lcars-in-flight"
  @awaits_arch "lcars-awaits-arch"
  @awaits_toolchain "lcars-awaits-toolchain"
  # Wire enum, routing clause and forge label derive from one destination token.
  @destination_workshop_token "workshop"
  @destination_workshop "destination/" <> @destination_workshop_token

  @doc "\"Pod in flight\" lock: set BEFORE the spawn (anti double-spawn), lifted at end-of-step-run."
  @spec in_flight() :: String.t()
  def in_flight, do: @in_flight

  @doc "HUMAN lock: the issue awaits an action via the arch (escalate/halt/redirect verdict)."
  @spec awaits_arch() :: String.t()
  def awaits_arch, do: @awaits_arch

  @doc """
  Admin-approval lock for toolchain requests. Keep separate from awaits_arch: the architect
  cannot approve installs, and its escalation inbox must contain actions it can handle.
  The reconciler drains merged requests for redispatch and refusals back to the project's human.
  Closure without merge must be checked separately because it does not move the branch SHA.
  """
  @spec awaits_toolchain() :: String.t()
  def awaits_toolchain, do: @awaits_toolchain

  @doc """
  Workshop destination input for a routeless issue: the poller selects the workshop card when
  burning its route. Afterwards wfmap/* owns routing; changing this marker does not reroute it.
  """
  @spec destination_workshop() :: String.t()
  def destination_workshop, do: @destination_workshop

  @doc """
  Workshop token shared by issue_create's wire enum, routing and destination label.
  """
  @spec destination_workshop_token() :: String.t()
  def destination_workshop_token, do: @destination_workshop_token

  @doc """
  Visual type derived from destination: type:workshop for workshop, type:feature otherwise.
  It informs the human and does not route work; derive it rather than posting an unrelated constant.
  """
  @spec type_for_destination(String.t() | nil) :: String.t()
  def type_for_destination(@destination_workshop_token), do: "type:workshop"
  def type_for_destination(_), do: "type:feature"

  # nil represents the fallback clause, whose visual type must also be seeded.
  @destinations [@destination_workshop_token, nil]

  @doc """
  Visual types to seed with their colour/description before use. Derived from the routing-to-type
  function so a rename cannot leave the real label lazily created with grey defaults.
  The labels.visual_types_derived contract checks destination coverage.
  """
  @spec visual_types() :: [String.t()]
  def visual_types, do: @destinations |> Enum.map(&type_for_destination/1) |> Enum.uniq()

  # wfmap names the map; stage tracks its step plus PR lifecycle states outside the map.
  @stage_prefix "stage/"
  @wfmap_prefix "wfmap/"
  @stage_review "review"
  @stage_merged "merged"
  @stage_retired "retired"

  @doc "Current-step scope prefix (stage/), created exclusive by Forge.Client."
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

  @doc """
  Closure without delivery (superseded or abandoned), explicitly distinguished from merged.
  Forge.Client.close_issue/3 names the closure kind; correctly provisioned stage labels are exclusive.
  """
  @spec stage_retired() :: String.t()
  def stage_retired, do: @stage_retired

  # Exclusivity replaces another wait when a new one is set. Callers must remove it on leaving
  # the wait entirely; setting nothing does not clear a stale label.
  @wait_prefix "wait/"

  @doc "Wait-reason scope prefix (wait/), created exclusive by Forge.Client."
  @spec wait_prefix() :: String.t()
  def wait_prefix, do: @wait_prefix

  @doc """
  Maps a dispatch skip reason to wait/*, or nil for the deliberate exclusions explained below.
  Unknown reasons raise so new states cannot silently disappear from the UI. Keep the producer/table
  coverage tests, including tuple-shaped reasons; each new nil needs a rationale.
  """
  @spec wait_for(term()) :: String.t() | nil
  def wait_for(:at_capacity), do: @wait_prefix <> "capacity"
  # Both capacity ceilings mean waiting for a seat; the skip reason retains the diagnostic detail.
  def wait_for(:role_at_capacity), do: @wait_prefix <> "capacity"
  def wait_for(:role_busy), do: @wait_prefix <> "role"

  # A failed refs/lcars/base refresh leaves the producer unready; retry before briefing on a stale base.
  def wait_for(:stale_base_unrefreshed), do: @wait_prefix <> "role"
  def wait_for(:draining), do: @wait_prefix <> "draining"
  def wait_for(:criterion_unavailable), do: @wait_prefix <> "criterion"
  def wait_for(:ci_pending), do: @wait_prefix <> "ci"
  # A declared blocker is still open: waiting for another ticket.
  def wait_for({:depends, _blocker}), do: @wait_prefix <> "depends"

  # Unreadable dependencies stop at the same gate; retain the failure detail in the skip reason.
  def wait_for({:depends_unreadable, _why}), do: @wait_prefix <> "depends"
  # CI read failures share the gate's wait label; logs/tallies distinguish the failed reads.
  def wait_for({:ci_head_unreadable, _why}), do: @wait_prefix <> "ci"
  def wait_for({:ci_unreadable, _why}), do: @wait_prefix <> "ci"
  def wait_for({:ci_red_marker_unreadable, _why}), do: @wait_prefix <> "ci"

  # An unreadable PR date also prevents the CI deadline from being evaluated.
  def wait_for({:ci_deadline_unreachable, _why}), do: @wait_prefix <> "ci"

  # Arbitration cannot start without its budget marker; wait for the role and retry next tick.
  def wait_for({:verdict_marker_unposted, _why}), do: @wait_prefix <> "role"

  # Existing lock labels already explain these states.
  def wait_for(:in_flight), do: nil
  def wait_for(:awaits_arch), do: nil
  def wait_for(:awaits_toolchain), do: nil
  # The open PR carries ongoing work, not a ticket waiting for dispatch.
  def wait_for(:pr_open), do: nil

  # Configuration failure has its own incident, not a wait label.
  def wait_for(:no_role), do: nil

  # Foreign PRs are outside fleet dispatch.
  def wait_for(:not_fleet_branch), do: nil

  # Onboarding is a transition; merged/cancelled are terminal.
  def wait_for(:onboarded), do: nil
  def wait_for(:merged), do: nil
  def wait_for(:retired), do: nil
  def wait_for({:cancelled, _pr}), do: nil

  # These paths already post the awaits-arch escalation label; the issue itself is not resolved.
  def wait_for({:rework_exhausted_escalated, _pr}), do: nil
  def wait_for({:merge_blocked_escalated, _pr}), do: nil
  def wait_for({:publish_brake_escalated, _pr}), do: nil

  # The PR's ci-red marker records the failure; triggered rework is not waiting for a CI verdict.
  def wait_for({:ci_red_already_signalled, _sha}), do: nil

  # Provenance failure already has a forge trace.
  def wait_for({:head_read_failed, _why}), do: nil

  # Draft is a human decision, not fleet readiness. Both shapes stay silent pending user arbitration.
  def wait_for(:draft), do: nil
  def wait_for({:draft, _pr}), do: nil

  def wait_for(reason) do
    raise ArgumentError,
          "Fleet.Labels.wait_for/1: reason #{inspect(reason)} is absent from the BL-6-48 table. " <>
            "Add it with a label OR with an explicit nil AND its argument — a silent fallthrough " <>
            "is how a reason is born mute."
  end
end
