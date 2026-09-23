defmodule Fleet.Project.WorktreeSync do
  @moduledoc """
  Serializes face alignment and issue-ref fetches through one GenServer instance.
  Code alignment fetches then refuses visible dirty state before resetting to
  origin/main. Ops and workshop rebase with autostash to preserve local commits.

  This is not a lock against humans, OpsObjectSync or other server instances.
  Status checks and Git mutations can race with external writers. A clean code
  tree can still contain local commits that reset removes from the current branch.
  Ignored files and changes hidden by Git settings are not protected by porcelain status.

  Requests do not schedule retries or guarantee convergence. Cast results are
  discarded after logging; calls return operation results subject to their timeout.
  """

  use GenServer

  require Logger

  alias Fleet.Layout
  alias Fleet.Project.GitOps

  @code_root Layout.code_root()

  @spec start_link(keyword()) :: GenServer.on_start()
  def start_link(opts \\ []) do
    GenServer.start_link(__MODULE__, opts, name: Keyword.get(opts, :name, __MODULE__))
  end

  @doc """
  Casts an alignment request; :ok acknowledges sending, not successful alignment.
  Unknown face branches return an internal error; clones without a .git directory
  are skipped (including linked worktrees whose .git is a file).
  """
  @spec sync(GenServer.server(), String.t(), String.t()) :: :ok
  def sync(server \\ __MODULE__, repo, branch), do: GenServer.cast(server, {:sync, repo, branch})

  @doc "SYNCHRONOUS variant (blocking usage / tests): aligns `repo`'s face worktree, returns the git result."
  @spec sync_now(GenServer.server(), String.t(), String.t()) :: :ok | {:error, term()}
  def sync_now(server \\ __MODULE__, repo, branch),
    do: GenServer.call(server, {:sync, repo, branch}, 60_000)

  @doc """
  Fetches matching lcars/issue-<n>-* branches into refs/lcars/pr/<n>/* in the code clone.
  Host-side fetching lets a read-only architect mount inspect deliverables without
  writing FETCH_HEAD. Named refs survive unrelated fetches; --force permits rewrites.

  Returns locally enumerated refs after fetch, without pruning deleted remote branches:
  stale refs can remain in the list. No .git directory returns :no_local_clone.
  The call timeout is 60 seconds and does not cancel server work; issue_n is interpolated
  without a runtime positivity/type guard.
  """
  @spec fetch_issue_refs(GenServer.server(), String.t(), pos_integer()) ::
          {:ok, [String.t()]} | {:error, term()}
  def fetch_issue_refs(server \\ __MODULE__, repo, issue_n),
    do: GenServer.call(server, {:fetch_issue_refs, repo, issue_n}, 60_000)

  @impl GenServer
  def init(opts) do
    {:ok,
     %{
       root: Keyword.get(opts, :code_root, @code_root),
       ops_root: Keyword.get(opts, :ops_root, Layout.ops_root()),
       workshop_root: Keyword.get(opts, :workshop_root, Layout.workshop_root())
     }}
  end

  @impl GenServer
  def handle_cast({:sync, repo, branch}, state) do
    _ = do_sync(repo, branch, state)
    {:noreply, state}
  end

  @impl GenServer
  def handle_call({:sync, repo, branch}, _from, state) do
    {:reply, do_sync(repo, branch, state), state}
  end

  @impl GenServer
  def handle_call({:fetch_issue_refs, repo, issue_n}, _from, state) do
    {:reply, do_fetch_issue_refs(repo, issue_n, state), state}
  end

  defp do_sync(repo, branch, state) do
    name = Layout.project_name(repo)

    # Explicit face routing prevents a new face from silently using the code aligner.
    {dir, aligner} =
      case Layout.face_of(branch) do
        "code" ->
          {Path.join(state.root, name), &align_code/1}

        "workshop" ->
          {Path.join(state.workshop_root, name), &align_writer(&1, Layout.workshop_branch())}

        "ops" ->
          {Path.join(state.ops_root, name), &align_writer(&1, Layout.ops_branch())}

        nil ->
          {nil, nil}
      end

    cond do
      is_nil(dir) ->
        # A fleet PR only merges into a face; anything else here is a caller bug — loud, no guess.
        Logger.warning(
          "WorktreeSync: #{repo} — branch #{inspect(branch)} is neither face, NO worktree aligned " <>
            "(a fleet PR only merges into a face; fix the caller)"
        )

        {:error, {:not_a_face, branch}}

      File.dir?(Path.join(dir, ".git")) ->
        log_result(repo, dir, branch, aligner.(dir))

      true ->
        # No local worktree (project onboarded on another machine, or folder deleted by hand):
        # nothing to align, this is not an error (the deliverable remains viewable on the forge).
        Logger.debug("WorktreeSync: #{repo} — no local worktree at #{dir}, skip")
        :ok
    end
  end

  # The human's code directory can contain uncommitted work. Refuse visible dirt
  # rather than accumulating implicit stashes; callers must serialize external writers.
  defp align_code(dir) do
    with :ok <-
           GitOps.run(["-C", dir, "fetch", "origin", Layout.code_branch()], auth: true),
         :ok <- refuse_if_dirty(dir) do
      GitOps.run(["-C", dir, "reset", "--hard", "origin/" <> Layout.code_branch()],
        auth: false
      )
    end
  end

  # A failed status read is not evidence of cleanliness. Empty output is only
  # the current porcelain observation, not a guarantee that reset cannot lose data.
  defp refuse_if_dirty(dir) do
    case GitOps.read(["-C", dir, "status", "--porcelain"], auth: false) do
      {:ok, ""} ->
        :ok

      {:ok, dirty} ->
        Logger.error(
          "WorktreeSync: #{dir} has UNCOMMITTED changes — alignment REFUSED (a `reset --hard` " <>
            "would destroy them with no copy and no recovery). This face is rooted at the human's " <>
            "working directory, so what is here may exist NOWHERE else. Commit, stash or discard, " <>
            "then the next tick aligns. Showcase stays stale meanwhile — nothing depends on it " <>
            "(pods clone from the forge).\n#{dirty}"
        )

        {:error, {:worktree_dirty, dir}}

      {:error, reason} ->
        Logger.error(
          "WorktreeSync: #{dir} — could not read `git status` (#{inspect(reason)}); alignment " <>
            "REFUSED rather than resetting on an unknown state"
        )

        {:error, {:status_unreadable, dir, reason}}
    end
  end

  # Writer faces keep local commits through rebase. FETCH_HEAD works even when a
  # single-branch clone does not maintain origin/<branch>. Autostash is not a guarantee
  # of conflict-free restoration. Any rebase error is tagged rebase_conflict; abort
  # is attempted but its result is ignored.
  defp align_writer(dir, branch) do
    with :ok <- GitOps.run(["-C", dir, "fetch", "origin", branch], auth: true) do
      # Replaying local commits needs a committer. Writer faces are published by the system, and
      # their guard admits only its address: without it the rebase stops half-way on a host whose
      # human has no Git identity (measured on a bench, 2026-09-23), or commits as `login@hostname`.
      %{name: name, email: email} = Fleet.Credentials.ForgeIdentity.system_identity()
      identity = ["-c", "user.name=#{name}", "-c", "user.email=#{email}"]

      case GitOps.run(["-C", dir | identity] ++ ["rebase", "--autostash", "FETCH_HEAD"],
             auth: false
           ) do
        :ok ->
          :ok

        {:error, reason} ->
          _ = GitOps.run(["-C", dir, "rebase", "--abort"], auth: false)
          {:error, {:rebase_conflict, branch, reason}}
      end
    end
  end

  defp do_fetch_issue_refs(repo, issue_n, state) do
    dir = Path.join(state.root, Layout.project_name(repo))

    if File.dir?(Path.join(dir, ".git")) do
      spec = "refs/heads/lcars/issue-#{issue_n}-*:refs/lcars/pr/#{issue_n}/*"

      with :ok <- GitOps.run(["-C", dir, "fetch", "--force", "origin", spec], auth: true),
           {:ok, out} <-
             GitOps.read(
               ["-C", dir, "for-each-ref", "--format=%(refname)", "refs/lcars/pr/#{issue_n}/"],
               auth: false
             ) do
        refs = out |> String.split("\n", trim: true)

        Logger.info(
          "WorktreeSync: #{repo}##{issue_n} → #{length(refs)} ref(s) readable in #{dir}"
        )

        {:ok, refs}
      end
    else
      {:error, {:no_local_clone, dir}}
    end
  end

  defp log_result(repo, dir, branch, :ok) do
    Logger.info("WorktreeSync: #{repo} → #{dir} aligned on origin/#{branch}")
    :ok
  end

  defp log_result(repo, _dir, _branch, {:error, reason} = err) do
    Logger.warning(
      "WorktreeSync: #{repo} alignment failed (#{inspect(reason)}) — the deliverable stays on the forge"
    )

    err
  end
end
