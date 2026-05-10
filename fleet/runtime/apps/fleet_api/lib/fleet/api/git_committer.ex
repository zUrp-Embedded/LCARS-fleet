defmodule Fleet.Api.GitCommitter do
  @moduledoc """
  Pure functions wrapper atomic write + git auto commit.

  Canon trace strate 1 directive active = traçable git
  (architecture-cible §L380). Tout changement config via API/UI →
  commit auto git côté backend.

  ## Workflow

  1. Write atomique : `<file>.tmp` + `File.rename` (rename atomique
     POSIX, pas de file partiel)
  2. `git add <file>` (cwd = repo config)
  3. `git commit -m "config: <file> updated by <user>"`

  ## Configuration

    * `:fleet_api, :git_repo_path` — racine repo config
      (default `/var/lib/lcars/config`)

  ## Errors

  Tout échec (write/rename/git) → `{:error, reason}` (loggé).
  """

  require Logger

  @default_repo "/var/lib/lcars/config"

  @doc """
  Atomic write `content` vers `file_path` puis `git add` + `git commit`.

  `file_path` doit être un chemin relatif au repo `:git_repo_path`.

  Returns `{:ok, sha}` (commit SHA) ou `{:error, reason}`.
  """
  @spec commit_config_change(
          file_path :: String.t(),
          content :: iodata(),
          user_id :: String.t()
        ) :: {:ok, String.t()} | {:error, String.t()}
  def commit_config_change(file_path, content, user_id)
      when is_binary(file_path) and is_binary(user_id) do
    cwd = git_repo_path()
    abs_path = Path.join(cwd, file_path)
    tmp_path = abs_path <> ".tmp"

    with :ok <- File.write(tmp_path, content),
         :ok <- File.rename(tmp_path, abs_path),
         {_add_out, 0} <- System.cmd("git", ["add", file_path], cd: cwd, stderr_to_stdout: true),
         {commit_out, 0} <-
           System.cmd(
             "git",
             [
               "commit",
               "-m",
               "config: #{file_path} updated by #{user_id}"
             ],
             cd: cwd,
             stderr_to_stdout: true
           ),
         {sha_out, 0} <- System.cmd("git", ["rev-parse", "HEAD"], cd: cwd, stderr_to_stdout: true) do
      Logger.debug("git_committer commit ok: #{file_path} by #{user_id}\n#{commit_out}")
      {:ok, String.trim(sha_out)}
    else
      {:error, reason} ->
        cleanup_tmp(tmp_path)
        Logger.error("git_committer file io failed: #{inspect(reason)}")
        {:error, "file io: #{inspect(reason)}"}

      {output, code} when is_integer(code) ->
        cleanup_tmp(tmp_path)
        Logger.error("git_committer git failed (#{code}): #{output}")
        {:error, "git command failed (#{code}): #{String.trim(output)}"}
    end
  end

  defp cleanup_tmp(tmp_path) do
    _ = File.rm(tmp_path)
    :ok
  end

  defp git_repo_path do
    Application.get_env(:fleet_api, :git_repo_path, @default_repo)
  end
end
