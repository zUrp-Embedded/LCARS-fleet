defmodule Fleet.Project.Onboard.Faces do
  @moduledoc """
  Git operations for the three local project faces: code, ops and workshop.
  Roots default to Layout values captured at compile time, with per-call overrides.
  Public helpers support the onboarding submodules; lifecycle contracts live at their entry points.
  """

  alias Fleet.Layout
  alias Fleet.Project.GitOps
  alias Fleet.Project.Onboard.Repo
  alias Fleet.Project.Onboard.Scaffold
  alias Fleet.Project.Roles

  require Logger

  @code_root Layout.code_root()
  @ops_root Layout.ops_root()
  @workshop_root Layout.workshop_root()

  @doc false
  @spec code_root(keyword()) :: String.t()
  def code_root(opts), do: Keyword.get(opts, :code_root, @code_root)

  # ForgeIdentity supplies the system scaffold author. Git committer configuration describes
  # the runtime environment, not necessarily the human requester.
  @doc false
  @spec onboard_author() :: %{name: String.t(), email: String.t()}
  def onboard_author, do: Fleet.Credentials.ForgeIdentity.system_identity()

  @doc false
  @spec compensate_dir(String.t()) :: :removed | :removal_incomplete | :absent
  def compensate_dir(dir) do
    if File.exists?(dir) do
      case nuke_dir(dir) do
        :ok -> :removed
        {:error, _} -> :removal_incomplete
      end
    else
      :absent
    end
  end

  # Delete only branches reported as newly published, retaining cloned branches.
  # Failed deletions wrap the original error so callers know remote cleanup is incomplete.
  # Deletion is by branch name without an expected SHA; concurrent advances are not protected.
  @doc false
  @spec undo_published(String.t(), [String.t()], term(), keyword()) :: {:error, term()}
  def undo_published(_full_name, [], reason, _opts), do: {:error, reason}

  def undo_published(full_name, published, reason, opts) do
    outcomes =
      Enum.map(published, fn branch ->
        {branch, Repo.repo_mod(opts).delete_branch(full_name, branch, Repo.fc_opts(opts))}
      end)

    case Enum.reject(outcomes, &match?({_b, {:ok, _}}, &1)) do
      [] ->
        Logger.warning(
          "ProjectOnboard: import #{full_name} FAILED (#{inspect(reason)}) — forge compensated: " <>
            "#{inspect(Enum.map(outcomes, fn {b, {:ok, o}} -> {b, o} end))}"
        )

        {:error, reason}

      left ->
        Logger.error(
          "ProjectOnboard: import #{full_name} FAILED (#{inspect(reason)}) and its forge " <>
            "compensation did NOT complete — branches pushed by this attempt SURVIVE on a " <>
            "third-party repo: #{inspect(left)}"
        )

        {:error, {:import_not_compensated, reason, left}}
    end
  end

  # ⚠ AVEC UNE BRANCHE, LE REFSPEC EST RESSERRE : une FACE ne porte que la sienne (cf. le bloc de
  # `clone_main`). Sans elle — le cas d'un arbre de travail d'import, qui pousse trois branches
  # depuis un seul clone — le refspec reste celui que git a pose.
  @doc false
  @spec set_origin(String.t(), String.t(), String.t() | nil) :: :ok | {:error, term()}
  def set_origin(dir, url, branch \\ nil) do
    with :ok <- put_origin(dir, url) do
      if branch do
        GitOps.run(
          [
            "-C",
            dir,
            "config",
            "remote.origin.fetch",
            "+refs/heads/#{branch}:refs/remotes/origin/#{branch}"
          ],
          auth: false
        )
      else
        :ok
      end
    end
  end

  defp put_origin(dir, url) do
    case GitOps.read(["-C", dir, "config", "--get", "remote.origin.url"]) do
      {:ok, _present} -> GitOps.run(["-C", dir, "remote", "set-url", "origin", url], auth: false)
      {:error, _} -> GitOps.run(["-C", dir, "remote", "add", "origin", url], auth: false)
    end
  end

  @doc false
  @spec nuke_dir(String.t()) :: :ok | {:error, term()}
  def nuke_dir(dir) do
    case File.rm_rf(dir) do
      {:ok, _} ->
        :ok

      {:error, reason, path} ->
        Logger.warning("ProjectOnboard: reset could not fully remove #{path}: #{inspect(reason)}")
        {:error, reason}
    end
  end

  # Track each branch only after a successful push return; a push error can still be ambiguous.
  # Carry the successful prefix on failure because ops publishes before workshop.
  # The mode comes from `Fleet.Layout` by branch, never from a literal here; chmod applies to the
  # face root only, not recursively to its contents.
  @doc false
  @spec ensure_writer_faces(String.t(), String.t(), map(), String.t(), keyword()) ::
          {:ok, [String.t()]} | {:error, term(), [String.t()]}
  def ensure_writer_faces(full_name, url, dirs, name, opts) do
    faces = [
      %{dir: dirs.ops, branch: Layout.ops_branch(), template: "ops"},
      %{dir: dirs.workshop, branch: Layout.workshop_branch(), template: "workshop"}
    ]

    Enum.reduce_while(faces, {:ok, []}, fn %{branch: branch} = face, {:ok, published} ->
      case ensure_face(full_name, url, face, name, opts) do
        {:ok, :published} -> {:cont, {:ok, published ++ [branch]}}
        {:ok, :cloned} -> {:cont, {:ok, published}}
        {:error, reason} -> {:halt, {:error, reason, published}}
      end
    end)
  end

  @doc false
  @spec lock_main(String.t(), keyword()) :: :ok | {:error, term()}
  def lock_main(full_name, opts), do: protect_main(full_name, opts)

  @doc """
  Required main status contexts, also read by project_template_workflows_test.

  That test checks probe workflows remain outside this glob. Sharing this function avoids
  a copied expectation that would miss a changed protection rule.
  """
  @spec main_status_check_contexts() :: [String.t()]
  def main_status_check_contexts, do: ["CI / *"]

  @doc false
  @spec protect_main(String.t(), keyword()) :: :ok | {:error, term()}
  def protect_main(repo, opts) do
    rule = %{
      rule_name: "main",
      required_approvals: length(Roles.project_jury(repo, opts)),
      dismiss_stale_approvals: true,
      block_on_rejected_reviews: true,
      enable_push: false,
      # Enforce CI on the forge as well as in runtime checks, covering merges outside the runtime.
      # The glob tolerates job/trigger changes but requires the workflow name to remain CI;
      # requiring every status would also make unrelated probes block merges.
      enable_status_check: true,
      status_check_contexts: main_status_check_contexts()
    }

    case Repo.repo_mod(opts).protect_branch(repo, rule, Repo.fc_opts(opts)) do
      {:ok, outcome} -> announce_protection(repo, rule, outcome)
      {:error, reason} -> {:error, {:protect_main, reason}}
    end
  end

  @doc false
  @spec announce_protection(String.t(), term(), atom()) :: :ok
  def announce_protection(_repo, _rule, :unchanged), do: :ok

  def announce_protection(repo, rule, outcome) when outcome in [:created, :updated] do
    Logger.info(
      "ProjectOnboard: #{repo} main-protection #{outcome} " <>
        "(approvals=#{rule.required_approvals}, direct push refused)"
    )

    :ok
  end

  # ⚠ `--single-branch` N'EST PAS UNE OPTIMISATION, C'EST CE QUI SEPARE LES TROIS FACES.
  #
  # Un projet a UN depot et trois faces, qui sont trois branches ORPHELINES de ce depot (aucun
  # ancetre commun : `merge-base` ne rend rien, mesure du 2026-09-18 sur le banc 2004). Mais chaque
  # face est un clone a part, et `--branch <face>` choisit seulement ce qui SORT dans le repertoire
  # de travail : sans `--single-branch`, git configure `+refs/heads/*:refs/remotes/origin/*` et
  # RAPATRIE LES OBJETS DE TOUTES LES BRANCHES.
  #
  # Mesure, meme jour, meme banc : 20 Mo pousses sur `workshop`, puis un `git fetch origin` nu dans
  # la face CODE — elle passe de 456 KiB a 19,54 MiB, et le blob de workshop est dans sa base. Une
  # zone de depot ou un humain verse des firmwares fait donc porter trois fois chaque fichier, dont
  # une par la face que les pods clonent a chaque tache et qui ne l'affichera jamais.
  #
  # ⚠ ET CA NE COUPE RIEN : ce que la face code doit voir en plus — les branches de travail des pods
  # — est cherche par un refspec EXPLICITE (`worktree_sync`, `refs/heads/lcars/issue-<n>-*:…`), et
  # un refspec en ligne de commande l'emporte sur celui de la config. Sur les dix fetchs du runtime,
  # huit nomment deja ce qu'ils veulent ; les deux `fetch origin` nus ne veulent que leur face.
  @doc false
  @spec clone_main(String.t(), String.t()) :: :ok | {:error, term()}
  def clone_main(url, proj_dir) do
    File.mkdir_p!(Path.dirname(proj_dir))
    GitOps.run(["clone", "--single-branch", "--branch", "main", url, proj_dir], auth: true)
  end

  @doc false
  @spec publish_face(String.t(), String.t()) :: :ok | {:error, term()}
  def publish_face(dir, branch), do: push(dir, branch, true)

  # Each writer face owns its gitdir: a linked worktree would need writes inside the
  # parent repository, which pods can mount read-only.
  @doc false
  @spec init_face(String.t(), String.t(), String.t()) :: :ok | {:error, term()}
  def init_face(dir, url, branch) do
    File.mkdir_p!(Path.dirname(dir))

    # ⚠ LE MODE SE POSE ICI, PARCE QUE C'EST ICI QUE LE REPERTOIRE NAIT. Les trois chemins qui
    # batissent une face d'ecriture passent par ce verbe — creation d'un projet, adoption d'un
    # arbre local, import d'une branche absente — et deux d'entre eux ne le posaient pas : la face
    # naissait sous l'umask du BEAM (mesure du 2026-09-16 sur LCARS-beta : atelier en 2755 au lieu
    # de 2775). Le laisser a l'appelant, c'est l'oublier dans l'appelant suivant.
    #
    # `-t <branche>` : le pendant de `--single-branch` pour une face PUBLIEE et non clonee. Sans
    # lui, `remote add` pose le refspec large, et le premier fetch rapatrie les deux autres faces —
    # meme defaut, autre porte.
    with :ok <- GitOps.run(["init", "-q", "-b", branch, dir], auth: false),
         :ok <- GitOps.run(["-C", dir, "remote", "add", "-t", branch, "origin", url], auth: false) do
      apply_face_mode(dir, branch)
    end
  end

  # Nil mode = no rule declared for this face (the code face, a feature branch): leave the umask.
  defp apply_face_mode(dir, branch) do
    case Layout.writer_face_mode(Layout.face_of(branch)) do
      nil -> :ok
      mode -> chmod_face(dir, mode)
    end
  end

  # Distinguish cloned from newly published branches for compensation. An unreadable branch
  # is a refusal, never evidence that it is absent. The probe and push are not an atomic claim.
  @doc false
  @spec ensure_face(String.t(), String.t(), map(), String.t(), keyword()) ::
          {:ok, :cloned | :published} | {:error, term()}
  def ensure_face(full_name, url, face, name, opts) do
    %{dir: dir, branch: branch, template: template} = face

    case Repo.repo_mod(opts).branch_exists?(full_name, branch, Repo.fc_opts(opts)) do
      {:error, reason} ->
        {:error, {:branch_unreadable, branch, reason}}

      {:ok, true} ->
        File.mkdir_p!(Path.dirname(dir))

        # `--single-branch` : cf. le bloc de `clone_main` — une face ne porte QUE sa branche.
        with :ok <-
               GitOps.run(["clone", "--single-branch", "--branch", branch, url, dir], auth: true),
             :ok <- apply_face_mode(dir, branch) do
          {:ok, :cloned}
        end

      {:ok, false} ->
        with :ok <- init_face(dir, url, branch),
             :ok <- Scaffold.face(dir, template, name, opts),
             :ok <- commit(dir, "chore(import): init #{branch}"),
             :ok <- publish_face(dir, branch) do
          {:ok, :published}
        end
    end
  end

  # Measure before writing: a chmod on a directory carrying an ACL clamps that ACL's mask down to
  # the group bits, and the deployment grants named accounts access to the face roots that way.
  # Re-onboarding a project must not silently revoke access the runtime never granted.
  @doc false
  @spec chmod_face(String.t(), non_neg_integer()) :: :ok | {:error, term()}
  def chmod_face(dir, mode) do
    case File.stat(dir) do
      {:ok, %File.Stat{mode: current}} ->
        if Bitwise.band(current, 0o7777) == mode, do: :ok, else: write_face_mode(dir, mode)

      {:error, reason} ->
        {:error, {:face_mode_unreadable, dir, reason}}
    end
  end

  defp write_face_mode(dir, mode) do
    case File.chmod(dir, mode) do
      :ok -> :ok
      {:error, reason} -> {:error, {:face_mode_failed, dir, mode, reason}}
    end
  end

  @doc false
  @spec face_dirs(String.t(), keyword()) :: %{
          code: String.t(),
          workshop: String.t(),
          ops: String.t()
        }
  def face_dirs(name, opts) do
    %{
      code: Path.join(Keyword.get(opts, :code_root, @code_root), name),
      workshop: Path.join(Keyword.get(opts, :workshop_root, @workshop_root), name),
      ops: Path.join(Keyword.get(opts, :ops_root, @ops_root), name)
    }
  end

  @doc false
  @spec commit(String.t(), String.t()) :: :ok | {:error, term()}
  def commit(dir, message) do
    with :ok <- GitOps.run(["-C", dir, "add", "-A"], auth: false) do
      GitOps.run(["-C", dir, "commit", "-m", message], auth: false, author: onboard_author())
    end
  end

  @doc false
  @spec push(String.t(), String.t(), boolean()) :: :ok | {:error, term()}
  def push(dir, branch, set_upstream?) do
    args =
      ["-C", dir, "push"] ++
        if(set_upstream?, do: ["-u"], else: []) ++ ["origin", branch]

    GitOps.run(args, auth: true)
  end
end
