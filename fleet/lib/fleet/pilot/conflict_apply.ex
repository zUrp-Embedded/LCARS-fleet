defmodule Fleet.Pilot.ConflictApply do
  @moduledoc """
  Tier-0 conflict write path. It rechecks every file in an isolated worktree,
  aborts on any residual, and pushes only a complete deterministic resolution.
  The normal jury then re-judges the new head.
  """
  alias Fleet.Conflict
  alias Fleet.Project.GitOps

  # A2 — the runtime's ONE identity (`ForgeIdentity.system_identity/0`), not a locally-minted one.
  # A locally-minted author maps to NO forge account: a grey author, no avatar, no link — while
  # every other runtime write (onboard, template sync) maps to the system account. ONE AUTHOR PER
  # SUBSTRATE is the signature matrix, and the mechanical substrate's author is the system.
  defp author, do: Fleet.Credentials.ForgeIdentity.system_identity()

  @doc """
  Auto-resolves and pushes `feature_ref` if the merge with `:base_branch` (default `"origin/main"`)
  is entirely trivially resolvable. `{:ok, :auto_resolved}` on success; `{:error, reason}` otherwise
  (the caller then routes to the producer). `opts`: `:base_branch`, `:dir`, `:auth` (default true),
  `:fetch` (default true).
  """
  @spec apply(String.t(), String.t(), keyword()) :: {:ok, :auto_resolved} | {:error, term()}
  def apply(_repo, feature_ref, opts \\ []) do
    # REQUIRED (chantier face-projet): the face worktree — an ops PR resolves in the OPS worktree,
    # and a defaulted code-face dir here would silently operate on the wrong repository.
    dir = Keyword.fetch!(opts, :dir)

    if File.dir?(Path.join(dir, ".git")) do
      apply_in(dir, feature_ref, opts)
    else
      {:error, :no_local_clone}
    end
  end

  @doc "Core flow against an explicit clone `dir` (isolated for testing with a local remote)."
  @spec apply_in(String.t(), String.t(), keyword()) :: {:ok, :auto_resolved} | {:error, term()}
  def apply_in(dir, feature_ref, opts \\ []) do
    # REQUIRED (chantier face-projet): the merge target is the PR's own base — a defaulted
    # `origin/main` would merge the CODE face into an ops branch and report :auto_resolved.
    base_branch = Keyword.fetch!(opts, :base_branch)
    auth = Keyword.get(opts, :auth, true)
    fetch? = Keyword.get(opts, :fetch, true)
    apply_branch = "lcars-apply-" <> sanitize(feature_ref)
    wt = Path.join(System.tmp_dir!(), "lcars-apply-#{:erlang.unique_integer([:positive])}")

    result =
      with :ok <- maybe_fetch(dir, fetch?, auth),
           :ok <-
             GitOps.run([
               "-C",
               dir,
               "worktree",
               "add",
               "-f",
               "-B",
               apply_branch,
               wt,
               "origin/#{feature_ref}"
             ]),
           :ok <- merge_and_resolve(wt, base_branch),
           :ok <- GitOps.run(["-C", wt, "push", "origin", "HEAD:#{feature_ref}"], auth: auth) do
        {:ok, :auto_resolved}
      end

    cleanup(dir, wt, apply_branch)
    result
  end

  defp maybe_fetch(_dir, false, _auth), do: :ok
  defp maybe_fetch(dir, true, auth), do: GitOps.run(["-C", dir, "fetch", "origin"], auth: auth)

  # Merge base_branch into the feature worktree; resolve every conflicted file deterministically.
  # A clean merge is already committed by git. A residual (any file we cannot fully resolve) aborts
  # the whole apply -- never a partial write.
  #
  # `merge.conflictStyle=diff3` is LOAD-BEARING, not cosmetic. Three of the four auto-writable
  # patterns prove their correctness AGAINST THE BASE (`one_side_change`: only one side moved;
  # `delete_no_change`: the deletion is unilateral; `non_overlapping`: the two changes touch disjoint
  # regions). Git's DEFAULT style emits diff2 -- ours and theirs, no base -- so on that input those
  # three cannot fire at all, and the only patterns left able to resolve were the format-assuming
  # ones this engine refuses to write. MEASURED, not deduced: the probe diagnosed `non_overlapping`
  # (it feeds `merge-file` the base blob explicitly) while this path saw the SAME conflict as
  # unresolvable — the diagnosis that authorized the write and the write itself were reading
  # different inputs. Asking git for the base makes them agree.
  defp merge_and_resolve(wt, base_branch) do
    case GitOps.run(
           ["-C", wt, "-c", "merge.conflictStyle=diff3", "merge", "--no-edit", base_branch],
           author: author()
         ) do
      :ok ->
        # Clean merge -- git already made the merge commit.
        :ok

      {:error, {:git_failed, _, _code, _}} ->
        case unmerged_files(wt) do
          {:ok, []} ->
            _ = GitOps.run(["-C", wt, "merge", "--abort"])
            {:error, :merge_failed}

          {:ok, files} ->
            case resolve_all(wt, files) do
              :ok -> GitOps.run(["-C", wt, "commit", "--no-edit"], author: author())
              {:error, _} = err -> abort(wt, err)
            end

          {:error, _} = err ->
            abort(wt, err)
        end

      {:error, _} = err ->
        err
    end
  end

  defp unmerged_files(wt) do
    case GitOps.read(["-C", wt, "diff", "--name-only", "--diff-filter=U"]) do
      {:ok, out} -> {:ok, String.split(out, "\n", trim: true)}
      {:error, _} = err -> err
    end
  end

  defp resolve_all(wt, files) do
    Enum.reduce_while(files, :ok, fn file, :ok ->
      path = Path.join(wt, file)

      with {:ok, content} <- File.read(path),
           {:ok, %{merged: merged}} when is_binary(merged) <- Conflict.resolve(content),
           :ok <- File.write(path, merged),
           :ok <- GitOps.run(["-C", wt, "add", "--", file]) do
        {:cont, :ok}
      else
        # TOTAL over what the `with` can produce, and no catch-all: `Conflict.resolve/1` only ever
        # returns `{:ok, %Report{}}`, so the sole non-binary `merged` reaching here is `nil`, and
        # every other step returns `{:error, _}`. A third defensive clause was here and Dialyzer
        # proved it unreachable — a branch that cannot run defends nothing and hides the day the
        # union genuinely widens (which the strict flags will then say out loud, right here).
        {:ok, %{merged: nil}} -> {:halt, {:error, {:residual, file}}}
        {:error, _} = err -> {:halt, err}
      end
    end)
  end

  defp abort(wt, err) do
    _ = GitOps.run(["-C", wt, "merge", "--abort"])
    err
  end

  defp cleanup(dir, wt, apply_branch) do
    _ = GitOps.run(["-C", dir, "worktree", "remove", "--force", wt])
    _ = GitOps.run(["-C", dir, "branch", "-D", apply_branch])
    _ = File.rm_rf(wt)
    :ok
  end

  defp sanitize(ref), do: String.replace(ref, ~r/[^A-Za-z0-9._-]/, "_")
end
