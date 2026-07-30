defmodule Fleet.Pilot.ConflictApply do
  @moduledoc """
  Tier-0 AUTO-RESOLUTION (the write half). When the diagnosis says a conflict is entirely trivial,
  the runtime performs the merge itself in a throwaway `git worktree`, RE-resolves each conflicted
  file with `Fleet.Conflict` in the real merge orientation (ours = the feature HEAD, theirs =
  `origin/main`) -- and only if EVERY file resolves, commits and pushes the feature branch.

  Why this is safe to write: the poller re-detects the new head and the jury re-judges it. A wrong
  trivial resolution is caught downstream -- the safety net the standalone engine lacked. The
  diagnosis is only a hint; this module re-checks in the authoritative merge context and refuses on
  the first residual (`merge --abort`), so the caller falls back to the producer conflict-rework.

  Never destructive to the shared clone: a worktree in a temp dir, removed afterwards, so
  `WorktreeSync`'s working tree is never touched.

  **Last revised**: 2026-07-30
  """
  alias Fleet.Conflict
  alias Fleet.Layout
  alias Fleet.Pilot.GitOps

  # Automated resolution author -- the committer stays the human (GitOps identity), for traceability.
  @author %{name: "lcars-conflict-engine", email: "conflict-engine@lcars.local"}

  @doc """
  Auto-resolves and pushes `feature_ref` if the merge with `:base_branch` (default `"origin/main"`)
  is entirely trivially resolvable. `{:ok, :auto_resolved}` on success; `{:error, reason}` otherwise
  (the caller then routes to the producer). `opts`: `:base_branch`, `:dir`, `:auth` (default true),
  `:fetch` (default true).
  """
  @spec apply(String.t(), String.t(), keyword()) :: {:ok, :auto_resolved} | {:error, term()}
  def apply(repo, feature_ref, opts \\ []) do
    dir = Keyword.get(opts, :dir, Path.join(Layout.projects_root(), Layout.project_name(repo)))

    if File.dir?(Path.join(dir, ".git")) do
      apply_in(dir, feature_ref, opts)
    else
      {:error, :no_local_clone}
    end
  end

  @doc "Core flow against an explicit clone `dir` (isolated for testing with a local remote)."
  @spec apply_in(String.t(), String.t(), keyword()) :: {:ok, :auto_resolved} | {:error, term()}
  def apply_in(dir, feature_ref, opts \\ []) do
    base_branch = Keyword.get(opts, :base_branch, "origin/main")
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
  defp merge_and_resolve(wt, base_branch) do
    case GitOps.run(["-C", wt, "merge", "--no-edit", base_branch], author: @author) do
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
              :ok -> GitOps.run(["-C", wt, "commit", "--no-edit"], author: @author)
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
