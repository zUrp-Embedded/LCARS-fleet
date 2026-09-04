defmodule Fleet.MCP.PodTools.Delegation.ProjectOnboard do
  @moduledoc """
  Behaviour of the project onboarding sequence — the CONTRACT of the
  `:project_onboard` runtime seam, consumed by `Fleet.MCP.PodTools.Delegation`
  (ONBOARDING channel, tool `project_create`).

  ## Why a seam at all

  `Fleet.Project` is a compile dep of this domain (`lib/fleet/mcp.ex`); the module is still
  resolved at RUNTIME (`resolved/0`: app-env + default) so a test injects a stub, and
  `Gate.conforming/2` refuses a stub that lies about the contract.

  ## Implementations

    * `Fleet.Project.Onboard` — the REAL impl (canonical default: forge repo + three faces
      `main`/`ops`/`workshop` + scaffold + push). It lives in `Fleet.Project`, which sits BELOW
      `Fleet.MCP` and does not depend on it: it CANNOT adopt this behaviour and stays DUCK-TYPED
      with a cross-reference comment; the callback type is aligned on its `@spec onboard/2`
      (`result()`).
    * Test stub `Fleet.MCP.PodToolsTest.StubOnboard` — same app → adopts the
      behaviour (the compiler checks conformance).
  """

  @doc """
  Onboards the project `name` (kebab-case slug). `opts` consumed by the real default:
  `:org`, `:description`, `:pitch` (cf. `Fleet.Project.Onboard.onboard/2`).
  The result MUST carry the 4 keys — `Portfolio` pattern-matches
  `%{repo: _, project_dir: _, work_dir: _, doc_dir: _}` strictly. ONE KEY PER FACE: a wire that
  announces two of the three trees it just created leaves a caller unable to name the third.
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
  `Portfolio` pattern-matches
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
  OPENS (relaunches) a project ALREADY on the machine — the third portfolio verb: no forge/disk
  write, ensures the project's per-project architect. Same 4 return
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
  the anti-work safety guard (a DELIBERATE end-of-life delete). The result shape is
  `Fleet.Project.Onboard.delete_result/0` — declared ONCE on the default implementation's side, so
  the `@spec` there and this `@callback` cannot drift apart. `Portfolio` relays `repo`, `forge`,
  `architect`, `workers_killed` and `local` on the wire.
  """
  @callback delete_project(full_name :: String.t(), opts :: keyword()) ::
              {:ok, Fleet.Project.Onboard.delete_result()} | {:error, term()}

  @doc """
  ADOPTS a project living on DISK but not on the forge (BL-6-32) — the inverse of `import/2`:
  publishes the existing local faces (empty org repo, labels seeded, origin set, main and the
  writer faces pushed, protection, architect). `name` = the dirs' basename; `opts` carries `:org`
  (the catalogue, required) and may relay the criticality declaration (same keys as `onboard/2`).
  The local content is never scaffolded over. Same 4 return keys as `onboard/2` (+ `architect`).
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
  standard import leg. One-way — the external origin is left behind. Same 4 return keys as
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
  The DEPOSIT candidates of a human: the repos in their personal space that no catalogue org
  already carries under the same name.

  The counterpart of `import_deposit/3` on the discovery side, and it needs no registry because
  THE LOCATION IS THE STATE: outside every catalogue org = a candidate, inside one = enrolled.
  Fail-loud on an unreachable org — a candidate list that is too WIDE offers to import what is
  already in.
  """
  @callback deposit_candidates(human :: String.t(), opts :: keyword()) ::
              {:ok, [String.t()]} | {:error, term()}

  @doc """
  IMPORTS a repo DEPOSITED by a human in their personal space (`<login>/<name>`) into a catalogue
  org — the third door, and the one the other two refuse by construction.

  `import/2` only takes repos ALREADY in a catalogue org, so it filters nothing and does not need
  to. `import_external/3` demands `https` plus a host from its allowlist, and our forge is `http`:
  it would refuse on the SCHEME. That guard bounds "from which FOREIGN host do we clone", and a
  personal repo on our own forge is not a foreign host — it is a foreign PROVENANCE.

  So the adoption frontier is not "our forge / an external forge" but **"inside a catalogue org /
  outside one"**: anything coming from a personal space goes through the gate, even deposited by a
  trusted human on our own forge. The transport does not change the provenance. The source repo is
  NOT consumed — the import takes a copy and leaves the original with its owner.
  """
  @callback import_deposit(source :: String.t(), catalogue :: String.t(), opts :: keyword()) ::
              {:ok, map()} | {:error, term()}

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
  `.lcars.json` on `main` through a scoped protection lift, protection re-sized on the new
  card's jury. `opts`: `:workflow_map` (required), `:justification` (required — the revision's
  WHY, committed), `:max_fan` (optional), `:revised_by` (the acting role).
  Result carries `repo`/`card`/`previous_card`/`outcome` (`:revised` | `:unchanged`).
  """
  @callback revise_card(full_name :: String.t(), opts :: keyword()) ::
              {:ok, map()} | {:error, term()}

  @doc """
  RÉÉCRIT le rail CI d'un projet sur `main` depuis le template livré — la sortie de secours quand
  un `ci.yml` cassé empêche toute PR de fusionner (le plancher `CI / *` de `protect_main` exige un
  statut que le rail ne produit plus, et les humains sont en `read` sur la forge). `opts` :
  `:justification` (requise), `:reset_by` (le rôle qui agit). Résultat : `repo`/`outcome`
  (`:reset` | `:unchanged`)/`files`.
  """
  @callback reset_ci_rail(full_name :: String.t(), opts :: keyword()) ::
              {:ok, map()} | {:error, term()}

  # Canonical default: the real onboarding sequence, `Fleet.Project` side. Set HERE once.
  @default_onboard Fleet.Project.Onboard

  @doc """
  Resolved onboarding sequence: config `:lcars_fleet, :mcp_project_onboard` otherwise the
  canonical default `Fleet.Project.Onboard`. SINGLE SOURCE of the default.
  """
  @spec resolved() :: module()
  def resolved, do: Application.get_env(:lcars_fleet, :mcp_project_onboard, @default_onboard)
end
