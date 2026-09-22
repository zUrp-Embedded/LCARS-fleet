defmodule Fleet.Project do
  @moduledoc """
  Project lifecycle boundary: onboarding, declarations, project roles, architect
  identity and host worktree maintenance. These imperative operations are shared
  by MCP callers and the reactive Pilot rail.

  Roles and Declaration refer to each other and remain within this boundary.
  MCP's :mcp_project_onboard override is a test seam governed by its delegation
  behaviour; ordinary calls use the declared Fleet.Project dependency.
  """

  # Keep lifecycle dependencies explicit for compile-time boundary checks.
  use Boundary,
    deps: [
      Fleet.Slug,
      Fleet.EnvParse,
      Fleet.GitRef,
      Fleet.Opts,
      Fleet.Labels,
      # The system repository address names the system org — a name no project may carry.
      Fleet.Toolchain,
      Fleet.Layout,
      Fleet.Catalogue,
      Fleet.Event,
      Fleet.SchemaCache,
      Fleet.EventRouter,
      Fleet.CapProfile,
      Fleet.Credentials,
      Fleet.Spawner,
      Fleet.Workflow,
      Fleet.Forge,
      Fleet.ReceptionFilter,
      Fleet.Conflict,
      # Release entry points share stdout/error handling with other release doors.
      Fleet.ReleaseDoor
    ],
    exports: [
      Onboard,
      Onboard.Scaffold,
      Roles,
      Declaration,
      Architect,
      WorktreeSync,
      GitOps
    ]
end
