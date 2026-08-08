defmodule Fleet.Pilot.WorktreeSync do
  @moduledoc """
  Serializes post-merge projection onto local worktrees. Code-face mirrors reset
  to forge `main`; writer-owned ops faces rebase with autostash. Async requests
  converge on the latest remote state and failures remain retryable.
  """

  use GenServer

  require Logger

  alias Fleet.Pilot.GitOps

  @projects_root Fleet.Layout.projects_root()

  def start_link(opts \\ []) do
    GenServer.start_link(__MODULE__, opts, name: Keyword.get(opts, :name, __MODULE__))
  end

  @doc """
  Requests serialized alignment of the repository worktree selected by `branch`.
  """
  @spec sync(GenServer.server(), String.t(), String.t()) :: :ok
  def sync(server \\ __MODULE__, repo, branch), do: GenServer.cast(server, {:sync, repo, branch})

  @doc "SYNCHRONOUS variant (blocking usage / tests): aligns `repo`'s face worktree, returns the git result."
  @spec sync_now(GenServer.server(), String.t(), String.t()) :: :ok | {:error, term()}
  def sync_now(server \\ __MODULE__, repo, branch),
    do: GenServer.call(server, {:sync, repo, branch}, 60_000)

  @impl GenServer
  def init(opts) do
    {:ok,
     %{
       root: Keyword.get(opts, :projects_root, @projects_root),
       work_root: Keyword.get(opts, :work_root, Fleet.Layout.work_root())
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

  defp do_sync(repo, branch, state) do
    name = Fleet.Layout.project_name(repo)

    # One clause per face and NO catch-all: the day `@face_branches` names a third one, this case
    # raises with the face in the message instead of quietly routing it to a worktree that is not
    # its own. A crash that names the missing branch is a two-minute fix; a doc deliverable
    # realigned into the code worktree is a corruption nobody attributes.
    {dir, aligner} =
      case Fleet.Layout.face_of(branch) do
        "code" -> {Path.join(state.root, name), &align_code/1}
        "ops" -> {Path.join(state.work_root, name), &align_ops/1}
        nil -> {nil, nil}
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

  # CODE face: `fetch` (network, forge token) then `reset --hard` — the worktree is a read-only
  # showcase (the pods work in their ephemeral clones) → `reset --hard` overwrites nothing useful,
  # and guarantees convergence even if something had diverged.
  defp align_code(dir) do
    with :ok <- GitOps.run(["-C", dir, "fetch", "origin", Fleet.Layout.code_branch()], auth: true) do
      GitOps.run(["-C", dir, "reset", "--hard", "origin/" <> Fleet.Layout.code_branch()],
        auth: false
      )
    end
  end

  # OPS face: the worktree is a WRITER — rebase local commits on top of the merged remote tip,
  # never reset (§C). `FETCH_HEAD` (not `origin/work/ops`): a `--single-branch` clone's refspec
  # may not maintain the remote-tracking ref, FETCH_HEAD is exact by construction. `--autostash`
  # carries the arch's uncommitted edits across. A conflicted rebase is ABORTED so the worktree
  # stays usable (a half-applied rebase would wedge OpsObject and every brief after it), and the
  # error propagates loud: that divergence is a human's call.
  defp align_ops(dir) do
    with :ok <- GitOps.run(["-C", dir, "fetch", "origin", Fleet.Layout.ops_branch()], auth: true) do
      case GitOps.run(["-C", dir, "rebase", "--autostash", "FETCH_HEAD"], auth: false) do
        :ok ->
          :ok

        {:error, reason} ->
          _ = GitOps.run(["-C", dir, "rebase", "--abort"], auth: false)
          {:error, {:ops_rebase_conflict, reason}}
      end
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
