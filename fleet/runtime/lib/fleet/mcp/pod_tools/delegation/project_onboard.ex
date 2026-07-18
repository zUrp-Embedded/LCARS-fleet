defmodule Fleet.MCP.PodTools.Delegation.ProjectOnboard do
  @moduledoc """
  Behaviour of the project onboarding sequence — the CONTRACT of the
  `:project_onboard` runtime seam, consumed by `Fleet.MCP.PodTools.Delegation`
  (ONBOARDING channel, tool `create_project`).

  ## Why a RUNTIME seam (and not a compile dep)

  `fleet_pilot` sits ABOVE `fleet_mcp` in the boundary ladder: a compile dep
  `fleet_mcp → fleet_pilot` would be UPWARD, forbidden (the boundary compiler
  would reject it). The module is resolved at
  RUNTIME (`resolved/0`: app-env + default as a literal atom → no compile-time
  dep, no cycle). Assumed UPWARD runtime seam (mcp → pilot).

  ## Implementations

    * `Fleet.Pilot.ProjectOnboard` — the REAL impl (canonical default: forge repo +
      dual-worktree `main`/`work/ops` + scaffold + push). It lives in
      `fleet_pilot`, which does NOT depend on `fleet_mcp`: it CANNOT adopt this
      behaviour and stays DUCK-TYPED with a cross-reference comment; the callback
      type is aligned on its `@spec onboard/2` (`result()`).
    * Test stub `Fleet.MCP.PodToolsTest.StubOnboard` — same app → adopts the
      behaviour (the compiler checks conformance).

  **Last revised**: 2026-07-18
  """

  @doc """
  Onboards the project `name` (kebab-case slug). `opts` consumed by the real default:
  `:org`, `:description`, `:pitch` (cf. `Fleet.Pilot.ProjectOnboard.onboard/2`).
  The result MUST carry the 3 keys — `Delegation.do_create_project/2` pattern-matches
  `%{repo: _, project_dir: _, work_dir: _}` strictly.
  """
  @callback onboard(name :: String.t(), opts :: keyword()) ::
              {:ok, %{repo: String.t(), project_dir: Path.t(), work_dir: Path.t()}}
              | {:error, term()}

  @doc """
  Imports an EXISTING repo `full_name` (`"owner/name"`) into the agent machine — WITHOUT creating
  nor scaffolding `main` (content intact). Same 3 return keys as `onboard/2`:
  `Delegation.do_import_project/2` pattern-matches `%{repo: _, project_dir: _, work_dir: _}`
  strictly, identical to the onboarding channel.
  """
  @callback import(full_name :: String.t(), opts :: keyword()) ::
              {:ok, %{repo: String.t(), project_dir: Path.t(), work_dir: Path.t()}}
              | {:error, term()}

  # Canonical default: the real onboarding sequence on the fleet_pilot side. Literal atom
  # (not a literal remote call) → no compile-time dep. Set HERE once.
  @default_onboard Fleet.Pilot.ProjectOnboard

  @doc """
  Resolved onboarding sequence: config `:fleet_mcp, :project_onboard` otherwise the
  canonical default `Fleet.Pilot.ProjectOnboard`. SINGLE SOURCE of the default.
  """
  @spec resolved() :: module()
  def resolved, do: Application.get_env(:fleet_mcp, :project_onboard, @default_onboard)
end
