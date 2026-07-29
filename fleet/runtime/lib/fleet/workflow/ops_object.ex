defmodule Fleet.Workflow.OpsObject do
  @moduledoc """
  The ONE parametric mechanic "commit an object into the work/ops worktree" — engine, no
  business: write the file, commit it atomically (`add_paths: [ref]`, one object per commit),
  publish best-effort. `BriefArtifact` (briefs) and `Provenance` (statements) are pure
  BUSINESS layers (naming, content) plugged onto this mechanic; duplicating it per artifact
  family would be the exact anti-pattern the engine/business axiom forbids.

  **Identity = the introducing COMMIT sha** (returned by `commit_object/4`). Idempotent via
  git: same path + same content ⇒ no new commit, the introducing commit is returned
  (`Git.last_commit_sha/2`); different content ⇒ a new commit on the same path (a VERSION —
  git history is the ledger, nothing is ever rewritten).

  **Publication is BEST-EFFORT on top of the local truth** (F-15): `push: :work_ops` (the
  single owner of the `{"origin", "work/ops"}` target) or an explicit `{remote, refspec}`;
  a push failure logs LOUD and keeps the local success — the branch catches up whole at the
  next successful push. Local commit failure remains a real failure.

  **Last revised**: 2026-07-30
  """

  require Logger

  alias Fleet.Workflow.Git

  # The ONLY site that knows where work/ops publishes (F-15). Callers say `push: :work_ops`.
  @work_ops_push {"origin", "work/ops"}

  @doc """
  Commits `content` at `ref` (work/ops-relative) inside `work_dir` and returns
  `{:ok, commit_sha}` — the introducing commit (the version's identity).

  `opts`:
  - `:label` — commit-message prefix (`"<label>: <ref>"`), REQUIRED (the artifact family
    speaks its name in the log rail).
  - `:author` — `{name, email}`, system default.
  - `:push` — `:work_ops` | `{remote, refspec}` | absent (local only, tests).

  `{:error, term()}`: work_dir missing / non-git, write failure, local git failure (fail-loud).
  """
  @spec commit_object(Path.t(), String.t(), String.t(), keyword()) ::
          {:ok, String.t()} | {:error, term()}
  def commit_object(work_dir, ref, content, opts)
      when is_binary(work_dir) and is_binary(ref) and is_binary(content) do
    abs = Path.join(work_dir, ref)

    cond do
      not File.dir?(work_dir) ->
        {:error, {:work_dir_missing, work_dir}}

      File.exists?(abs) and File.read!(abs) == content ->
        # Same version already on disk → identity = the commit that introduced it. Empty sha
        # (written but never committed — crash residue) → re-materialize to give it one.
        case Git.last_commit_sha(work_dir, ref) do
          {:ok, sha} when sha != "" -> {:ok, sha}
          _ -> materialize(work_dir, abs, ref, content, opts)
        end

      true ->
        materialize(work_dir, abs, ref, content, opts)
    end
  end

  # How far back a readback walks `ref`'s history looking for its own version. Bounded so a
  # long-lived ref cannot turn a post-timeout confirmation into an unbounded scan; generous enough
  # that a realistic burst of concurrent writers on ONE ref cannot bury a commit that just landed.
  @readback_history_depth 50

  @doc """
  READ-ONLY probe: has `content` been committed at `ref`? `{:ok, sha}` (the commit carrying that
  version) or `:not_committed`. Takes NO index.lock (only `git log` + `git show`, both read-only),
  so a caller that TIMED OUT waiting on the serializer can confirm whether its transaction landed
  WITHOUT reintroducing the concurrent-git race the serializer exists to prevent. Never materializes.

  Asks "did MY version land", NOT "is my version at the TIP". The distinction is the whole point:
  the tip answers for the LAST writer only, so under two concurrent writes on one ref the first
  one's commit is in the history, is real, is pushed — and a tip-identity readback reported it as
  never having happened. That negative was then logged as DEFINITIVE, and a caller acting on it
  retries and overwrites the version that displaced it. Walking `ref`'s bounded history instead
  matches the identity model this module already declares (identity = the introducing commit),
  and a version present anywhere in that history HAS landed, whatever sits at the tip now.

  Content-identity, deliberately: two writers of the SAME content are indistinguishable and
  equivalent here — exactly the idempotency `commit_object/4` already promises for that case.
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
        # Newest first: under concurrency the answer is normally the tip, so the common case still
        # costs one `git show`. An unreadable commit is SKIPPED, never fatal — this probe exists to
        # turn a maybe into a fact, and one bad object must not make it lie in the other direction.
        Enum.find_value(shas, :not_committed, fn sha ->
          case Git.show(work_dir, sha, ref) do
            {:ok, ^content} -> {:ok, sha}
            _ -> nil
          end
        end)

      {:error, _reason} ->
        :not_committed
    end
  end

  defp materialize(work_dir, abs, ref, content, opts) do
    with :ok <- File.mkdir_p(Path.dirname(abs)),
         :ok <- File.write(abs, content),
         {:ok, commit_sha} <- commit_or_recover(work_dir, ref, opts),
         :ok <- maybe_push(work_dir, opts) do
      {:ok, commit_sha}
    end
  end

  # `Git.commit` returns the new HEAD sha; `:nothing_to_commit` (identical content raced in by
  # another writer) recovers the introducing commit — never an error for an existing version.
  defp commit_or_recover(work_dir, ref, opts) do
    case Git.commit(commit_opts(work_dir, ref, opts)) do
      {:ok, sha} -> {:ok, sha}
      {:error, :nothing_to_commit} -> Git.last_commit_sha(work_dir, ref)
      {:error, reason} -> {:error, reason}
    end
  end

  defp commit_opts(work_dir, ref, opts) do
    # Default author = the SYSTEM identity from its SINGLE AUTHORITY
    # (`ForgeIdentity.system_identity/0`) — a name/email literal retyped here WAS the
    # divergence: `system@lcars.local` matched no forge account, so every work-order and
    # provenance commit rendered as plain text (no profile link, no avatar) on Gitea,
    # while onboard commits (already on the SSoT) rendered linked.
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
      # `add_paths` limited to the object — never `["."]` (an artifact commit must not sweep
      # an entire work/ops worktree: one object, atomic).
      add_paths: [ref]
    }
  end

  defp maybe_push(work_dir, opts) do
    case Keyword.get(opts, :push) do
      nil ->
        :ok

      :work_ops ->
        do_push(work_dir, @work_ops_push, opts)

      {_remote, _refspec} = target ->
        do_push(work_dir, target, opts)
    end
  end

  defp do_push(work_dir, {remote, refspec}, opts) do
    case Git.push(work_dir, remote, refspec) do
      {:ok, _} ->
        :ok

      {:error, reason} ->
        Logger.warning(
          "OpsObject: work/ops publication failed (#{Keyword.fetch!(opts, :label)}, " <>
            "#{inspect(reason)}) — local object kept, forge catches up at next push"
        )

        :ok
    end
  end
end
