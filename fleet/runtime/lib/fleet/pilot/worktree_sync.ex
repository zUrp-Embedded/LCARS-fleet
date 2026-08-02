defmodule Fleet.Pilot.WorktreeSync do
  @moduledoc """
  Projection of the deliverable onto the local clone after merge — dedicated serializer.

  On the terminal merge of a PR (`Fleet.Pilot.GatekeeperSeal.seal_and_merge`), `origin/main` advances on the
  forge, but the local clone `/home/projects/<name>` (the `main` worktree, designated "the deliverable" by
  `Fleet.Pilot.ProjectOnboard`) does not follow on its own: it stays frozen at onboarding. This module aligns it
  — `git fetch origin main` then `git reset --hard origin/main`.

  ## Why a process (Iron Law): the SERIALIZATION

  The merge has TWO triggers that can run at the same time:

    * the poller (`Fleet.Pilot.StepDispatcher.promote_pr`), mono-process;
    * the StepRunConsumer (`Fleet.Pilot.StepRunCompleter.promote`), **offloaded into a `Task`**.

  Two simultaneous `reset --hard` on the SAME worktree corrupt the index (`index.lock`). Resting
  safety on the "1 active pipeline/repo" lease would be praying against the race: that lease is a
  LOGICAL invariant of the poller (the code itself says "no lock, mono-process poller"), not a physical lock
  on disk. This GenServer closes the race by construction: it handles one message at a time → one `git`
  at a time, whatever the number of triggers.

  ## Fast-path mirror — the truth lives on the forge

  `sync/2` is a **cast**: the merge does not wait for it (hot-path intact) and the deliverable is already on the
  forge — the local clone is a MIRROR; a failed alignment is only a disk behind, never a loss, and is
  logged warning by `log_result`. The alignment is **convergent and idempotent**: `reset --hard origin/main`
  re-derives the FULL state (absolute, not incremental) — the next sync (every later merge casts one, or a
  manual `sync_now/2`) brings back the LATEST `main`, no matter how many merges happened between the cast
  and its handling, and heals any previously missed alignment. We don't try to match a precise merge: we
  want "clone == latest `main`". The timing with the merges therefore has no functional importance —
  that's what makes the non-coalescence inconsequential (the lease already spaces out the merges of a same repo).

  **Last revised**: 2026-08-02
  """

  use GenServer

  require Logger

  alias Fleet.Pilot.GitOps

  # Derives from the single authority of the container layout (Fleet.Layout).
  @projects_root Fleet.Layout.projects_root()

  def start_link(opts \\ []) do
    GenServer.start_link(__MODULE__, opts, name: Keyword.get(opts, :name, __MODULE__))
  end

  @doc """
  Requests (async cast, serialized) the alignment of the worktree of `branch`'s FACE for `repo`.
  The branch names the face (chantier face-projet), and the face names BOTH the worktree and the
  alignment semantics — they are not symmetric (inventory §C):

    * code face (`main`) → `<projects_root>/<name>`, `fetch` + `reset --hard`: that worktree is a
      read-only showcase, nothing local to preserve;
    * ops face (`work/ops`) → `<work_root>/<name>`, `fetch` + `rebase --autostash FETCH_HEAD`: the
      host ops worktree is a WRITER (OpsObject commits briefs there, the arch writes its docs, a
      human their journals) — a `reset --hard` would DESTROY local commits not yet pushed. The
      rebase replays them on top of the merged deliverable; `--autostash` carries uncommitted
      edits across; a conflicted rebase is aborted (worktree left usable) and logged LOUD — that
      divergence needs a human, not a guess.

  A failure is logged warning and heals at the next sync; the truth stays on the forge.
  The `branch` is REQUIRED — the caller (the seal) knows what the PR merged into; a default here
  would re-decide the face downstream (single-default-site doctrine). A branch that is neither
  face is refused loud: a fleet PR only ever merges into a face.
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

  # cast (prod) and call (blocking / tests) share `do_sync`. The GenServer handles one message at a time
  # → the alignments are serialized, never two concurrent `git` on the same worktree.
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
    # The forge repo is `<org>/<name>`; the face worktree lives under `<face root>/<name>`.
    name = Fleet.Layout.project_name(repo)

    {dir, aligner} =
      cond do
        branch == Fleet.Layout.code_branch() ->
          {Path.join(state.root, name), &align_code/1}

        Fleet.Layout.ops_branch?(branch) ->
          {Path.join(state.work_root, name), &align_ops/1}

        true ->
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
