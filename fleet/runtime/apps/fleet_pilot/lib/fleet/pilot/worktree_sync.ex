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

  ## Best-effort and convergent

  `sync/2` is a **cast**: the merge does not wait for it (hot-path intact) and the deliverable is already on the
  forge — a failed alignment is only a disk behind, never a loss. The alignment is
  **convergent and idempotent**: `reset --hard origin/main` brings back the LATEST `main`, no matter how many
  merges happened between the cast and its handling. We don't try to match a precise merge: we
  want "clone == latest `main`". The timing with the merges therefore has no functional importance —
  that's what makes the non-coalescence inconsequential (the lease already spaces out the merges of a same repo).
  """

  use GenServer

  require Logger

  alias Fleet.Pilot.GitOps

  # Derives from the single authority of the container layout (Fleet.Layout, R0).
  @projects_root Fleet.Layout.projects_root()

  def start_link(opts \\ []) do
    GenServer.start_link(__MODULE__, opts, name: Keyword.get(opts, :name, __MODULE__))
  end

  @doc "Requests (best-effort, serialized) the alignment of `repo`'s local clone onto `origin/main`."
  @spec sync(GenServer.server(), String.t()) :: :ok
  def sync(server \\ __MODULE__, repo), do: GenServer.cast(server, {:sync, repo})

  @doc "SYNCHRONOUS variant (blocking usage / tests): aligns `repo` and returns the git result."
  @spec sync_now(GenServer.server(), String.t()) :: :ok | {:error, term()}
  def sync_now(server \\ __MODULE__, repo), do: GenServer.call(server, {:sync, repo}, 60_000)

  @impl GenServer
  def init(opts) do
    {:ok, %{root: Keyword.get(opts, :projects_root, @projects_root)}}
  end

  # cast (prod) and call (blocking / tests) share `do_sync`. The GenServer handles one message at a time
  # → the alignments are serialized, never two concurrent `git` on the same worktree.
  @impl GenServer
  def handle_cast({:sync, repo}, state) do
    _ = do_sync(repo, state.root)
    {:noreply, state}
  end

  @impl GenServer
  def handle_call({:sync, repo}, _from, state) do
    {:reply, do_sync(repo, state.root), state}
  end

  defp do_sync(repo, root) do
    # The forge repo is `<org>/<name>`; the local clone lives under `<root>/<name>` (final segment).
    name = repo |> String.split("/") |> List.last()
    dir = Path.join(root, name)

    if File.dir?(Path.join(dir, ".git")) do
      log_result(repo, dir, align(dir))
    else
      # No local clone (project onboarded on another machine, or folder deleted by hand):
      # nothing to align, this is not an error (the deliverable remains viewable on the forge).
      Logger.debug("WorktreeSync: #{repo} — pas de clone local en #{dir}, skip")
      :ok
    end
  end

  # `fetch` (network, forge token) then `reset --hard`: the `main` worktree takes the latest `origin/main`.
  # The worktree is a read-only showcase (the pods work in their ephemeral clones) → `reset --hard`
  # overwrites nothing useful, and guarantees convergence even if something had diverged.
  defp align(dir) do
    with :ok <- GitOps.run(["-C", dir, "fetch", "origin", "main"], auth: true) do
      GitOps.run(["-C", dir, "reset", "--hard", "origin/main"], auth: false)
    end
  end

  defp log_result(repo, dir, :ok) do
    Logger.info("WorktreeSync: #{repo} → #{dir} aligné sur origin/main")
    :ok
  end

  defp log_result(repo, _dir, {:error, reason} = err) do
    Logger.warning(
      "WorktreeSync: #{repo} alignement échoué (#{inspect(reason)}) — le livrable reste sur la forge"
    )

    err
  end
end
