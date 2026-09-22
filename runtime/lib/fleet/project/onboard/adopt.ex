defmodule Fleet.Project.Onboard.Adopt do
  @moduledoc """
  Publishes an existing local project to a new forge repository.

  Classify writer faces before mutation so compensation can retain pre-existing
  directories. It does not undo changes to their origins, files or commits.
  """

  alias Fleet.Forge.WriteSpacing
  alias Fleet.Layout
  alias Fleet.Project.GitOps
  alias Fleet.Project.Onboard
  alias Fleet.Project.Onboard.Faces
  alias Fleet.Project.Onboard.Repo
  alias Fleet.Project.Onboard.Scaffold

  require Logger

  @doc """
  Publishes local main, ops and workshop histories; missing writer faces are created.
  Seeds labels, adds missing declaration/CI files, protects main and ensures the architect.

  Admission checks that named branch refs resolve, not that those branches are checked out.
  A conflicting parsed main origin is refused; origin read errors are accepted.

  On a returned finish error, attempts to delete the new forge repo and writer directories
  classified absent before the call. Cleanup failures are logged; the original error returns.
  Exceptions bypass this compensation. The local main directory is retained.
  """
  @spec adopt_project(String.t(), keyword()) :: {:ok, Onboard.result()} | {:error, term()}
  def adopt_project(name, opts \\ []) when is_binary(name) do
    dirs = Faces.face_dirs(name, opts)

    with {:ok, org} <- Onboard.required_org(opts),
         full_name = "#{org}/#{name}",
         :ok <- Onboard.admit(org, name, opts),
         :ok <- require_local_main(dirs.code),
         :ok <- Repo.ensure_catalogue_org_on_forge(org, opts),
         :ok <- require_adoptable_origin(full_name, dirs.code, opts),
         {:ok, states} <- classify_adopt_writer_faces(dirs),
         :ok <- Repo.require_forge_absent(full_name, opts),
         {:ok, url} <- Repo.repo_url(full_name, opts),
         {:ok, full_name} <- Repo.create_empty_repo(name, org, opts) do
      case finish_adopt(full_name, url, dirs, states, name, opts) do
        {:ok, result} ->
          {:ok, result}

        {:error, reason} = err ->
          compensate_adopt(full_name, dirs, states, reason, opts)
          err
      end
    end
  end

  defp require_local_main(proj_dir) do
    with true <- File.dir?(proj_dir),
         {:ok, _sha} <-
           GitOps.read(["-C", proj_dir, "rev-parse", "--verify", "--quiet", "refs/heads/main"]) do
      :ok
    else
      _ -> {:error, {:not_adoptable, {:no_local_main, proj_dir}}}
    end
  end

  defp require_adoptable_origin(full_name, proj_dir, opts) do
    case Repo.origin_full_name(proj_dir, opts) do
      {:ok, ^full_name} -> :ok
      {:ok, other} -> {:error, {:origin_conflict, other}}
      {:error, _no_origin} -> :ok
    end
  end

  # A resolving branch ref admits an existing writer face; this does not check HEAD or its origin.
  defp classify_adopt_face(dir, branch) do
    cond do
      not File.exists?(dir) ->
        {:ok, :absent}

      match?(
        {:ok, _},
        GitOps.read(["-C", dir, "rev-parse", "--verify", "--quiet", "refs/heads/" <> branch])
      ) ->
        {:ok, :present_git}

      true ->
        {:error, {:not_adoptable, {:face_dir_not_on_branch, dir, branch}}}
    end
  end

  defp classify_adopt_writer_faces(dirs) do
    with {:ok, ops} <- classify_adopt_face(dirs.ops, Layout.ops_branch()),
         {:ok, workshop} <-
           classify_adopt_face(dirs.workshop, Layout.workshop_branch()) do
      {:ok, %{ops: ops, workshop: workshop}}
    end
  end

  defp finish_adopt(full_name, url, dirs, states, name, opts) do
    with :ok <- WriteSpacing.gap(opts),
         :ok <- Repo.seed_protocol_labels(full_name, opts),
         # la branche RESSERRE le refspec : une face ne porte que la sienne (cf. `Faces.clone_main`)
         :ok <- Faces.set_origin(dirs.code, url, Layout.code_branch()),
         :ok <- Onboard.ensure_declaration(dirs.code, full_name, opts),
         :ok <-
           Onboard.ensure_ci_workflows(
             dirs.code,
             name,
             Onboard.with_ci_stance(full_name, opts),
             "ci(adopt): rail CI du depot (.gitea/workflows)"
           ),
         :ok <- Faces.push(dirs.code, "main", true),
         :ok <- WriteSpacing.gap(opts),
         :ok <-
           adopt_face(
             states.ops,
             url,
             dirs.ops,
             Layout.ops_branch(),
             "ops",
             name,
             opts
           ),
         :ok <- WriteSpacing.gap(opts),
         :ok <-
           adopt_face(
             states.workshop,
             url,
             dirs.workshop,
             Layout.workshop_branch(),
             "workshop",
             name,
             opts
           ),
         :ok <- Faces.lock_main(full_name, opts) do
      Logger.info(
        "ProjectOnboard: #{full_name} ADOPTED from disk — main published, " <>
          "#{Layout.ops_branch()} and #{Layout.workshop_branch()} up, protection placed"
      )

      {:ok, Onboard.onboard_result(full_name, dirs, opts)}
    end
  end

  defp adopt_face(:absent, url, dir, branch, template, name, opts) do
    with :ok <- Faces.init_face(dir, url, branch),
         :ok <- Scaffold.face(dir, template, name, opts),
         :ok <- Faces.commit(dir, "chore(adopt): init #{branch}") do
      Faces.publish_face(dir, branch)
    end
  end

  defp adopt_face(:present_git, url, dir, branch, _template, _name, _opts) do
    with :ok <- Faces.set_origin(dir, url, branch) do
      Faces.publish_face(dir, branch)
    end
  end

  defp compensate_adopt(full_name, dirs, states, reason, opts) do
    forge =
      case Repo.repo_mod(opts).delete_repo(full_name, Repo.fc_opts(opts)) do
        :ok -> :deleted
        {:error, e} -> {:delete_failed, e}
      end

    # Cleanup is per initial face state: never remove a pre-existing writer directory.
    # The log's 'untouched' refers to retention, not restoration of its earlier contents.
    undo = fn state, dir ->
      if state == :absent, do: Faces.compensate_dir(dir), else: :kept_preexisting
    end

    Logger.warning(
      "ProjectOnboard: adopt #{full_name} FAILED (#{inspect(reason)}) — compensated: " <>
        "forge #{inspect(forge)}, work_dir #{inspect(undo.(states.ops, dirs.ops))}, " <>
        "doc_dir #{inspect(undo.(states.workshop, dirs.workshop))} (proj_dir untouched — the user's; " <>
        "a clean retry is possible)"
    )
  end
end
