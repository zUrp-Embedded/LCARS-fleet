defmodule Fleet.Pipeline.Git do
  @moduledoc """
  Mécanisme système-side de publication git post-EXTRACT (face 2 décision
  archi git, 2026-05-24). Composé par `Fleet.Pipeline.Executor` sur
  `pod.completed` lorsque la stage déclare `post_extract.git`.

  Pure data → action :
    * input  : workspace path, identités auteur/committer, message, branch,
      add_paths, remote, push?
    * action : `git add <paths> → git commit → [git push <remote> <branch>]`
    * output : `{:ok, %{commit_sha, pushed?}}` ou `{:error, term()}`

  Fail-closed strict : `--force` et `--no-verify` ne sont **JAMAIS** composés
  par le module. Si un cas futur nécessite override, ce sera une décision
  explicite avec audit, pas une option par défaut.

  D-04 préservée : `author_*` reflète l'identité du worker (role) ;
  `committer_*` reflète l'identité système. Natif git
  (`GIT_AUTHOR_*` ≠ `GIT_COMMITTER_*`).
  """

  require Logger

  @type opts :: %{
          required(:workspace) => Path.t(),
          required(:author_name) => String.t(),
          required(:author_email) => String.t(),
          required(:committer_name) => String.t(),
          required(:committer_email) => String.t(),
          required(:message) => String.t(),
          required(:branch) => String.t(),
          optional(:remote) => String.t(),
          optional(:add_paths) => [String.t()],
          optional(:push?) => boolean()
        }

  @required_keys [
    :workspace,
    :author_name,
    :author_email,
    :committer_name,
    :committer_email,
    :message,
    :branch
  ]

  # Refuse branches/refs avec caractères ambigus (espace, ..., leading `-`).
  # Pas une défense anti-injection (System.cmd n'utilise pas de shell), juste
  # un garde-fou contre des entrées catalogue manifestement cassées. Aligne
  # grosso-modo sur git check-ref-format : commence par alphanumérique, puis
  # `[A-Za-z0-9._/-]`, et rejette le substring `..`.
  @branch_re ~r/^[A-Za-z0-9][A-Za-z0-9._\/\-]*$/

  @doc """
  Compose la séquence git système-side (add → commit → [push]) dans
  `workspace`. Pure data → action ; pas d'état conservé.
  """
  @spec publish(opts) :: {:ok, %{commit_sha: String.t(), pushed?: boolean()}} | {:error, term()}
  def publish(opts) when is_map(opts) do
    with :ok <- validate_opts(opts),
         :ok <- ensure_git_workspace(opts.workspace),
         :ok <- git_add(opts),
         {:ok, sha} <- git_commit(opts),
         {:ok, pushed?} <- maybe_push(opts) do
      {:ok, %{commit_sha: sha, pushed?: pushed?}}
    end
  end

  # ============================================================
  # Validation
  # ============================================================

  defp validate_opts(opts) do
    with :ok <- check_required_keys(opts),
         :ok <- check_workspace_string(opts.workspace),
         :ok <- check_branch(opts.branch),
         :ok <- check_push_remote(opts) do
      :ok
    end
  end

  defp check_required_keys(opts) do
    case Enum.reject(@required_keys, &Map.has_key?(opts, &1)) do
      [] -> :ok
      missing -> {:error, {:missing_opts, missing}}
    end
  end

  defp check_workspace_string(ws) when is_binary(ws) and ws != "", do: :ok
  defp check_workspace_string(_ws), do: {:error, :invalid_workspace}

  defp check_branch(branch) when is_binary(branch) do
    if Regex.match?(@branch_re, branch) and not String.contains?(branch, ".."),
      do: :ok,
      else: {:error, :invalid_branch}
  end

  defp check_branch(_branch), do: {:error, :invalid_branch}

  defp check_push_remote(%{push?: true} = opts) do
    case Map.get(opts, :remote) do
      r when is_binary(r) -> :ok
      _ -> {:error, :push_requires_remote}
    end
  end

  defp check_push_remote(_opts), do: :ok

  defp ensure_git_workspace(ws) do
    case {File.dir?(ws), File.dir?(Path.join(ws, ".git"))} do
      {false, _} -> {:error, :workspace_missing}
      {true, false} -> {:error, :not_a_git_workspace}
      {true, true} -> :ok
    end
  end

  # ============================================================
  # Git ops
  # ============================================================

  defp git_add(opts) do
    paths = Map.get(opts, :add_paths, ["."])

    case System.cmd("git", ["add" | paths], cd: opts.workspace, stderr_to_stdout: true) do
      {_out, 0} -> :ok
      {out, rc} -> {:error, {:git_add_failed, rc, String.trim(out)}}
    end
  end

  defp git_commit(opts) do
    with :ok <- run_commit(opts),
         {:ok, sha} <- read_head_sha(opts.workspace) do
      {:ok, sha}
    end
  end

  defp run_commit(opts) do
    # audit elixir #2 : ancienne classification grep "nothing to commit" sur
    # stderr → i18n-dependent (LC_ALL=fr_FR → "rien à valider" → grep rate →
    # mauvaise classification). Pre-check via `git diff --cached --quiet`
    # (codes RC stable across locales : 0 = pas de diff staged, 1 = diff
    # staged). Évite le commit entièrement quand `:nothing_to_commit`.
    case has_staged_changes?(opts.workspace) do
      false ->
        {:error, :nothing_to_commit}

      true ->
        case System.cmd("git", ["commit", "-m", opts.message],
               cd: opts.workspace,
               env: commit_env(opts),
               stderr_to_stdout: true
             ) do
          {_out, 0} -> :ok
          {out, rc} -> {:error, {:git_commit_failed, rc, String.trim(out)}}
        end
    end
  end

  defp has_staged_changes?(workspace) do
    case System.cmd("git", ["diff", "--cached", "--quiet"],
           cd: workspace,
           stderr_to_stdout: true
         ) do
      # Exit 0 = aucun diff staged → rien à commit.
      {_, 0} -> false
      # Exit 1 = diff staged présent (sémantique stable git).
      {_, 1} -> true
      # Autre code = erreur git non-attendue (corruption repo, etc.) → laisse
      # commit tenter et reporter via {:git_commit_failed, ...}.
      {_, _} -> true
    end
  end

  defp commit_env(opts) do
    [
      {"GIT_AUTHOR_NAME", opts.author_name},
      {"GIT_AUTHOR_EMAIL", opts.author_email},
      {"GIT_COMMITTER_NAME", opts.committer_name},
      {"GIT_COMMITTER_EMAIL", opts.committer_email}
    ]
  end

  defp read_head_sha(workspace) do
    case System.cmd("git", ["rev-parse", "HEAD"], cd: workspace, stderr_to_stdout: true) do
      {sha, 0} -> {:ok, String.trim(sha)}
      {err, rc} -> {:error, {:rev_parse_failed, rc, String.trim(err)}}
    end
  end

  defp maybe_push(%{push?: true} = opts) do
    remote = Map.fetch!(opts, :remote)
    timeout_ms = push_timeout_ms()

    # audit elixir #1 BLOQUANT — `System.cmd("git", ["push", ...])` n'a pas
    # de timeout natif. Un push réseau hung (DNS, TLS handshake, packfile
    # transfer interrompu) bloque l'Executor GenServer indéfiniment.
    # Task.async + Task.yield + Task.shutdown :brutal_kill : si pas de retour
    # dans `timeout_ms`, on tue le Task (donc le port, donc le process git
    # via SIGKILL). Retour `{:error, :git_push_timeout}` propagé à
    # `Fleet.Pipeline.Executor.do_post_extract_git/4` qui broadcast
    # `git.publish_failed` (best-effort, n'interrompt pas le pipeline).
    task =
      Task.async(fn ->
        System.cmd("git", ["push", remote, opts.branch],
          cd: opts.workspace,
          stderr_to_stdout: true
        )
      end)

    case Task.yield(task, timeout_ms) || Task.shutdown(task, :brutal_kill) do
      {:ok, {_out, 0}} ->
        {:ok, true}

      {:ok, {out, rc}} ->
        {:error, {:git_push_failed, rc, String.trim(out)}}

      nil ->
        {:error, {:git_push_timeout, timeout_ms}}

      {:exit, reason} ->
        {:error, {:git_push_exit, reason}}
    end
  end

  defp maybe_push(_opts), do: {:ok, false}

  # Timeout pour `git push` réseau. Default 30s (suffisant LAN/forge locale,
  # garde-fou contre hung indéfini WAN). Override via :fleet_pipeline,
  # :git_push_timeout_ms (config app ou Application.put_env).
  defp push_timeout_ms do
    Application.get_env(:fleet_pipeline, :git_push_timeout_ms, 30_000)
  end
end
