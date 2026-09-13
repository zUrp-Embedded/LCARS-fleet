defmodule Fleet.Workflow.OpsObject do
  @moduledoc """
  Writes and commits ops artifacts for BriefArtifact and Provenance, with optional
  best-effort publication. The returned SHA identifies a commit holding the version.

  Use OpsObjectSync to serialize cooperating writers. Direct calls take no lock;
  callers must supply trusted paths and an exclusive worktree with a clean index.
  add_paths stages one path but Git commits the whole index. Writes and commits
  are not rolled back on later failures.

  When disk content already matches, a bounded history probe can return an existing
  commit without pushing, even if push was requested. This can leave dirty worktree
  content differing from HEAD when an older version was restored on disk.
  """

  require Logger

  alias Fleet.Workflow.Git

  # The ONLY site that knows where ops publishes (F-15). Callers say `push: :ops`.
  @ops_push {"origin", "ops"}

  @doc """
  Writes content at ref under work_dir and returns {:ok, sha, push_state}.
  Paths are joined without containment checks. Materialization requires :label;
  :author defaults to ForgeIdentity's system identity. Optional :push accepts :ops
  (origin, ops) or {remote, refspec}.

  :pushed means Git.push returned success; :local_only means a push error was
  returned, not proof that nothing reached the remote. :not_requested also covers
  an idempotent hit that skipped a requested push. Local file/Git errors propagate;
  invalid options can raise. This function does not verify remote reachability.
  """
  @type push_state :: :pushed | :local_only | :not_requested

  @spec commit_object(Path.t(), String.t(), String.t(), keyword()) ::
          {:ok, String.t(), push_state()} | {:error, term()}
  def commit_object(work_dir, ref, content, opts)
      when is_binary(work_dir) and is_binary(ref) and is_binary(content) do
    abs = Path.join(work_dir, ref)

    cond do
      not File.dir?(work_dir) ->
        {:error, {:work_dir_missing, work_dir}}

      # A failed non-bang read means content differs; it must not crash the serializer.
      File.read(abs) == {:ok, content} ->
        # Disk equality alone can describe a write left behind by a failed commit.
        # Verify bytes in history before citing a SHA. A hit skips publication.
        case committed_sha(work_dir, ref, content) do
          {:ok, sha} -> {:ok, sha, :not_requested}
          :not_committed -> materialize(work_dir, abs, ref, content, opts)
        end

      true ->
        materialize(work_dir, abs, ref, content, opts)
    end
  end

  # Bounded post-timeout history readback.
  @readback_history_depth 50

  @doc """
  Searches the latest 50 commits touching ref for the first readable version with
  matching bytes. Returns {:ok, sha} or :not_committed. Git errors and unreadable
  versions are treated as misses; older matching versions may be outside the bound.
  This identifies content in history, not which invocation wrote it.
  """
  @spec committed_sha(Path.t(), String.t(), String.t()) :: {:ok, String.t()} | :not_committed
  def committed_sha(work_dir, ref, content)
      when is_binary(work_dir) and is_binary(ref) and is_binary(content) do
    if File.dir?(work_dir) do
      find_committed_version(work_dir, ref, content)
    else
      :not_committed
    end
  end

  defp find_committed_version(work_dir, ref, content) do
    case Git.commits_touching(work_dir, ref, @readback_history_depth) do
      {:ok, shas} ->
        Enum.find_value(shas, :not_committed, &commit_holding(work_dir, &1, ref, content))

      {:error, _reason} ->
        :not_committed
    end
  end

  # Unreadable commits are skipped; the search can therefore miss a committed version.
  defp commit_holding(work_dir, sha, ref, content) do
    case Git.show(work_dir, sha, ref) do
      {:ok, ^content} -> {:ok, sha}
      _ -> nil
    end
  end

  defp materialize(work_dir, abs, ref, content, opts) do
    with :ok <- File.mkdir_p(Path.dirname(abs)),
         :ok <- File.write(abs, content),
         {:ok, commit_sha} <- commit_or_recover(work_dir, ref, opts) do
      {:ok, commit_sha, maybe_push(work_dir, opts)}
    end
  end

  # After staging, nothing_to_commit permits the last-touching SHA fallback only
  # under exclusive workspace access; concurrent changes or filters can alter that premise.
  defp commit_or_recover(work_dir, ref, opts) do
    case Git.commit(commit_opts(work_dir, ref, opts)) do
      {:ok, sha} -> {:ok, sha}
      {:error, :nothing_to_commit} -> Git.last_commit_sha(work_dir, ref)
      {:error, reason} -> {:error, reason}
    end
  end

  defp commit_opts(work_dir, ref, opts) do
    # ForgeIdentity is the single source for default system author.
    %{name: sys_name, email: sys_email} = Fleet.Credentials.ForgeIdentity.system_identity()
    {name, email} = Keyword.get(opts, :author, {sys_name, sys_email})
    label = Keyword.fetch!(opts, :label)

    %{
      workspace: work_dir,
      author_name: name,
      author_email: email,
      committer_name: name,
      committer_email: email,
      message: "#{label}: #{ref}",
      # Stage this object; any unrelated pre-staged paths still join the commit.
      add_paths: [ref]
    }
  end

  # Push errors keep local success; future publication depends on a later successful push.
  @spec maybe_push(Path.t(), keyword()) :: push_state()
  defp maybe_push(work_dir, opts) do
    case Keyword.get(opts, :push) do
      nil ->
        :not_requested

      :ops ->
        do_push(work_dir, @ops_push, opts)

      {_remote, _refspec} = target ->
        do_push(work_dir, target, opts)
    end
  end

  defp do_push(work_dir, {remote, refspec}, opts) do
    case Git.push(work_dir, remote, refspec) do
      {:ok, _} ->
        :pushed

      {:error, reason} ->
        Logger.warning(
          "OpsObject: ops publication failed (#{Keyword.fetch!(opts, :label)}, " <>
            "#{inspect(reason)}) — local object kept, forge catches up at next push"
        )

        :local_only
    end
  end
end
