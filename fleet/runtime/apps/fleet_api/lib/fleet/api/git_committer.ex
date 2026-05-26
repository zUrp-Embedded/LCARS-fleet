defmodule Fleet.Api.GitCommitter do
  @moduledoc """
  GenServer wrapper atomic write + git auto commit.

  Canon trace strate 1 directive active = traçable git
  (architecture-cible §L380). Tout changement config via API/UI →
  commit auto git côté backend.

  ## Workflow

  1. Write atomique : `<file>.tmp` + `File.rename` (rename atomique
     POSIX, pas de file partiel)
  2. `git add <file>` (cwd = repo config)
  3. `git commit -m "config: <file> updated by <user>"`

  ## Vulcan #2 — sérialisation

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

  Vulcan #2 : sérialisé via le GenServer (call queue FIFO).
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

  # Confinement (finding sécu) : `file_path` DOIT rester sous le repo. Rejette les
  # chemins absolus et toute traversée `..` qui résoudrait hors de `cwd`. Le @doc
  # disait "doit être relatif au repo" — c'était un contrat NON enforcé.
  defp safe_abs_path(cwd, file_path) do
    if Path.type(file_path) != :relative do
      {:error, "absolute path"}
    else
      abs = Path.expand(Path.join(cwd, file_path))
      root = Path.expand(cwd)

      if abs == root or String.starts_with?(abs, root <> "/") do
        {:ok, abs}
      else
        {:error, "path escapes repo"}
      end
    end
  end

  defp do_commit(cwd, file_path, abs_path, content, user_id) do
    tmp_path = abs_path <> ".tmp"

    # Snapshot pour rollback (finding atomicité) : le rename arrive AVANT git, donc
    # un échec git laissait le fichier modifié non commité. On restaure l'état d'origine.
    original =
      case File.read(abs_path) do
        {:ok, bytes} -> {:existed, bytes}
        {:error, _} -> :absent
      end

    with :ok <- File.write(tmp_path, content),
         :ok <- File.rename(tmp_path, abs_path) do
      # rename réussi → abs_path est désormais modifié : tout échec git en aval restaure.
      case git_add_commit(cwd, file_path, user_id) do
        {:ok, sha} ->
          {:ok, sha}

        {:error, msg} ->
          restore(abs_path, original)
          Logger.error("git_committer git failed (rollback appliqué): #{msg}")
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
    with {_add_out, 0} <- System.cmd("git", ["add", file_path], cd: cwd, stderr_to_stdout: true),
         {commit_out, 0} <-
           System.cmd("git", ["commit", "-m", "config: #{file_path} updated by #{user_id}"],
             cd: cwd,
             stderr_to_stdout: true
           ),
         {sha_out, 0} <- System.cmd("git", ["rev-parse", "HEAD"], cd: cwd, stderr_to_stdout: true) do
      Logger.debug("git_committer commit ok: #{file_path} by #{user_id}\n#{commit_out}")
      {:ok, String.trim(sha_out)}
    else
      {output, code} when is_integer(code) ->
        {:error, "git command failed (#{code}): #{String.trim(output)}"}
    end
  end

  # Rollback atomicité : restaure le contenu d'origine (ou supprime si le fichier
  # n'existait pas avant) après un échec git post-rename.
  defp restore(abs_path, {:existed, bytes}), do: File.write(abs_path, bytes)
  defp restore(abs_path, :absent), do: File.rm(abs_path)

  defp cleanup_tmp(tmp_path) do
    _ = File.rm(tmp_path)
    :ok
  end

  defp git_repo_path do
    Application.get_env(:fleet_api, :git_repo_path, @default_repo)
  end
end
