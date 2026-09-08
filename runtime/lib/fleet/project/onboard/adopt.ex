defmodule Fleet.Project.Onboard.Adopt do
  @moduledoc """
  ADOPTER un arbre local que la fleet n'a pas cree : le depot n'existe pas encore sur la forge,
  mais les faces, elles, peuvent deja etre la — en tout ou en partie.

  D'ou le classement par FACE avant d'ecrire quoi que ce soit : une face qu'on a posee se defait,
  une face qui appartenait deja a l'humain se GARDE. Confondre les deux, c'est soit laisser un
  residu, soit supprimer le travail de quelqu'un d'autre.
  """

  alias Fleet.Forge.WriteSpacing
  alias Fleet.Layout
  alias Fleet.Project.GitOps
  alias Fleet.Project.Onboard
  alias Fleet.Project.Onboard.Faces
  alias Fleet.Project.Onboard.Refute
  alias Fleet.Project.Onboard.Repo
  alias Fleet.Project.Onboard.Scaffold

  require Logger

  @doc """
  Publishes a disk-only project to a new empty forge repository. `BL-6-32`

  The local `main` and any valid local `ops` history are preserved. The call seeds protocol
  labels, ensures the project declaration, publishes both faces, protects `main`, and ensures the
  architect. It refuses conflicting origins, existing forge state and malformed local faces.
  Compensation removes only the forge repository and a `ops` directory created by this call.
  """
  @spec adopt_project(String.t(), keyword()) :: {:ok, Onboard.result()} | {:error, term()}
  def adopt_project(name, opts \\ []) when is_binary(name) do
    dirs = Faces.face_dirs(name, opts)

    with {:ok, org} <- Onboard.required_org(opts),
         full_name = "#{org}/#{name}",
         :ok <- Refute.refute_store_address(full_name, name),
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

  # Per WRITER face: absent (we build it), already a git dir on that face's branch (we adopt it),
  # or a directory that is something else — which is a refusal, never a thing to overwrite. The
  # directory belongs to the user; adopt publishes what is there, it does not replace it.
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
         :ok <- Faces.set_origin(dirs.code, url),
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
    with :ok <- Faces.set_origin(dir, url) do
      Faces.publish_face(dir, branch)
    end
  end

  defp compensate_adopt(full_name, dirs, states, reason, opts) do
    forge =
      case Repo.repo_mod(opts).delete_repo(full_name, Repo.fc_opts(opts)) do
        :ok -> :deleted
        {:error, e} -> {:delete_failed, e}
      end

    # A face we BUILT is removed; a face that was already the user's is KEPT. The distinction is
    # per-face because the states are: adopting a project with a ops of its own and no
    # workshop must not delete the former while cleaning up the latter.
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
