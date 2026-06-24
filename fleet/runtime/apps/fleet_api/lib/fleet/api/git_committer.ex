defmodule Fleet.API.GitCommitter do
  @moduledoc """
  GenServer wrapper atomic write + git auto commit.

  Canon trace strate 1 : toute directive active doit être traçable en
  git. Tout changement de config via API/UI → commit auto git côté
  backend (l'historique git EST la trace d'audit des changements config).

  ## Workflow

  1. Write atomique : `<file>.tmp` + `File.rename` (rename atomique
     POSIX, pas de file partiel)
  2. `git add <file>` (cwd = repo config)
  3. `git commit -m "config: <file> updated by <user>"`

  ## Sérialisation

  Le GenServer **sérialise** tous les commits (call queue) pour éviter
  les race conditions sur le repo git partagé :

    * 2 callers concurrents pourraient interleaver `git add` → un
      `commit` pourrait inclure les fichiers de l'autre (staged).
    * Le rollback (snapshot → restore après échec git) n'est pas safe
      cross-thread (T2 modifie le fichier pendant le rollback de T1).

  Le call `commit_config_change/3` continue d'être l'API publique
  (transparent côté caller) — route vers `GenServer.call`, queue FIFO,
  un commit à la fois. Pas de cycle (zero state — GenServer = juste
  un mutex sérialiseur).

  ## Configuration

    * `:fleet_api, :git_repo_path` — racine repo config
      (default `/var/lib/lcars/config`)

  ## Errors

  Tout échec (write/rename/git) → `{:error, reason}` (loggé).
  """

  use GenServer
  require Logger

  @default_repo "/var/lib/lcars/config"
  # Timeout call : un commit peut prendre plusieurs secondes (git push
  # eventuel out-of-scope ici, mais git add/commit local + I/O FS = ~ms).
  # 30s = large garde-fou caller-side.
  @call_timeout_ms 30_000

  # Source UNIQUE de la neutralisation config git (hooks/fsmonitor/sshCommand/diff.external/attributesFile
  # global), composée sur les ops git système-side du repo de config (potentiellement co-écrit). Pas de 2e
  # copie de la liste de tournevis ici — `Fleet.Credentials.Shell` la porte pour TOUT le runtime.
  @git_safe_config Fleet.Credentials.Shell.git_safe_config_args()

  @doc false
  @spec start_link(keyword()) :: GenServer.on_start()
  def start_link(opts \\ []) do
    GenServer.start_link(__MODULE__, opts, name: __MODULE__)
  end

  @impl GenServer
  def init(_opts) do
    # Pas de state mutable — le GenServer est un sérialiseur pur.
    {:ok, %{}}
  end

  @impl GenServer
  def handle_call({:commit, file_path, content, user_id}, _from, state) do
    {:reply, do_commit_serialized(file_path, content, user_id), state}
  end

  @doc """
  Atomic write `content` vers `file_path` puis `git add` + `git commit`.

  `file_path` doit être un chemin relatif au repo `:git_repo_path`.

  Returns `{:ok, sha}` (commit SHA) ou `{:error, reason}`.

  Sérialisé via le GenServer (call queue FIFO) — un commit à la fois.
  """
  @spec commit_config_change(
          file_path :: String.t(),
          content :: iodata(),
          user_id :: String.t()
        ) :: {:ok, String.t()} | {:error, String.t()}
  def commit_config_change(file_path, content, user_id)
      when is_binary(file_path) and is_binary(user_id) do
    GenServer.call(__MODULE__, {:commit, file_path, content, user_id}, @call_timeout_ms)
  end

  defp do_commit_serialized(file_path, content, user_id) do
    cwd = git_repo_path()

    case safe_abs_path(cwd, file_path) do
      {:ok, abs_path} ->
        do_commit(cwd, file_path, abs_path, content, user_id)

      {:error, why} ->
        Logger.error("git_committer path rejected: #{inspect(file_path)} (#{why})")
        {:error, "invalid file_path: #{why}"}
    end
  end

  # Confinement RÉEL (pas lexical-only) : `file_path` DOIT désigner un fichier STRICTEMENT SOUS le repo.
  # Le @doc annonce « relatif au repo » ; cette fonction l'ENFORCE par construction. Quatre verrous
  # fail-closed, chacun fermant une évasion concrète d'un repo de config potentiellement co-écrit :
  #
  #   1. chemin absolu refusé (`/etc/passwd`) ;
  #   2. composant `.git` refusé (`.git/config`, `.git/hooks/pre-commit`) — sinon un update « de config »
  #      réécrirait la plomberie git du repo (armer un hook / un filtre exécuté côté monde au commit) ;
  #   3. confinement NON-LEXICAL : on résout les symlinks des composants EXISTANTS du chemin avant de
  #      vérifier le préfixe. `Path.expand` est lexical (résout `..`, PAS les liens) → un symlink présent
  #      dans le repo (`link -> /home/x`) laisserait `File.write`/`File.rename` SUIVRE le lien et écrire un
  #      fichier HÔTE arbitraire. On `lstat` chaque composant existant et on refuse s'il est un symlink ;
  #   4. le résultat résolu doit rester `== root` exclu (cf. `do_commit` rejette `abs == root`) ou sous
  #      `root <> "/"`.
  defp safe_abs_path(cwd, file_path) do
    root = Path.expand(cwd)

    cond do
      Path.type(file_path) != :relative ->
        {:error, "absolute path"}

      dotgit_component?(file_path) ->
        {:error, "dotgit path"}

      symlink_in_chain?(root, file_path) ->
        {:error, "symlink in path"}

      true ->
        abs = Path.expand(Path.join(root, file_path))

        if abs == root or String.starts_with?(abs, root <> "/") do
          {:ok, abs}
        else
          {:error, "path escapes repo"}
        end
    end
  end

  # Vrai si UN composant du chemin relatif est exactement `.git` (`.git/config`, `a/.git/x`). Comparaison
  # sur les COMPOSANTS, pas un substring : `.gitignore`/`foo.git` ne sont pas un composant `.git`.
  defp dotgit_component?(rel_path) do
    rel_path |> Path.split() |> Enum.any?(&(&1 == ".git"))
  end

  # Vrai si un composant EXISTANT du chemin (de la racine au fichier) est un symlink. `File.lstat` ne
  # suit pas le lien (stat le lien lui-même) → on détecte le vecteur d'évasion AVANT tout write/rename.
  # Même approche que la validation de payload côté pipeline (détection lstat par composant).
  defp symlink_in_chain?(root, rel_path) do
    rel_path
    |> Path.split()
    |> Enum.scan(root, fn part, acc -> Path.join(acc, part) end)
    |> Enum.any?(&symlink?/1)
  end

  defp symlink?(path) do
    case File.lstat(path) do
      {:ok, %File.Stat{type: :symlink}} -> true
      _ -> false
    end
  end

  defp do_commit(cwd, file_path, abs_path, content, user_id) do
    cond do
      # `file_path` doit désigner un fichier STRICTEMENT SOUS la racine, JAMAIS la racine elle-même
      # (cas `""`/`"."`). Sinon `tmp_path = abs_path <> ".tmp"` = `<root>.tmp`, un SIBLING de la racine
      # → écriture HORS du repo confiné (et un rename de la racine n'a aucun sens). Refus fail-closed.
      abs_path == Path.expand(cwd) ->
        Logger.error("git_committer path is repo root: #{inspect(file_path)}")
        {:error, "invalid file_path: path is repo root"}

      not is_binary(content) ->
        # Garde-fou : la route matche la PRÉSENCE de la clé `content`, pas son type ; un `content`
        # non-binaire ferait crasher `File.write`. On refuse proprement plutôt que de laisser crasher.
        {:error, "invalid content: not a binary"}

      true ->
        do_commit_checked(cwd, file_path, abs_path, content, user_id)
    end
  end

  defp do_commit_checked(cwd, file_path, abs_path, content, user_id) do
    tmp_path = abs_path <> ".tmp"

    # Snapshot pour rollback : le rename arrive AVANT git, donc un échec git AVANT que le commit ne
    # land laisserait le fichier modifié SANS commit. On restaure l'état d'origine dans ce cas SEUL.
    original =
      case File.read(abs_path) do
        {:ok, bytes} -> {:existed, bytes}
        {:error, _} -> :absent
      end

    with :ok <- File.write(tmp_path, content),
         :ok <- File.rename(tmp_path, abs_path) do
      # rename réussi → abs_path est désormais modifié.
      case git_add_commit(cwd, file_path, user_id) do
        {:ok, sha} ->
          {:ok, sha}

        # Échec AVANT que le commit ne land (`git add`/`git commit` a échoué) : le commit n'existe PAS,
        # rollback du worktree LÉGITIME + désindexation (le blob a pu être staged par `git add`).
        {:error, :pre_commit, msg} ->
          restore(cwd, file_path, abs_path, original)
          Logger.error("git_committer git failed before commit (rollback appliqué): #{msg}")
          {:error, msg}

        # Le commit a LAND (durable sur exit 0) mais une étape POST-commit a échoué (ex. `rev-parse`).
        # On NE TOUCHE PAS au worktree : HEAD porte DÉJÀ le nouveau contenu — un `restore` ÉCRASERAIT le
        # fichier avec l'ancien et corromprait l'état (worktree ≠ HEAD). On remonte l'erreur telle quelle.
        {:error, :post_commit, msg} ->
          Logger.error(
            "git_committer post-commit step failed (commit DURABLE, pas de rollback): #{msg}"
          )

          {:error, msg}
      end
    else
      # Échec AVANT/PENDANT le rename → abs_path intact, rien à restaurer, juste le tmp.
      {:error, reason} ->
        cleanup_tmp(tmp_path)
        Logger.error("git_committer file io failed: #{inspect(reason)}")
        {:error, "file io: #{inspect(reason)}"}
    end
  end

  defp git_add_commit(cwd, file_path, user_id) do
    # `@git_safe_config` (source unique `Fleet.Credentials.Shell.git_safe_config_args/0`) neutralise la
    # config git pilotable depuis le repo (hooks, filtres, sshCommand, diff.external, attributesFile global) :
    # le repo de config peut être co-écrit, un `pre-commit`/`core.hooksPath` modifiable s'exécuterait côté
    # monde au commit. On compose le set AVANT chaque sous-commande qui peut exécuter du code config-driven.
    #
    # Séparateur `--` AVANT le path. Sans lui, un file_path commençant par `-` (`--renormalize`) interprété
    # par git comme une OPTION (injection d'options) — bien que `safe_abs_path` borne déjà le chemin. Et
    # `git commit -- <pathspec>` borne le commit au SEUL fichier écrit (sans `--`, `commit` balaye tout
    # l'index staged, y compris un changement pré-staged étranger sous un message qui ne le décrit pas).
    #
    # Discrimination pre/post-commit (cf. `do_commit_checked`) : le `git commit` exit 0 rend le commit
    # DURABLE. Toute étape APRÈS (ici `rev-parse HEAD`) ne doit PAS déclencher un rollback du worktree.
    with {_add_out, 0} <-
           System.cmd("git", @git_safe_config ++ ["add", "--", file_path],
             cd: cwd,
             stderr_to_stdout: true
           ),
         {commit_out, 0} <-
           System.cmd(
             "git",
             @git_safe_config ++
               ["commit", "-m", "config: #{file_path} updated by #{user_id}", "--", file_path],
             cd: cwd,
             stderr_to_stdout: true
           ) do
      # Le commit a LAND. Tout échec APRÈS est `:post_commit` (jamais un rollback worktree).
      case System.cmd("git", ["rev-parse", "HEAD"], cd: cwd, stderr_to_stdout: true) do
        {sha_out, 0} ->
          Logger.debug("git_committer commit ok: #{file_path} by #{user_id}\n#{commit_out}")
          {:ok, String.trim(sha_out)}

        {output, code} ->
          {:error, :post_commit, "git rev-parse failed (#{code}): #{String.trim(output)}"}
      end
    else
      # `git add` OU `git commit` a échoué → le commit n'a PAS land (pre-commit).
      {output, code} when is_integer(code) ->
        {:error, :pre_commit, "git command failed (#{code}): #{String.trim(output)}"}
    end
  end

  # Rollback atomicité (cas pre-commit UNIQUEMENT) : restaure le contenu d'origine du worktree (ou
  # supprime si le fichier n'existait pas) ET DÉSINDEXE le fichier. `git add` (réussi) a pu poser un
  # blob staged ; sans `git reset -- <file>`, ce blob FANTÔME survit dans l'index (statut `AD`/`MM`) et
  # un commit non-pathspec ultérieur le matérialiserait. Le `--` borne le reset au seul fichier. Le
  # reset est best-effort (le repo peut être pre-initial / sans HEAD) → on ignore son résultat.
  defp restore(cwd, file_path, abs_path, original) do
    restore_worktree(abs_path, original)

    _ =
      System.cmd("git", @git_safe_config ++ ["reset", "--", file_path],
        cd: cwd,
        stderr_to_stdout: true
      )

    :ok
  end

  defp restore_worktree(abs_path, {:existed, bytes}), do: File.write(abs_path, bytes)
  defp restore_worktree(abs_path, :absent), do: File.rm(abs_path)

  defp cleanup_tmp(tmp_path) do
    _ = File.rm(tmp_path)
    :ok
  end

  defp git_repo_path do
    Application.get_env(:fleet_api, :git_repo_path, @default_repo)
  end
end
