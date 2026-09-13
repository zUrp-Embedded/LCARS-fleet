defmodule Fleet.MCP.PodTools.Delegation.ProjectOnboard do
  @moduledoc """
  Consumer-owned callbacks for :mcp_project_onboard, default Fleet.Project.Onboard.
  Runtime injection supports stubs; Gate checks callback exports, not result shapes.
  The lower Project domain cannot adopt this MCP behaviour without an upward compile
  dependency, so default-export tests check that side of the contract.

  Creation/import/open/adoption consumers strictly match repo, project_dir, work_dir
  and doc_dir. Optional architect details are rendered when present; each face path
  must reach the caller. The implementation owns compensation and partial outcomes.
  """

  @doc """
  Creates a slug-named project. Options include org, description, pitch,
  workflow_map, justification and onboarded_by; see Onboard for validation/defaults.
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
  Imports an existing catalogue-org repo without scaffolding its main content.
  Returns the four identity/face keys described above.
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
  Reopens an existing local project, clears its parked marker and ensures its architect.
  May write forge/runtime state. Missing local directories yield not_on_machine;
  opening does not replace the create/import path.
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
  Deletes through Onboard's lifecycle operation; force is required by the default.
  The shared delete_result type carries forge, architect, worker and local outcomes.
  MCP also has a separate deployment switch checked before calling this seam.
  """
  @callback delete_project(full_name :: String.t(), opts :: keyword()) ::
              {:ok, Fleet.Project.Onboard.delete_result()} | {:error, term()}

  @doc """
  Publishes existing local faces into a new forge repo using an explicit org and
  optional card declaration. It does not scaffold over local content; validation,
  publication order and compensation belong to Onboard.Adopt.
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
  Imports external history through URL/adoption checks and default-branch normalization.
  Foreign .claude directories and rejected CLAUDE.md content are refused; ambiguous
  master/main history can fail with branch_collision. Source repository is not consumed.
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
  Lists personal repos whose names are absent from installed catalogue orgs.
  Unreadable org state is an error, not permission to offer already-enrolled names.
  """
  @callback deposit_candidates(human :: String.t(), opts :: keyword()) ::
              {:ok, [String.t()]} | {:error, term()}

  @doc """
  Copies a personal-space repo on the internal forge into a catalogue org.
  Provenance still requires adoption checks even on the same host; standard import
  expects an existing catalogue-org repo, while external import applies an HTTPS host gate.
  Keep the source with its owner.
  """
  @callback import_deposit(source :: String.t(), catalogue :: String.t(), opts :: keyword()) ::
              {:ok, Fleet.Project.Onboard.result()} | {:error, term()}

  @doc """
  Parks a project through a forge marker and attempts to stop its architect.
  Poller admission respects the marker; this does not cancel work already in flight.
  Open clears the marker; a human can also close it to unpark. No face deletion.
  """
  @callback close_project(full_name :: String.t(), opts :: keyword()) ::
              {:ok, Fleet.Project.Onboard.close_result()} | {:error, term()}

  @doc """
  Lists local projects with declared card information and forge parked state.
  An unreadable parked state is unknown plus state_error, not silently open.
  """
  @callback list_projects(opts :: keyword()) :: {:ok, [map()]} | {:error, term()}

  @doc """
  Returns human-assigned open issue numbers eligible for emergency retirement.
  Project owns this composition and excludes parked markers: closing one would unpark.
  """
  @callback list_stoppable_issues(full_name :: String.t(), opts :: keyword()) ::
              {:ok, [integer()]} | {:error, term()}

  @doc """
  Revises main's card declaration with scoped protection changes. workflow_map and
  justification are required; max_fan is optional, revised_by records the acting role.
  Existing engraved routes remain unchanged. Result carries previous/current cards,
  outcome and optional jury/protection changes; see Onboard.Card for partial failures.
  """
  @callback revise_card(full_name :: String.t(), opts :: keyword()) ::
              {:ok, Fleet.Project.Onboard.revise_result()} | {:error, term()}

  @doc """
  Restores shipped CI files on main so broken CI can be repaired outside a blocked PR.
  Existing PR branches retain their files. The default checks justification but does
  not record it, and ignores reset_by. Returns reset/unchanged and file/protection details.
  """
  @callback reset_ci_rail(full_name :: String.t(), opts :: keyword()) ::
              {:ok, Fleet.Project.Onboard.reset_ci_result()} | {:error, term()}

  # Canonical default: the real onboarding sequence, `Fleet.Project` side. Set HERE once.
  @default_onboard Fleet.Project.Onboard

  @doc """
  Returns :mcp_project_onboard or the canonical Fleet.Project.Onboard default.
  """
  @spec resolved() :: module()
  def resolved, do: Application.get_env(:lcars_fleet, :mcp_project_onboard, @default_onboard)
end
