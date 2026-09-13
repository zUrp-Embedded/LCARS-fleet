defmodule Fleet.Project.Onboard.Create do
  @moduledoc """
  Creates a new forge project or imports an existing one.

  Creation scaffolds main and both writer faces. Import clones main without adding a
  declaration or CI files, then creates/clones writer faces and reapplies main protection.
  Existing local faces may return an idempotent result when convergence checks pass.
  """

  alias Fleet.Forge.WriteSpacing
  alias Fleet.Layout
  alias Fleet.Project.Onboard
  alias Fleet.Project.Onboard.Faces
  alias Fleet.Project.Onboard.Refute
  alias Fleet.Project.Onboard.Repo
  alias Fleet.Project.Onboard.Scaffold

  require Logger

  @doc """
  Creates a project using the installed catalogue's templates.

  Requires `:org` (the catalogue name). `:description` and `:pitch` supply scaffold text;
  `:code_root`, `:ops_root`, `:workshop_root` override Layout roots.
  Forge options include `:base_url` and `:token`.

  Once repository creation returns success, finish errors and caught exceptions attempt
  deletion of that repo and all three local faces. Incomplete cleanup is logged, not
  substituted for the original error; caught exceptions are re-raised. Process/VM death
  can leave residue. A retry is clean only if compensation actually completed.

  Existing state may instead return `:idempotent`: matching local origins, a readable forge
  repo and both published writer branches suffice. This does not verify contents or
  protection, and still calls architect ensure.
  """
  @spec onboard(String.t(), keyword()) :: {:ok, Onboard.result()} | {:error, term()}
  def onboard(name, opts \\ []) when is_binary(name) do
    dirs = Faces.face_dirs(name, opts)

    # Validate the explicit card before creating a repository that would need compensation.
    with {:ok, org} <- Onboard.required_org(opts),
         :ok <- Onboard.admit(org, name, opts),
         :ok <- Repo.ensure_catalogue_org_on_forge(org, opts),
         :ok <- refute_existing_or_converge("#{org}/#{name}", dirs, opts),
         {:ok, full_name} <- create_repo(name, org, opts) do
      case guarded_finish(full_name, dirs, name, opts) do
        {:ok, result} ->
          {:ok, result}

        {:error, reason} = err ->
          compensate_onboard(full_name, dirs, reason, opts)
          err
      end
    else
      {:already_satisfied, result} -> {:ok, result}
      {:error, _} = err -> err
    end
  end

  # Catch exceptions as well as returned errors after creation, then re-raise with the original
  # kind and stacktrace. Compensation is an attempt, not a guarantee of clean state.
  defp guarded_finish(full_name, dirs, name, opts) do
    finish_onboard(full_name, dirs, name, opts)
  catch
    kind, payload ->
      compensate_onboard(full_name, dirs, {kind, payload}, opts)
      :erlang.raise(kind, payload, __STACKTRACE__)
  end

  defp finish_onboard(full_name, dirs, name, opts) do
    with :ok <- WriteSpacing.gap(opts),
         {:ok, url} <- Repo.repo_url(full_name, opts),
         :ok <- Repo.seed_protocol_labels(full_name, opts),
         :ok <- Faces.clone_main(url, dirs.code),
         :ok <- Scaffold.main(dirs.code, name, Onboard.with_ci_stance(full_name, opts)),
         :ok <- Onboard.write_declaration(dirs.code, full_name, opts),
         :ok <- Faces.commit(dirs.code, "chore(onboard): scaffold initial du projet"),
         :ok <- Faces.push(dirs.code, "main", false),
         :ok <- WriteSpacing.gap(opts),
         :ok <-
           build_writer_face(
             full_name,
             url,
             dirs.ops,
             Layout.ops_branch(),
             "ops",
             name,
             opts
           ),
         :ok <- WriteSpacing.gap(opts),
         :ok <-
           build_writer_face(
             full_name,
             url,
             dirs.workshop,
             Layout.workshop_branch(),
             "workshop",
             name,
             opts
           ),
         :ok <- Faces.lock_main(full_name, opts) do
      Logger.info(
        "ProjectOnboard: #{full_name} ready — main=#{dirs.code}, " <>
          "#{Layout.ops_branch()}=#{dirs.ops}, #{Layout.workshop_branch()}=#{dirs.workshop}"
      )

      {:ok, Onboard.onboard_result(full_name, dirs, opts)}
    end
  end

  # New-repository path: initialize writer branches instead of probing and cloning them.
  defp build_writer_face(_full_name, url, dir, branch, template, name, opts) do
    with :ok <- Faces.init_face(dir, url, branch),
         :ok <- Scaffold.face(dir, template, name, opts),
         :ok <- Faces.commit(dir, "chore(onboard): init #{branch}") do
      Faces.publish_face(dir, branch)
    end
  end

  defp compensate_onboard(full_name, dirs, reason, opts) do
    forge =
      case Repo.delete_forge(full_name, opts) do
        {:ok, verdict} -> verdict
        {:error, e} -> {:delete_failed, e}
      end

    Logger.warning(
      "ProjectOnboard: onboard #{full_name} FAILED (#{inspect(reason)}) — compensated: " <>
        "forge #{inspect(forge)}, project_dir #{inspect(Faces.compensate_dir(dirs.code))}, " <>
        "work_dir #{inspect(Faces.compensate_dir(dirs.ops))}, " <>
        "doc_dir #{inspect(Faces.compensate_dir(dirs.workshop))} " <>
        "(a clean retry is possible; incomplete legs above must be cleared first)"
    )
  end

  @doc """
  Imports a forge repository from an installed catalogue org without changing main content.
  The fresh-import path requires main as the default branch; existing-state convergence
  is checked first and accepts any readable default branch.

  On returned errors, attempts local cleanup and deletion of writer branches whose pushes
  returned success. Pre-existing cloned branches are retained. Failed branch deletion returns
  `{:import_not_compensated, reason, left}`; local cleanup failures are logged only.
  Exceptions bypass this compensation, and remote protection changes are not rolled back.
  """
  @spec import(String.t(), keyword()) :: {:ok, Onboard.result()} | {:error, term()}
  def import(full_name, opts \\ []) when is_binary(full_name) do
    # The source owner selects the catalogue; a default org would misroute other catalogues.
    org = full_name |> String.split("/") |> List.first()
    name = Layout.project_name(full_name)
    dirs = Faces.face_dirs(name, opts)

    # Keep local card admission before forge guards.
    with :ok <- Onboard.admit(org, name, opts),
         :ok <- Refute.refute_store(full_name, opts),
         :ok <- Repo.ensure_catalogue_org_on_forge(org, opts),
         :ok <- refute_existing_or_converge(full_name, dirs, opts),
         :ok <- require_default_branch_main(full_name, opts) do
      case Onboard.finish_import(full_name, dirs, name, opts) do
        {:ok, result} ->
          {:ok, result}

        {:error, reason} = err ->
          Logger.warning(
            "ProjectOnboard: import #{full_name} FAILED (#{inspect(reason)}) — compensated: " <>
              "project_dir #{inspect(Faces.compensate_dir(dirs.code))}, " <>
              "work_dir #{inspect(Faces.compensate_dir(dirs.ops))}, " <>
              "doc_dir #{inspect(Faces.compensate_dir(dirs.workshop))} #{remote_state(reason)}"
          )

          err
      end
    else
      {:already_satisfied, result} -> {:ok, result}
      {:error, _} = err -> err
    end
  end

  # This log distinguishes reported branch-cleanup failures. Its fallback does not prove
  # a clean retry after an ambiguous push or other untracked remote mutation.
  defp remote_state({:import_not_compensated, _reason, left}),
    do:
      "(⚠ REPO MUTATED — branches pushed by this attempt SURVIVE: " <>
        "#{inspect(Enum.map(left, &elem(&1, 0)))}; a retry is NOT clean)"

  defp remote_state(_reason), do: "(repo untouched — pre-existing; a clean retry is possible)"

  defp require_default_branch_main(full_name, opts) do
    case Repo.repo_mod(opts).default_branch(full_name, Repo.fc_opts(opts)) do
      {:ok, "main"} -> :ok
      {:ok, other} -> {:error, {:unexpected_default_branch, other}}
      {:error, _} = err -> err
    end
  end

  defp refute_existing(dirs) do
    case Enum.find([dirs.code, dirs.ops, dirs.workshop], &File.exists?/1) do
      nil -> :ok
      dir -> {:error, {:already_exists, dir}}
    end
  end

  defp refute_existing_or_converge(full_name, dirs, opts) do
    case refute_existing(dirs) do
      :ok ->
        :ok

      {:error, _} = refusal ->
        if satisfied_end_state?(full_name, dirs, opts) do
          Logger.info(
            "ProjectOnboard: #{full_name} already realized (repo + three faces proven ours + " <>
              "writer branches published) — idempotent re-emit, nothing created"
          )

          {:already_satisfied,
           Map.put(Onboard.onboard_result(full_name, dirs, opts), :idempotent, true)}
        else
          refusal
        end
    end
  end

  defp satisfied_end_state?(full_name, dirs, opts) do
    ours? =
      Enum.all?([dirs.code, dirs.ops, dirs.workshop], fn dir ->
        Repo.origin_full_name(dir, opts) == {:ok, full_name}
      end)

    # Only explicit true proves publication; an error tuple is truthy in Elixir.
    published? =
      Enum.all?([Layout.ops_branch(), Layout.workshop_branch()], fn branch ->
        Repo.repo_mod(opts).branch_exists?(full_name, branch, Repo.fc_opts(opts)) == {:ok, true}
      end)

    ours? and forge_repo_present?(full_name, opts) and published?
  end

  defp forge_repo_present?(full_name, opts) do
    match?({:ok, _branch}, Repo.repo_mod(opts).default_branch(full_name, Repo.fc_opts(opts)))
  end

  # User choice: scaffold from the installed catalogue, not a generated forge template copy.
  # A second copy had drifted; keeping the local catalogue authoritative removes that sync.
  defp create_repo(name, org, opts) do
    desc = Keyword.get(opts, :description, "")

    result =
      Repo.repo_mod(opts).create_repo(name, Keyword.merge(opts, org: org, description: desc))

    Repo.classify_create_repo(result, org, name)
  end
end
