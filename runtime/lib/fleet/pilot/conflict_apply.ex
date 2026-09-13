defmodule Fleet.Pilot.ConflictApply do
  @moduledoc """
  Tier-0 conflict writer: merges the requested base into a temporary feature worktree,
  resolves unmerged files, and pushes only after all resolutions and the commit succeed.
  Review of the resulting head is the caller's responsibility.
  """
  alias Fleet.Conflict
  alias Fleet.Project.GitOps

  defp author, do: Fleet.Credentials.ForgeIdentity.system_identity()

  @doc """
  Merges and pushes `feature_ref`; requires `:dir` and `:base_branch` for the PR's face.
  `:auth` and `:fetch` default to true. Returns `{:ok, :auto_resolved}` or a returned
  Git/file/resolution error. Missing required options raise. The clone check requires
  a `.git` directory, so linked worktrees are rejected. `repo` is unused.
  """
  @spec apply(String.t(), String.t(), keyword()) :: {:ok, :auto_resolved} | {:error, term()}
  def apply(_repo, feature_ref, opts \\ []) do
    dir = Keyword.fetch!(opts, :dir)

    if File.dir?(Path.join(dir, ".git")) do
      apply_in(dir, feature_ref, opts)
    else
      {:error, :no_local_clone}
    end
  end

  @doc """
  Runs against an explicit clone, requiring `:base_branch`. Uses a unique worktree
  directory but a shared sanitized branch name; concurrent calls are not isolated.
  Cleanup errors are ignored and exceptions bypass cleanup.
  """
  @spec apply_in(String.t(), String.t(), keyword()) :: {:ok, :auto_resolved} | {:error, term()}
  def apply_in(dir, feature_ref, opts \\ []) do
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

  # diff3 supplies the base needed by one_side_change, delete_no_change and
  # non_overlapping. Without it the write path cannot reproduce those probe classifications.
  defp merge_and_resolve(wt, base_branch) do
    case GitOps.run(
           ["-C", wt, "-c", "merge.conflictStyle=diff3", "merge", "--no-edit", base_branch],
           author: author()
         ) do
      :ok ->
        :ok

      {:error, {:git_failed, _, _code, _}} ->
        resolve_unmerged(wt, unmerged_files(wt))

      {:error, _} = err ->
        err
    end
  end

  # A failed merge without unmerged files is not a conflict this engine can resolve.
  defp resolve_unmerged(wt, {:ok, []}) do
    _ = GitOps.run(["-C", wt, "merge", "--abort"])
    {:error, :merge_failed}
  end

  defp resolve_unmerged(wt, {:ok, files}) do
    case resolve_all(wt, files) do
      :ok -> GitOps.run(["-C", wt, "commit", "--no-edit"], author: author())
      {:error, _} = err -> abort(wt, err)
    end
  end

  defp resolve_unmerged(wt, {:error, _} = err), do: abort(wt, err)

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
