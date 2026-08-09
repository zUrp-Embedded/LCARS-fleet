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

    * `Fleet.Project.Onboard` — the REAL impl (canonical default: forge repo +
      three faces `main`/`ops`/`workshop` + scaffold + push). It lives in
      `fleet_pilot`, which does NOT depend on `fleet_mcp`: it CANNOT adopt this
      behaviour and stays DUCK-TYPED with a cross-reference comment; the callback
      type is aligned on its `@spec onboard/2` (`result()`).
    * Test stub `Fleet.MCP.PodToolsTest.StubOnboard` — same app → adopts the
      behaviour (the compiler checks conformance).
  """

  @doc """
  Onboards the project `name` (kebab-case slug). `opts` consumed by the real default:
  `:org`, `:description`, `:pitch` (cf. `Fleet.Project.Onboard.onboard/2`).
  The result MUST carry the 4 keys — `Delegation.do_create_project/2` pattern-matches
  `%{repo: _, project_dir: _, work_dir: _, doc_dir: _}` strictly. ONE KEY PER FACE, and the fourth
  was missing while the runtime already produced it: the wire announced two of the three trees it
  had just created, so a caller could not name the doc face at all.
  """
  @callback onboard(name :: String.t(), opts :: keyword()) ::
              {:ok,
               %{
                 repo: String.t(),
                 project_dir: Path.t(),
                 work_dir: Path.t(),
                 doc_dir: Path.t()
               }}
              | {:error, term()}

  @doc """
  Imports an EXISTING repo `full_name` (`"owner/name"`) into the agent machine — WITHOUT creating
  nor scaffolding `main` (content intact). Same 4 return keys as `onboard/2`:
  `Delegation.do_import_project/2` pattern-matches
  `%{repo: _, project_dir: _, work_dir: _, doc_dir: _}` strictly, identical to the onboarding
  channel.
  """
  @callback import(full_name :: String.t(), opts :: keyword()) ::
              {:ok,
               %{
                 repo: String.t(),
                 project_dir: Path.t(),
                 work_dir: Path.t(),
                 doc_dir: Path.t()
               }}
              | {:error, term()}

  @doc """
  OPENS (relaunches) a project ALREADY on the machine — the third portfolio verb (reorg
  2026-07-19): no forge/disk write, ensures the project's per-project architect. Same 4 return
  keys as `onboard/2` (+ `architect`, the ensure outcome). Dirs absent →
  `{:error, {:not_on_machine, _}}` (open never creates — that is `create`/`import`'s job).
  """
  @callback open(full_name :: String.t(), opts :: keyword()) ::
              {:ok,
               %{
                 repo: String.t(),
                 project_dir: Path.t(),
                 work_dir: Path.t(),
                 doc_dir: Path.t()
               }}
              | {:error, term()}

  @doc """
  DELETES a project — general teardown (architect pod + forge repo + the three faces). `opts[:force]` bypasses
  the anti-work safety guard (a DELIBERATE end-of-life delete). Result carries `repo` (+ `forge`/
  `architect` status keys); `Delegation.do_delete_project/2` reads `%{repo: _}`.
  """
  @callback delete_project(full_name :: String.t(), opts :: keyword()) ::
              {:ok, map()} | {:error, term()}

  @doc """
  ADOPTS a project living on DISK but not on the forge (BL-6-32) — the inverse of `import/2`:
  publishes the existing local pair (empty org repo, labels seeded, origin set, main + ops
  pushed, protection, architect). `name` = the dirs' basename; `opts` may relay the criticality
  declaration (same keys as `onboard/2`). The local content is never scaffolded over. Same 3
  return keys as `onboard/2` (+ `architect`).
  """
  @callback adopt_project(name :: String.t(), opts :: keyword()) ::
              {:ok,
               %{
                 repo: String.t(),
                 project_dir: Path.t(),
                 work_dir: Path.t(),
                 doc_dir: Path.t()
               }}
              | {:error, term()}

  @doc """
  IMPORTS a repo from an EXTERNAL forge (GitHub/GitLab — BL-6-31): repatriates the full
  history into a system scratch, runs the ADOPTION GATE (foreign `.claude/` refused en bloc,
  every `CLAUDE.md` through the reception filter), normalizes the default branch to `main`
  (half-migrated master+main → named refusal), creates the org repo and hands over to the
  standard import leg. One-way — the external origin is left behind. Same 3 return keys as
  `onboard/2` (+ `architect`).
  """
  @callback import_external(url :: String.t(), name :: String.t(), opts :: keyword()) ::
              {:ok,
               %{
                 repo: String.t(),
                 project_dir: Path.t(),
                 work_dir: Path.t(),
                 doc_dir: Path.t()
               }}
              | {:error, term()}

  @doc """
  CLOSES a project (BL-6-30) — stops the fleet ON it, disk and forge intact (≠ delete: nothing
  destroyed). The closed state is a forge object (open `[lcars-parked]` marker issue) the poller
  respects; the running brick finishes, the next one never starts; the architect stops
  (best-effort). Reopen via `open/2` (which also clears the marker) or the human closing the
  marker in the UI. Result carries `repo`/`outcome` (`:closed` | `:already_closed`) +
  `marker_issue`/`architect`.
  """
  @callback close_project(full_name :: String.t(), opts :: keyword()) ::
              {:ok, map()} | {:error, term()}

  @doc """
  LISTS the projects on this box (pure read). Per project: name, repo, the DECLARED card and level
  (never the effective fallback — an undeclared project must stay distinguishable from one that
  chose the default), and the parked state read from the forge. A state that cannot be read is
  `"unknown"` plus `state_error`, never a silent `"open"`.
  """
  @callback list_projects(opts :: keyword()) :: {:ok, [map()]} | {:error, term()}

  @doc """
  The open ticket numbers of a repo that the fleet would act on — the scope an emergency stop
  closes. Composed on the pilot side because it joins two facts of that domain: the poller's own
  scoping (issues assigned to the human owner) and the parked-marker vocabulary, which MCP cannot
  even reference (upward boundary). The PARKED MARKER is excluded: closing it would unpark the
  project.
  """
  @callback list_stoppable_issues(full_name :: String.t(), opts :: keyword()) ::
              {:ok, [integer()]} | {:error, term()}

  @doc """
  REVISES an EXISTING project's validation-card declaration (BL-6-29) — commits the new
  `intensity.json` on `main` through a scoped protection lift, protection re-sized on the new
  card's jury. `opts`: `:workflow_map` (required), `:justification` (required — the revision's
  WHY, committed), `:intensity_level`/`:nature` (optional), `:revised_by` (the acting role).
  Result carries `repo`/`card`/`previous_card`/`outcome` (`:revised` | `:unchanged`).
  """
  @callback revise_card(full_name :: String.t(), opts :: keyword()) ::
              {:ok, map()} | {:error, term()}

  # Canonical default: the real onboarding sequence on the fleet_pilot side. Literal atom
  # (not a literal remote call) → no compile-time dep. Set HERE once.
  @default_onboard Fleet.Project.Onboard

  @doc """
  Resolved onboarding sequence: config `:fleet_mcp, :project_onboard` otherwise the
  canonical default `Fleet.Project.Onboard`. SINGLE SOURCE of the default.
  """
  @spec resolved() :: module()
  def resolved, do: Application.get_env(:fleet_mcp, :project_onboard, @default_onboard)
end
