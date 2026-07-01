defmodule Fleet.Pilot.WorktreeSync do
  @moduledoc """
  Projection du livrable sur le clone local après merge — sérialiseur dédié.

  Au merge terminal d'une PR (`Fleet.Pilot.GatekeeperSeal.seal_and_merge`), `origin/main` avance sur la
  forge, mais le clone local `/home/projects/<name>` (le worktree `main`, désigné « le livrable » par
  `Fleet.Pilot.ProjectOnboard`) ne suit pas tout seul : il reste figé à l'onboarding. Ce module l'aligne
  — `git fetch origin main` puis `git reset --hard origin/main`.

  ## Pourquoi un process (Iron Law) : la SÉRIALISATION

  Le merge a DEUX déclencheurs qui peuvent tourner en même temps :

    * le poller (`Fleet.Pilot.StageDispatcher.promote_pr`), mono-process ;
    * le StepRunConsumer (`Fleet.Pilot.StepRunCompleter.promote`), **offloadé dans une `Task`**.

  Deux `reset --hard` simultanés sur le MÊME worktree corrompent l'index (`index.lock`). Faire reposer
  la sûreté sur le bail « 1 pipeline actif/repo » serait prier contre la race : ce bail est un invariant
  LOGIQUE du poller (le code dit lui-même « pas de verrou, poller mono-process »), pas un verrou physique
  sur le disque. Ce GenServer ferme la race par construction : il traite un message à la fois → un `git`
  à la fois, quel que soit le nombre de déclencheurs.

  ## Best-effort et convergent

  `sync/2` est un **cast** : le merge ne l'attend pas (hot-path intact) et le livrable est déjà sur la
  forge — un alignement raté n'est qu'un disque en retard, jamais une perte. L'alignement est
  **convergent et idempotent** : `reset --hard origin/main` ramène le DERNIER `main`, peu importe combien
  de merges ont eu lieu entre le cast et son traitement. On ne cherche pas à matcher un merge précis : on
  veut « clone == dernier `main` ». Le timing avec les merges n'a donc aucune importance fonctionnelle —
  c'est ce qui rend la non-coalescence sans conséquence (le bail espace déjà les merges d'un même repo).
  """

  use GenServer

  require Logger

  alias Fleet.Pilot.GitOps

  @projects_root "/home/projects"

  def start_link(opts \\ []) do
    GenServer.start_link(__MODULE__, opts, name: Keyword.get(opts, :name, __MODULE__))
  end

  @doc "Demande (best-effort, sérialisée) l'alignement du clone local de `repo` sur `origin/main`."
  @spec sync(GenServer.server(), String.t()) :: :ok
  def sync(server \\ __MODULE__, repo), do: GenServer.cast(server, {:sync, repo})

  @doc "Variante SYNCHRONE (usage bloquant / tests) : aligne `repo` et renvoie le résultat git."
  @spec sync_now(GenServer.server(), String.t()) :: :ok | {:error, term()}
  def sync_now(server \\ __MODULE__, repo), do: GenServer.call(server, {:sync, repo}, 60_000)

  @impl GenServer
  def init(opts) do
    {:ok, %{root: Keyword.get(opts, :projects_root, @projects_root)}}
  end

  # cast (prod) et call (bloquant / tests) partagent `do_sync`. Le GenServer traite un message à la fois
  # → les alignements sont sérialisés, jamais deux `git` concurrents sur un même worktree.
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
    # Le repo forge est `<org>/<name>` ; le clone local vit sous `<root>/<name>` (segment final).
    name = repo |> String.split("/") |> List.last()
    dir = Path.join(root, name)

    if File.dir?(Path.join(dir, ".git")) do
      log_result(repo, dir, align(dir))
    else
      # Pas de clone local (projet onboardé sur une autre machine, ou dossier supprimé à la main) :
      # rien à aligner, ce n'est pas une erreur (le livrable reste consultable sur la forge).
      Logger.debug("WorktreeSync: #{repo} — pas de clone local en #{dir}, skip")
      :ok
    end
  end

  # `fetch` (réseau, token forge) puis `reset --hard` : le worktree `main` prend le dernier `origin/main`.
  # Le worktree est une vitrine read-only (les pods bossent dans leurs clones éphémères) → `reset --hard`
  # n'écrase rien d'utile, et garantit la convergence même si quelque chose avait divergé.
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
