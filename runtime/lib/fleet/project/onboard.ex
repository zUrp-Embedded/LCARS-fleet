defmodule Fleet.Project.Onboard do
  @moduledoc """
  Project lifecycle facade: one forge repository and three local repositories.

  * `main`: deliverables, including shipped documentation.
  * `ops`: runtime records (briefs, verdicts, provenance).
  * `workshop`: planning and working material that does not ship.

  Writer faces own their gitdir: linked worktrees would require writes under a
  parent repository mounted read-only by pods. Mount access is set by cap-profiles.

  The implementations live in the Onboard submodules; their public docs describe
  creation, import, convergence and compensation. Scaffold commits use the system
  author and runtime Git committer configuration, which does not identify the requester.

  This is the default implementation of `Fleet.MCP.PodTools.Delegation.ProjectOnboard`.
  Keep its callbacks and result types aligned. Project cannot adopt that behaviour
  directly because the compile dependency on MCP would violate the domain boundary.
  """

  alias Fleet.Project.Roles

  alias Fleet.Project.Onboard.Adopt
  alias Fleet.Project.Onboard.Card
  alias Fleet.Project.Onboard.Create
  alias Fleet.Project.Onboard.Faces
  alias Fleet.Project.Onboard.Import
  alias Fleet.Project.Onboard.Lifecycle
  alias Fleet.Project.Onboard.Repo
  alias Fleet.Project.Onboard.Scaffold

  require Logger

  @type result :: %{
          :repo => String.t(),
          :project_dir => Path.t(),
          :work_dir => Path.t(),
          :doc_dir => Path.t(),
          # Architect callback outcome: up, deferred or failed.
          :architect => map(),
          # Present when existing state passes the convergence checks; architect ensure still runs.
          optional(:idempotent) => true,
          # Posée par `import_deposit/3` seul : la source personnelle (`<login>/<name>`) d'où la
          # copie a été prise — le dépôt d'origine n'est pas consommé, et le fil rend `from`.
          optional(:from) => String.t()
        }

  @type close_result :: %{
          :repo => String.t(),
          :outcome => :closed | :already_closed,
          # Best-effort stop: `:stopped` | `:none` (no architect was up) | `:error` (spawner hiccup).
          :architect => :stopped | :none | :error,
          # The parked marker issue — only when THIS call posted it (`:closed`).
          optional(:marker_issue) => pos_integer()
        }

  @type revise_result :: %{
          :repo => String.t(),
          :card => String.t(),
          :previous_card => String.t() | nil,
          :outcome => :revised | :unchanged,
          # Both only when the revision was pushed (`:revised`).
          optional(:jury_delta) => term(),
          optional(:protection) => term()
        }

  @type reset_ci_result :: %{
          :repo => String.t(),
          :outcome => :reset | :unchanged,
          :files => [String.t()],
          # Only when the rail was pushed (`:reset`): the protection restore outcome, as a string.
          optional(:protection) => String.t()
        }

  # Result types are shared with the MCP behaviour; keep all returned wire fields explicit.
  @type delete_result :: %{
          :repo => String.t(),
          # `:deleted` | `:absent` (the forge had no such repo — the local proof still runs).
          :forge => :deleted | :absent,
          # `:stopped` | `:none` | `:error` | `:skipped_identity` (no local face was proven ours).
          :architect => :stopped | :none | :error | :skipped_identity,
          # Workers swept BEFORE the faces go — reported, because a deletion that cost work in
          # flight must not read as free.
          :workers_killed => non_neg_integer(),
          :project_dir => Path.t(),
          :work_dir => Path.t(),
          :doc_dir => Path.t(),
          # One verdict per face: `:removed` | `:absent` | `:kept_identity_unproven` |
          # `:removal_incomplete`.
          :local => %{project: atom(), ops: atom(), workshop: atom()}
        }

  # Re-export entry points named outside this family: MCP callbacks, domain seams and shell evals.
  # Missing delegates can compile but fail Gate.conforming at runtime. Helper-only APIs stay local.

  @spec onboard(String.t(), keyword()) :: {:ok, result()} | {:error, term()}
  defdelegate onboard(name, opts \\ []), to: Create

  @spec import(String.t(), keyword()) :: {:ok, result()} | {:error, term()}
  defdelegate import(full_name, opts \\ []), to: Create

  @spec open(String.t(), keyword()) :: {:ok, result()} | {:error, term()}
  defdelegate open(full_name, opts \\ []), to: Lifecycle

  @spec list_projects(keyword()) :: {:ok, [map()]} | {:error, term()}
  defdelegate list_projects(opts \\ []), to: Lifecycle

  @spec list_stoppable_issues(String.t(), keyword()) :: {:ok, [map()]} | {:error, term()}
  defdelegate list_stoppable_issues(full_name, opts \\ []), to: Lifecycle

  @spec close_project(String.t(), keyword()) :: {:ok, close_result()} | {:error, term()}
  defdelegate close_project(full_name, opts \\ []), to: Lifecycle

  @spec delete_project(String.t(), keyword()) :: {:ok, delete_result()} | {:error, term()}
  defdelegate delete_project(full_name, opts \\ []), to: Lifecycle

  @spec adopt_project(String.t(), keyword()) :: {:ok, result()} | {:error, term()}
  defdelegate adopt_project(name, opts \\ []), to: Adopt

  @spec import_external(String.t(), String.t(), keyword()) :: {:ok, result()} | {:error, term()}
  defdelegate import_external(url, name, opts \\ []), to: Import

  @spec deposit_candidates(String.t(), keyword()) :: {:ok, [map()]} | {:error, term()}
  defdelegate deposit_candidates(human, opts \\ []), to: Import

  @spec import_deposit(String.t(), String.t(), keyword()) :: {:ok, result()} | {:error, term()}
  defdelegate import_deposit(source, catalogue, opts \\ []), to: Import

  # Shell eval strings bypass compiler checks; runtime.eval_doors_resolve guards these addresses.
  @spec eval_migrate(String.t(), String.t()) :: no_return()
  defdelegate eval_migrate(full_name, catalogue), to: Fleet.Project.Onboard.Migration

  @spec eval_reconcile(atom()) :: no_return()
  defdelegate eval_reconcile(mode), to: Fleet.Project.Onboard.Migration

  # Pilot's seam uses this address; re-exporting avoids exposing the Migration submodule.
  @spec reconcile_main_protection(String.t(), keyword()) :: :ok | {:error, term()}
  defdelegate reconcile_main_protection(repo, opts \\ []), to: Fleet.Project.Onboard.Migration

  @spec revise_card(String.t(), keyword()) :: {:ok, revise_result()} | {:error, term()}
  defdelegate revise_card(full_name, opts \\ []), to: Card

  @spec reset_ci_rail(String.t(), keyword()) :: {:ok, reset_ci_result()} | {:error, term()}
  defdelegate reset_ci_rail(full_name, opts \\ []), to: Card

  @doc false
  @spec onboard_result(String.t(), map(), keyword()) :: map()
  def onboard_result(full_name, dirs, opts) do
    %{
      repo: full_name,
      project_dir: dirs.code,
      work_dir: dirs.ops,
      doc_dir: dirs.workshop,
      architect: ensure_architect(full_name, opts)
    }
  end

  # Deferred is reported only when the callback returns it (e.g. eval without supervisors).
  # This function neither schedules a retry nor catches callback exceptions.
  @doc false
  @spec ensure_architect(String.t(), keyword()) :: map()
  def ensure_architect(repo, opts) do
    ensure = Keyword.get(opts, :ensure_architect, &Fleet.Project.Architect.ensure/2)

    case ensure.(repo, opts) do
      {:ok, pod_id} -> %{status: "up", pod_id: pod_id}
      {:deferred, reason} -> %{status: "deferred", reason: reason}
      {:error, reason} -> %{status: "failed", reason: inspect(reason)}
    end
  end

  @doc """
  Installed catalogue names, used as project forge orgs.

  Exposed through Project so MCP callers need not depend on Catalogue.
  """
  @spec installed_orgs() :: [String.t()]
  def installed_orgs, do: Fleet.Catalogue.installed_names()

  @doc false
  # Shared local admission: installed catalogue, name and explicit card validation.
  # Each entry point resolves its org before calling this; forge I/O belongs after admission.
  @spec admit(String.t(), String.t(), keyword()) :: :ok | {:error, term()}
  def admit(org, name, opts) when is_binary(org) and is_binary(name) do
    with :ok <- require_installed(org),
         :ok <- validate_name(name) do
      Fleet.Project.Declaration.refute_unloadable_card("#{org}/#{name}", opts)
    end
  end

  # Creation requires an explicit org; source-based verbs derive it from their source.
  @doc false
  @spec required_org(keyword()) :: {:ok, String.t()} | {:error, term()}
  def required_org(opts) do
    case Keyword.get(opts, :org) do
      org when is_binary(org) and org != "" -> {:ok, org}
      _ -> {:error, {:catalogue_required, installed_orgs()}}
    end
  end

  @doc """
  Shared catalogue refusal for local guards and MCP callers.

  The third tuple element is a guidance string containing the installed inventory,
  consistently a string rather than a list at some call sites.
  """
  @spec catalogue_not_installed(String.t()) ::
          {:error, {:catalogue_not_installed, String.t(), String.t()}}
  def catalogue_not_installed(name) do
    installed = installed_orgs()

    {:error,
     {:catalogue_not_installed, name,
      "the catalogue '#{name}' is not installed on this container (installed: " <>
        "#{Enum.join(installed, ", ")}). A project outside an installed catalogue is INVISIBLE — " <>
        "the poller only discovers on installed orgs. An admin installs it, inside the container: " <>
        "`lcars catalogue install #{name}`."}}
  end

  @doc false
  @spec require_installed(String.t()) :: :ok | {:error, term()}
  def require_installed(name) do
    if name in installed_orgs(), do: :ok, else: catalogue_not_installed(name)
  end

  # Import retains the pre-existing repository. Compensation tracks newly published writer
  # branches only; it does not restore arbitrary remote state such as protection rules.
  @doc false
  @spec finish_import(String.t(), map(), String.t(), keyword()) ::
          {:ok, map()} | {:error, term()}
  def finish_import(full_name, dirs, name, opts) do
    with {:ok, url} <- Repo.repo_url(full_name, opts),
         :ok <- Faces.clone_main(url, dirs.code) do
      case Faces.ensure_writer_faces(full_name, url, dirs, name, opts) do
        {:ok, published} -> lock_and_announce(full_name, dirs, published, opts)
        {:error, reason, published} -> Faces.undo_published(full_name, published, reason, opts)
      end
    end
  end

  @doc false
  @spec lock_and_announce(String.t(), map(), [String.t()], keyword()) ::
          {:ok, map()} | {:error, term()}
  def lock_and_announce(full_name, dirs, published, opts) do
    case Faces.lock_main(full_name, opts) do
      :ok ->
        Logger.info(
          "ProjectOnboard: #{full_name} imported — main=#{dirs.code}, " <>
            "#{Fleet.Layout.ops_branch()}=#{dirs.ops}, #{Fleet.Layout.workshop_branch()}=#{dirs.workshop}"
        )

        {:ok, onboard_result(full_name, dirs, opts)}

      {:error, reason} ->
        Faces.undo_published(full_name, published, reason, opts)
    end
  end

  @doc false
  @spec with_ci_stance(String.t(), keyword()) :: keyword()
  def with_ci_stance(repo, opts),
    do: Keyword.put_new(opts, :ci_stance, ci_stance(repo, opts))

  @doc false
  @spec ci_stance(String.t(), keyword()) :: atom()
  def ci_stance(repo, opts) do
    case Keyword.get(opts, :workflow_map) do
      card when is_binary(card) and card != "" ->
        loader_opts =
          case Keyword.take(opts, [:workflow_maps_root]) do
            [] -> Fleet.Workflow.Loader.card_opts_for_repo(repo)
            given -> given
          end

        try do
          Roles.ci(Fleet.Workflow.Loader.load!(card, loader_opts))
        rescue
          _ -> :required
        end

      _ ->
        :required
    end
  end

  @doc false
  @spec ensure_ci_workflows(String.t(), String.t(), keyword(), String.t()) ::
          :ok | {:error, term()}
  def ensure_ci_workflows(proj_dir, name, opts, msg) do
    case Scaffold.ci_workflows(proj_dir, name, opts) do
      {:ok, []} ->
        :ok

      {:ok, added} ->
        Logger.info(
          "ProjectOnboard: rail CI pose sur un depot importe — #{Enum.join(added, ", ")}"
        )

        Faces.commit(proj_dir, msg)

      {:error, _} = err ->
        err
    end
  end

  # Existing declarations are kept without validation here. Missing ones are written and
  # committed before the caller's main push, so the forge receives the card with the project.
  @doc false
  @spec ensure_declaration(String.t(), String.t(), keyword(), String.t()) ::
          :ok | {:error, term()}
  def ensure_declaration(
        proj_dir,
        full_name,
        opts,
        msg \\ "chore(adopt): déclaration de criticité (.lcars.json)"
      ) do
    if File.exists?(Path.join(proj_dir, Fleet.Layout.project_declaration_file())) do
      :ok
    else
      with :ok <- write_declaration(proj_dir, full_name, opts) do
        Faces.commit(proj_dir, msg)
      end
    end
  end

  # Require the repository positionally so declaration lookup uses the project's catalogue.
  # Merge repo last: revision_write_opts rebuilds options and would discard an earlier insertion.
  @doc false
  @spec write_declaration(String.t(), String.t(), keyword()) :: :ok | {:error, term()}
  def write_declaration(proj_dir, full_name, opts) do
    Fleet.Project.Declaration.write(proj_dir, Keyword.put(opts, :repo, full_name))
  end

  @doc false
  @spec require_on_machine(String.t(), String.t()) :: :ok | {:error, term()}
  def require_on_machine(full_name, proj_dir) do
    if File.dir?(proj_dir), do: :ok, else: {:error, {:not_on_machine, full_name}}
  end

  # LayoutTest reads this same admission pattern to check slug preservation.
  @name_re ~r/^[a-z0-9][a-z0-9-]*[a-z0-9]$/

  @doc false
  @spec name_charset() :: Regex.t()
  def name_charset, do: @name_re

  @doc false
  @spec validate_name(String.t()) :: :ok | {:error, term()}
  def validate_name(name) do
    if Regex.match?(@name_re, name),
      do: :ok,
      else: {:error, {:invalid_name, name}}
  end
end
