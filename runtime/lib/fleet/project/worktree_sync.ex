defmodule Fleet.Project.WorktreeSync do
  @moduledoc """
  Serializes post-merge projection onto the local face clones. The code face is a MIRROR — nobody
  writes it locally — so it resets hard to the forge. The two WRITER faces, `ops` and `doc`, rebase
  with autostash: something holds a live pen on them (the runtime on `ops`, the architect and the
  human on `doc`), and a reset would erase work that exists nowhere else. Async requests converge on
  the latest remote state and failures remain retryable.
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
  Requests serialized alignment of the repository worktree selected by `branch`.
  """
  @spec sync(GenServer.server(), String.t(), String.t()) :: :ok
  def sync(server \\ __MODULE__, repo, branch), do: GenServer.cast(server, {:sync, repo, branch})

  @doc "SYNCHRONOUS variant (blocking usage / tests): aligns `repo`'s face worktree, returns the git result."
  @spec sync_now(GenServer.server(), String.t(), String.t()) :: :ok | {:error, term()}
  def sync_now(server \\ __MODULE__, repo, branch),
    do: GenServer.call(server, {:sync, repo, branch}, 60_000)

  @doc """
  Makes the feature branches of issue `n` READABLE in the project's code worktree, under
  `refs/lcars/pr/<n>/<role>`. Returns the refs that landed.

  WHY THE RUNTIME DOES THIS AND NOT THE POD. The architect arbitrates on deliverables and its code
  face is a read-only bind, so its own `git fetch` dies on `.git/FETCH_HEAD` — measured from inside
  the pod. What that costs is not the missing diff: it arbitrates ANYWAY and invents an explanation
  for what it cannot see. The fetch happens host-side, in the worktree this GenServer already
  serializes, and the pod only READS the result through its bind.

  A NAMED ref per role, not `FETCH_HEAD`. `FETCH_HEAD` is overwritten by the next fetch and does not
  say what it is the head OF — measured, a pod declares its code face "frozen" while that file is
  two minutes old. `refs/lcars/pr/<n>/<role>` is stable, self-describing, and survives the next
  fetch.

  A WILDCARD refspec, so no forge read is needed to learn the producer's role: every branch of the
  ticket lands, whichever role opened it, and an escalation covering several of them gets all of
  them. `--force` because a re-push moves the branch and the local ref would refuse a non-fast-
  forward — this mirror has no history worth protecting.
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

    # One clause per face and NO catch-all: the day `@face_branches` names a third one, this case
    # raises with the face in the message instead of quietly routing it to a worktree that is not
    # its own. A crash that names the missing branch is a two-minute fix; a doc deliverable
    # realigned into the code worktree is a corruption nobody attributes.
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

  # CODE face: `fetch` (network, forge token) then `reset --hard` — convergence dure vers l'origine.
  #
  # ⚠ « CETTE VITRINE EST EN LECTURE SEULE » N'EST GARANTI PAR RIEN. La racine de cette face est
  # `Fleet.Layout.code_root/0` = **`/home/projects`** — le repertoire de travail par defaut de
  # l'humain, pas un dossier de la flotte. Les pods travaillent bien dans leurs clones ephemeres,
  # mais rien n'empeche un humain (ou un agent lance a la main) d'y avoir un fichier modifie non
  # commite. `reset --hard` le detruit sans copie, sans message, sans recuperation possible.
  #
  # La soeur `align_writer/2` tient deja la posture : sur une divergence,
  # elle ABANDONNE et propage fort — « that divergence is a human's call ». Meme regle ici : un
  # arbre SALE n'est pas aligne, il est REFUSE, bruyamment et avec la sortie de `status` pour que
  # l'humain voie ce qui l'a bloque.
  #
  # ⚠ POURQUOI PAS `--autostash` COMME LA SOEUR : sur une face que personne ne relit, une pile de
  # stashes s'accumulerait en silence — on aurait echange une destruction visible contre une perte
  # differee que personne ne va chercher. Le refus, lui, se voit au tick suivant et la vitrine
  # reste simplement perimee : elle n'est load-bearing pour rien (les pods clonent depuis la forge).
  defp align_code(dir) do
    with :ok <-
           GitOps.run(["-C", dir, "fetch", "origin", Layout.code_branch()], auth: true),
         :ok <- refuse_if_dirty(dir) do
      GitOps.run(["-C", dir, "reset", "--hard", "origin/" <> Layout.code_branch()],
        auth: false
      )
    end
  end

  # `status --porcelain` rend une sortie VIDE sur un arbre propre : c'est le seul etat ou un
  # `reset --hard` ne peut rien detruire. Une lecture qui echoue n'est pas un arbre propre — on
  # refuse aussi, plutot que de reset sur une ignorance.
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

  # WRITER faces (`ops` and `doc`): the clone is a WRITER — rebase local commits on top of the
  # merged remote tip, never reset (§C). The two share this because they share the property that
  # decides it: something holds a live pen on that clone — the runtime on `ops`, the architect and
  # the human on `doc` — so a reset would erase work that exists nowhere else. `code` is the only
  # face where nobody writes locally, which is why it is the only one that may reset.
  #
  # `FETCH_HEAD` (not `origin/<branch>`): a `--single-branch` clone's refspec may not maintain the
  # remote-tracking ref, FETCH_HEAD is exact by construction. `--autostash` carries uncommitted
  # edits across. A conflicted rebase is ABORTED so the clone stays usable (a half-applied rebase
  # would wedge every object written after it), and the error propagates loud: that divergence is a
  # human's call.
  defp align_writer(dir, branch) do
    with :ok <- GitOps.run(["-C", dir, "fetch", "origin", branch], auth: true) do
      case GitOps.run(["-C", dir, "rebase", "--autostash", "FETCH_HEAD"], auth: false) do
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

    cond do
      not File.dir?(Path.join(dir, ".git")) ->
        {:error, {:no_local_clone, dir}}

      true ->
        spec = "refs/heads/lcars/issue-#{issue_n}-*:refs/lcars/pr/#{issue_n}/*"

        with :ok <- GitOps.run(["-C", dir, "fetch", "--force", "origin", spec], auth: true),
             {:ok, out} <-
               GitOps.read(
                 [
                   "-C",
                   dir,
                   "for-each-ref",
                   "--format=%(refname)",
                   "refs/lcars/pr/#{issue_n}/"
                 ],
                 auth: false
               ) do
          refs = out |> String.split("\n", trim: true)

          Logger.info(
            "WorktreeSync: #{repo}##{issue_n} → #{length(refs)} ref(s) readable in #{dir}"
          )

          {:ok, refs}
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
