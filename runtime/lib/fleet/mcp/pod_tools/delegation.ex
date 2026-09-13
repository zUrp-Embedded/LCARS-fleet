defmodule Fleet.MCP.PodTools.Delegation do
  @moduledoc """
  Domain family behind PodTools dispatch; this module has no functions.
  Tool enumeration and its AST contracts live in PodTools' deftool declarations.

  Gate resolves roles from channel state and checks catalogue capabilities:
  require_onboarder admits :onboarder for portfolio operations; require_architect
  admits :project_delegate and requires a repo binding. Their role populations
  are disjoint in the bundled catalogue, not by a rule in Gate. Missing identity,
  capability or required binding is refused. Socket visibility/admission is separate.
  roles.capabilities_exercisable checks that declared capabilities have tools.

  Module responsibilities:
    * Issues and IssuePR: create/read tickets and resolve their PR state.
    * Dependencies and Retirement: edges, replacement and retirement.
    * Portfolio: project lifecycle and cards; Deposits: imports and external publication.
    * Escalations, Scratchpad and Toolchain: arbitration inbox, notes and tooling requests.
    * Gate, Render and Workshop: authorization/seam checks, result rendering and workshop paths.

  Fleet.Forge and Fleet.Project are compile dependencies; runtime seams enable injection.
  Gate.conforming checks callback exports, not implementation semantics or return values.
  Four behaviours (ForgeClient, EscalationForge, DependencyForge, ForgeWriter) share
  :mcp_forge_client, default Fleet.Forge.Client, resolved through ForgeClient.resolved/0.
  :mcp_project_onboard defaults to Fleet.Project.Onboard and uses ProjectOnboard's contract.
  PodResolver owns :mcp_pod_resolver and its Spawner default. :mcp_pod_reaper is an
  upward seam to Pilot, which MCP cannot reference directly.

  Onboarding catalogue/org is an explicit caller choice (Gate.resolve_org), not
  inferred from a card name; the poller discovers installed catalogue organizations.
  """
end
