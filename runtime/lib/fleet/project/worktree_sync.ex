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

  ⚠ A WRITER FACE ALSO MOVES WITHOUT A MERGE. The deck's deposit door commits into the
  workshop face through the forge's content API: no PR, so no merge-triggered sync ever
  brings the file down, and the architect's next publication is rejected (seen on a bench,
  2026-09-23: the push was refused as `stale info` until the face caught up).
  `refresh/3` (cast by the poller each regular tick) and `align_before_push/3` (called by
  the architect's own writers) cover that: both read the forge's head first and touch the
  face only when it is behind.
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
  Casts a CHEAP realignment of a writer face (workshop, ops): the forge's head is read with
  `ls-remote`, and the face is fetched and rebased only when that head is not already in its
  HEAD. A face that has everything is left untouched — the architect edits it live, and an
  autostash every tick would race its editor. A code branch is refused: its aligner resets.
  A failure is logged once per episode, not once per tick.
  """
  @spec refresh(GenServer.server(), String.t(), String.t()) :: :ok
  def refresh(server \\ __MODULE__, repo, branch),
    do: GenServer.cast(server, {:refresh, repo, branch})

  @doc """
  Brings a writer-face directory level with the forge BEFORE a local writer commits and pushes
  there, so the push is not refused for a commit it never saw. Serialized with the other
  alignments when this server runs, inline otherwise. Returns `:ok`, `:up_to_date` or the git
  error — callers log it and go on: their local write stays authoritative.
  """
  @spec align_before_push(GenServer.server(), String.t(), String.t()) ::
          :ok | :up_to_date | {:error, term()}
  def align_before_push(server \\ __MODULE__, dir, branch) do
    case GenServer.whereis(server) do
      nil -> align_writer_if_behind(dir, branch)
      _ -> GenServer.call(server, {:align_dir, dir, branch}, 60_000)
    end
  end

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
       workshop_root: Keyword.get(opts, :workshop_root, Layout.workshop_root()),
       # Repos whose last refresh failed: the failure is logged on entry, the recovery on exit.
       refresh_failed: MapSet.new()
     }}
  end

  @impl GenServer
  def handle_cast({:sync, repo, branch}, state) do
    _ = do_sync(repo, branch, state)
    {:noreply, state}
  end

  @impl GenServer
  def handle_cast({:refresh, repo, branch}, state) do
    {:noreply, do_refresh(repo, branch, state)}
  end

  @impl GenServer
  def handle_call({:align_dir, dir, branch}, _from, state) do
    {:reply, align_writer_if_behind(dir, branch), state}
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

  defp do_refresh(repo, branch, state) do
    dir =
      case Layout.face_of(branch) do
        "workshop" -> Path.join(state.workshop_root, Layout.project_name(repo))
        "ops" -> Path.join(state.ops_root, Layout.project_name(repo))
        _ -> nil
      end

    cond do
      is_nil(dir) ->
        Logger.warning(
          "WorktreeSync: refresh #{repo} — #{inspect(branch)} is not a writer face, nothing done"
        )

        state

      not File.dir?(Path.join(dir, ".git")) ->
        state

      true ->
        note_refresh(repo, dir, branch, align_writer_if_behind(dir, branch), state)
    end
  end

  defp note_refresh(repo, dir, branch, {:error, reason}, state) do
    unless MapSet.member?(state.refresh_failed, repo) do
      Logger.warning(
        "WorktreeSync: #{repo} — the forge's #{branch} is AHEAD of #{dir} and the face could not " <>
          "follow (#{inspect(reason)}); what was deposited stays on the forge. Retried every tick, " <>
          "logged again only once it recovers"
      )
    end

    %{state | refresh_failed: MapSet.put(state.refresh_failed, repo)}
  end

  defp note_refresh(repo, dir, branch, result, state) do
    if result == :ok,
      do: Logger.info("WorktreeSync: #{repo} → #{dir} brought level with the forge's #{branch}")

    if MapSet.member?(state.refresh_failed, repo),
      do: Logger.info("WorktreeSync: #{repo} — #{branch} follows the forge again")

    %{state | refresh_failed: MapSet.delete(state.refresh_failed, repo)}
  end

  # `ls-remote` costs one request and touches nothing. A head absent from the local object store
  # fails `merge-base` like a head that is not an ancestor: both mean « fetch ».
  defp align_writer_if_behind(dir, branch) do
    with {:ok, out} <-
           GitOps.read(["-C", dir, "ls-remote", "origin", "refs/heads/" <> branch], auth: true) do
      case String.split(out) do
        [] -> :up_to_date
        [sha | _] -> follow_head(dir, branch, sha)
      end
    end
  end

  defp follow_head(dir, branch, sha) do
    case GitOps.run(["-C", dir, "merge-base", "--is-ancestor", sha, "HEAD"], auth: false) do
      :ok -> :up_to_date
      {:error, _} -> align_writer(dir, branch)
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
  # single-branch clone does not maintain origin/<branch>. Any rebase error is tagged
  # rebase_conflict; abort is attempted but its result is ignored.
  #
  # ⚠ A FAILED AUTOSTASH EXITS 0. When the incoming commits touch a file the writer has
  # modified, `rebase --autostash` succeeds, keeps the edit in the stash and leaves conflict
  # markers in the file; an ignored file on an incoming path is overwritten without a word.
  # The rebase is therefore refused BEFORE it starts when an incoming path carries local work,
  # and an unmerged path left after it is reported, never read as success.
  defp align_writer(dir, branch) do
    with :ok <- GitOps.run(["-C", dir, "fetch", "origin", branch], auth: true),
         :ok <- refuse_if_local_work_in_the_way(dir, branch) do
      # Replaying local commits needs a committer. Writer faces are published by the system, and
      # their guard admits only its address: without it the rebase stops half-way on a host whose
      # human has no Git identity (measured on a bench, 2026-09-23), or commits as `login@hostname`.
      %{name: name, email: email} = Fleet.Credentials.ForgeIdentity.system_identity()
      identity = ["-c", "user.name=#{name}", "-c", "user.email=#{email}"]

      case GitOps.run(["-C", dir | identity] ++ ["rebase", "--autostash", "FETCH_HEAD"],
             auth: false
           ) do
        :ok ->
          refuse_if_unmerged(dir, branch)

        {:error, reason} ->
          _ = GitOps.run(["-C", dir, "rebase", "--abort"], auth: false)
          {:error, {:rebase_conflict, branch, reason}}
      end
    end
  end

  defp refuse_if_local_work_in_the_way(dir, branch) do
    with {:ok, incoming} <- paths(dir, ["diff", "--name-only", "-z", "HEAD...FETCH_HEAD"]),
         {:ok, changed} <- paths(dir, ["diff", "--name-only", "-z", "HEAD"]),
         {:ok, others} <- paths(dir, ["ls-files", "--others", "-z"]) do
      in_the_way = MapSet.intersection(MapSet.new(incoming), MapSet.new(changed ++ others))

      if MapSet.size(in_the_way) == 0,
        do: :ok,
        else:
          {:error, {:local_work_in_the_way, branch, in_the_way |> Enum.sort() |> Enum.take(10)}}
    end
  end

  defp refuse_if_unmerged(dir, branch) do
    case paths(dir, ["diff", "--name-only", "-z", "--diff-filter=U"]) do
      {:ok, []} -> :ok
      {:ok, unmerged} -> {:error, {:unmerged_after_rebase, branch, Enum.take(unmerged, 10)}}
      {:error, _} = err -> err
    end
  end

  defp paths(dir, args) do
    with {:ok, out} <- GitOps.read(["-C", dir | args], auth: false) do
      {:ok, String.split(out, <<0>>, trim: true)}
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
