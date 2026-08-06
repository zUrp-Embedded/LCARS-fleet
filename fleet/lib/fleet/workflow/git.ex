defmodule Fleet.Workflow.Git do
  @moduledoc """
  System-side, bounded git publication.

  `commit/1` and `push/3` remain separate so the deliverable gate runs between
  content and publication. Git configuration is neutralized for pod-written
  workspaces; no caller-controlled force or `--no-verify` is composed. A retry
  of an explicit non-fast-forward uses `--force-with-lease` only.
  """

  require Logger

  @type opts :: %{
          required(:workspace) => Path.t(),
          required(:author_name) => String.t(),
          required(:author_email) => String.t(),
          required(:committer_name) => String.t(),
          required(:committer_email) => String.t(),
          required(:message) => String.t(),
          optional(:add_paths) => [String.t()]
        }

  # Commit does not accept push concerns.
  @commit_required_keys [
    :workspace,
    :author_name,
    :author_email,
    :committer_name,
    :committer_email,
    :message
  ]

  # Pod-controlled workspaces can arm git config; Shell neutralizes hooks and global config.
  # PayloadGuard owns the remaining in-tree filter vector.
  @hooks_off Fleet.Credentials.Shell.git_safe_config_args()

  @doc """
  Commits paths in `workspace` without pushing and returns the resulting HEAD SHA.
  """
  @spec commit(opts) :: {:ok, String.t()} | {:error, term()}
  def commit(opts) when is_map(opts) do
    with :ok <- check_required_keys(opts, @commit_required_keys),
         :ok <- check_workspace_string(opts.workspace),
         :ok <- ensure_git_workspace(opts.workspace),
         :ok <- git_add(opts) do
      git_commit(opts)
    end
  end

  # Ref validation belongs to callers; `push/3` rejects option-like positional args.

  defp check_required_keys(opts, keys) do
    case Enum.reject(keys, &Map.has_key?(opts, &1)) do
      [] -> :ok
      missing -> {:error, {:missing_opts, missing}}
    end
  end

  defp check_workspace_string(ws) when is_binary(ws) and ws != "", do: :ok
  defp check_workspace_string(_ws), do: {:error, :invalid_workspace}

  defp ensure_git_workspace(ws) do
    # `.git` is a file in a linked worktree and a directory in a clone.
    case {File.dir?(ws), File.exists?(Path.join(ws, ".git"))} do
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

    case validate_add_paths(paths) do
      :ok ->
        # `--` makes option-like pathspecs literal; Shell bounds hangs and neutralizes config.
        case Fleet.Credentials.Shell.git(@hooks_off ++ ["add", "--" | paths],
               cd: opts.workspace,
               timeout_ms: git_local_timeout_ms()
             ) do
          {:ok, {_out, 0}} -> :ok
          {:ok, {out, rc}} -> {:error, {:git_add_failed, rc, String.trim(out)}}
          {:error, {:timeout, ms}} -> {:error, {:git_add_timeout, ms}}
          {:error, {:exit, reason}} -> {:error, {:git_add_exit, reason}}
          # Preserve future Shell errors as a typed failure.
          {:error, reason} -> {:error, {:git_add_exit, reason}}
        end

      {:error, _} = err ->
        err
    end
  end

  # Require non-empty binary pathspecs in addition to the `--` separator.
  defp validate_add_paths(paths) when is_list(paths) and paths != [] do
    if Enum.all?(paths, &(is_binary(&1) and &1 != "")),
      do: :ok,
      else: {:error, :invalid_add_paths}
  end

  defp validate_add_paths(_), do: {:error, :invalid_add_paths}

  defp git_commit(opts) do
    with :ok <- run_commit(opts) do
      read_head_sha(opts.workspace)
    end
  end

  defp run_commit(opts) do
    # Stable `diff --cached --quiet` codes avoid localized stderr parsing.
    case has_staged_changes?(opts.workspace) do
      false ->
        {:error, :nothing_to_commit}

      true ->
        # Preserve ForgeAuth's no-prompt environment while supplying commit identity.
        case Fleet.Credentials.Shell.git(@hooks_off ++ ["commit", "-m", opts.message],
               cd: opts.workspace,
               timeout_ms: git_local_timeout_ms(),
               env: Fleet.Credentials.ForgeAuth.git_env() ++ commit_env(opts)
             ) do
          {:ok, {_out, 0}} -> :ok
          {:ok, {out, rc}} -> {:error, {:git_commit_failed, rc, String.trim(out)}}
          {:error, {:timeout, ms}} -> {:error, {:git_commit_timeout, ms}}
          {:error, {:exit, reason}} -> {:error, {:git_commit_exit, reason}}
          {:error, reason} -> {:error, {:git_commit_exit, reason}}
        end
    end
  end

  defp has_staged_changes?(workspace) do
    # Bound and neutralize config; anomalies proceed to commit for a contextual error.
    case Fleet.Credentials.Shell.git(@hooks_off ++ ["diff", "--cached", "--quiet"],
           cd: workspace,
           timeout_ms: git_local_timeout_ms()
         ) do
      {:ok, {_, 0}} -> false
      {:ok, {_, 1}} -> true
      _ -> true
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

  @doc """
  Returns `workspace` HEAD through the bounded system-side rev-parse authority.
  """
  @spec read_head_sha(Path.t()) :: {:ok, String.t()} | {:error, term()}
  def read_head_sha(workspace) do
    # All system-side git reads share bounded, neutralized configuration.
    case Fleet.Credentials.Shell.git(@hooks_off ++ ["rev-parse", "HEAD"],
           cd: workspace,
           timeout_ms: git_local_timeout_ms()
         ) do
      {:ok, {sha, 0}} -> {:ok, String.trim(sha)}
      {:ok, {err, rc}} -> {:error, {:rev_parse_failed, rc, String.trim(err)}}
      {:error, {:timeout, ms}} -> {:error, {:rev_parse_timeout, ms}}
      {:error, {:exit, reason}} -> {:error, {:rev_parse_exit, reason}}
      {:error, reason} -> {:error, {:rev_parse_exit, reason}}
    end
  end

  @doc """
  Returns the bounded last touching commit, or `""` when the path has no history.
  """
  @spec last_commit_sha(Path.t(), String.t()) :: {:ok, String.t()} | {:error, term()}
  def last_commit_sha(workspace, path) do
    with :ok <- validate_cli_arg(path, :invalid_path) do
      case Fleet.Credentials.Shell.git(@hooks_off ++ ["log", "-1", "--format=%H", "--", path],
             cd: workspace,
             timeout_ms: git_local_timeout_ms()
           ) do
        {:ok, {sha, 0}} -> {:ok, String.trim(sha)}
        {:ok, {err, rc}} -> {:error, {:git_log_failed, rc, String.trim(err)}}
        {:error, {:timeout, ms}} -> {:error, {:git_log_timeout, ms}}
        {:error, {:exit, reason}} -> {:error, {:git_log_exit, reason}}
        # Preserve future Shell errors as a typed failure.
        {:error, reason} -> {:error, {:git_log_exit, reason}}
      end
    end
  end

  @doc """
  Tests whether `sha` names a commit; an unknown SHA is `{:ok, false}`.
  """
  @spec commit_exists?(Path.t(), String.t()) :: {:ok, boolean()} | {:error, term()}
  def commit_exists?(workspace, sha) do
    with :ok <- validate_cli_arg(sha, :invalid_sha) do
      case Fleet.Credentials.Shell.git(@hooks_off ++ ["cat-file", "-e", sha <> "^{commit}"],
             cd: workspace,
             timeout_ms: git_local_timeout_ms()
           ) do
        {:ok, {_, 0}} -> {:ok, true}
        {:ok, {_, _rc}} -> {:ok, false}
        {:error, {:timeout, ms}} -> {:error, {:git_timeout, ms}}
        {:error, {:exit, reason}} -> {:error, {:git_exit, reason}}
        # Preserve future Shell errors as a typed failure.
        {:error, reason} -> {:error, {:git_exit, reason}}
      end
    end
  end

  @doc """
  Tests ancestry with bounded git. Only rc 1 is a negative answer; all other
  failures remain typed errors.
  """
  @spec ancestor?(Path.t(), String.t(), String.t()) :: {:ok, boolean()} | {:error, term()}
  def ancestor?(workspace, ancestor, descendant) do
    with :ok <- validate_cli_arg(ancestor, :invalid_sha),
         :ok <- validate_cli_arg(descendant, :invalid_sha) do
      case Fleet.Credentials.Shell.git(
             @hooks_off ++ ["merge-base", "--is-ancestor", ancestor, descendant],
             cd: workspace,
             timeout_ms: git_local_timeout_ms()
           ) do
        {:ok, {_, 0}} -> {:ok, true}
        {:ok, {_, 1}} -> {:ok, false}
        {:ok, {_, 124}} -> {:error, {:git_timeout, "merge-base --is-ancestor timeout"}}
        {:ok, {out, rc}} -> {:error, {:git_error, "merge-base rc#{rc}: #{String.trim(out)}"}}
        {:error, {:timeout, ms}} -> {:error, {:git_timeout, ms}}
        {:error, {:exit, reason}} -> {:error, {:git_exit, reason}}
        # Preserve future Shell errors as a typed failure.
        {:error, reason} -> {:error, {:git_exit, reason}}
      end
    end
  end

  @doc """
  Returns up to `limit` commits touching `path`, newest first.
  """
  @spec commits_touching(Path.t(), String.t(), pos_integer()) ::
          {:ok, [String.t()]} | {:error, term()}
  def commits_touching(workspace, path, limit) when is_integer(limit) and limit > 0 do
    with :ok <- validate_cli_arg(path, :invalid_path) do
      args = @hooks_off ++ ["log", "-n", Integer.to_string(limit), "--format=%H", "--", path]

      case Fleet.Credentials.Shell.git(args, cd: workspace, timeout_ms: git_local_timeout_ms()) do
        {:ok, {out, 0}} ->
          {:ok, out |> String.split("\n", trim: true) |> Enum.map(&String.trim/1)}

        {:ok, {err, rc}} ->
          {:error, {:git_log_failed, rc, String.trim(err)}}

        {:error, {:timeout, ms}} ->
          {:error, {:git_log_timeout, ms}}

        {:error, {:exit, reason}} ->
          {:error, {:git_log_exit, reason}}

        # Preserve future Shell errors as a typed failure.
        {:error, reason} ->
          {:error, {:git_log_exit, reason}}
      end
    end
  end

  @doc """
  Returns bounded `git show` content; unknown commit or path is a typed error.
  """
  @spec show(Path.t(), String.t(), String.t()) :: {:ok, String.t()} | {:error, term()}
  def show(workspace, sha, path) do
    with :ok <- validate_cli_arg(sha, :invalid_sha),
         :ok <- validate_cli_arg(path, :invalid_path) do
      case Fleet.Credentials.Shell.git(@hooks_off ++ ["show", "#{sha}:#{path}"],
             cd: workspace,
             timeout_ms: git_local_timeout_ms()
           ) do
        {:ok, {content, 0}} -> {:ok, content}
        {:ok, {err, rc}} -> {:error, {:git_show_failed, rc, String.trim(err)}}
        {:error, {:timeout, ms}} -> {:error, {:git_show_timeout, ms}}
        {:error, {:exit, reason}} -> {:error, {:git_show_exit, reason}}
        # Preserve future Shell errors as a typed failure.
        {:error, reason} -> {:error, {:git_show_exit, reason}}
      end
    end
  end

  @doc """
  Pushes a committed refspec through the bounded system publication path.
  """
  @spec push(Path.t(), String.t(), String.t()) :: {:ok, true} | {:error, term()}
  def push(workspace, remote, refspec) do
    with :ok <- validate_cli_arg(remote, :invalid_remote),
         :ok <- validate_cli_arg(refspec, :invalid_refspec),
         # DR-024: malformed forge credentials fail before a push attempt.
         {:ok, auth_env} <- Fleet.Credentials.ForgeAuth.git_env_result() do
      do_push(workspace, remote, refspec, auth_env)
    end
  end

  # Git parses positional args starting with `-` as options; reject them fail-closed.
  defp validate_cli_arg(arg, err) when is_binary(arg) and arg != "" do
    if String.starts_with?(arg, "-"), do: {:error, {err, arg}}, else: :ok
  end

  defp validate_cli_arg(_arg, err), do: {:error, err}

  defp do_push(workspace, remote, refspec, auth_env) do
    case run_push(workspace, remote, refspec, [], auth_env) do
      {:ok, {_out, 0}} ->
        {:ok, true}

      {:ok, {out, rc}} ->
        # Explicit non-fast-forward alone may retry with a lease; never blind-force.
        if non_fast_forward?(out),
          do: force_push(workspace, remote, refspec, auth_env),
          else: {:error, {:git_push_failed, rc, String.trim(out)}}

      {:error, {:timeout, _ms}} ->
        # A timed-out local process may have pushed; confirm remote SHA before retrying.
        confirm_push_after_timeout(workspace, remote, refspec, auth_env)

      {:error, {:exit, reason}} ->
        {:error, {:git_push_exit, reason}}
    end
  end

  # Confirm timeout outcome only when source and remote target SHA are equal.
  defp confirm_push_after_timeout(workspace, remote, refspec, auth_env) do
    target = target_of_refspec(refspec)
    src = source_of_refspec(refspec)

    with {:ok, local} <- read_local_sha(workspace, src),
         {:ok, remote_sha} when is_binary(remote_sha) <-
           read_remote_ref_sha(workspace, remote, target, auth_env),
         true <- local == remote_sha do
      Logger.warning(
        "Workflow.Git: push #{refspec} timed out but the remote target holds our SHA " <>
          "(#{String.slice(local, 0, 12)}) — the push LANDED before the local kill; confirmed by readback"
      )

      {:ok, true}
    else
      _ -> {:error, {:git_push_timeout, push_timeout_ms()}}
    end
  end

  # A leading refspec `+` applies to source, not the remote target.
  defp source_of_refspec(refspec) do
    refspec |> String.split(":") |> List.first() |> String.trim_leading("+")
  end

  # Uses the runner seam so timeout readback is testable.
  defp read_local_sha(workspace, ref) do
    case git_runner().(@hooks_off ++ ["rev-parse", "--verify", "#{ref}^{commit}"],
           cd: workspace,
           timeout_ms: git_local_timeout_ms()
         ) do
      {:ok, {sha, 0}} -> {:ok, String.trim(sha)}
      {:ok, {err, rc}} -> {:error, {:rev_parse_failed, rc, String.trim(err)}}
      {:error, reason} -> {:error, {:rev_parse_exit, reason}}
    end
  end

  # Bounded `ls-remote`; no remote ref returns `{:ok, nil}`.
  defp read_remote_ref_sha(workspace, remote, target, auth_env) do
    case git_runner().(@hooks_off ++ ["ls-remote", remote, target],
           cd: workspace,
           timeout_ms: push_timeout_ms(),
           env: auth_env
         ) do
      {:ok, {out, 0}} ->
        case out |> String.split(~r/\s+/, parts: 2) |> List.first() do
          sha when is_binary(sha) and byte_size(sha) >= 7 -> {:ok, sha}
          _ -> {:ok, nil}
        end

      {:ok, {err, rc}} ->
        {:error, {:ls_remote_failed, rc, String.trim(err)}}

      {:error, reason} ->
        {:error, {:ls_remote_exit, reason}}
    end
  end

  # A force retry requires our recorded remote-tracking SHA as lease basis.
  defp force_push(workspace, remote, refspec, auth_env) do
    target = target_of_refspec(refspec)

    case read_remote_tracking_sha(workspace, remote, target) do
      {:ok, expected} ->
        lease = "--force-with-lease=#{target}:#{expected}"

        case run_push(workspace, remote, refspec, [lease], auth_env) do
          {:ok, {_out, 0}} ->
            {:ok, true}

          {:ok, {out, rc}} ->
            # Distinguish a moved remote from an ordinary push failure.
            if lease_stale?(out),
              do: {:error, {:git_push_lease_stale, target, String.trim(out)}},
              else: {:error, {:git_push_failed, rc, String.trim(out)}}

          {:error, {:timeout, _ms}} ->
            {:error, {:git_push_timeout, push_timeout_ms()}}

          {:error, {:exit, reason}} ->
            {:error, {:git_push_exit, reason}}
        end

      :absent ->
        {:error, {:git_push_no_lease_basis, target}}

      {:error, reason} ->
        {:error, {:git_push_no_lease_basis, {target, reason}}}
    end
  end

  # The remote-side target is the final refspec segment.
  defp target_of_refspec(refspec), do: refspec |> String.split(":") |> List.last()

  # Remote-tracking SHA is the lease basis; absent means no force retry.
  defp read_remote_tracking_sha(workspace, remote, target) do
    case Fleet.Credentials.Shell.git(
           @hooks_off ++ ["rev-parse", "--verify", "--quiet", "refs/remotes/#{remote}/#{target}"],
           cd: workspace,
           timeout_ms: git_local_timeout_ms()
         ) do
      {:ok, {sha, 0}} -> {:ok, String.trim(sha)}
      {:ok, {_out, 1}} -> :absent
      {:ok, {err, rc}} -> {:error, {:rev_parse_failed, rc, String.trim(err)}}
      {:error, {:timeout, ms}} -> {:error, {:rev_parse_timeout, ms}}
      {:error, {:exit, reason}} -> {:error, {:rev_parse_exit, reason}}
      # Preserve future Shell errors as a typed failure.
      {:error, reason} -> {:error, {:rev_parse_exit, reason}}
    end
  end

  # Git reports a refused lease as stale or rejected.
  defp lease_stale?(out) do
    o = String.downcase(out)
    String.contains?(o, "stale info") or String.contains?(o, "rejected")
  end

  # Shell bounds the entire git process group, including transport helpers.
  defp run_push(workspace, remote, refspec, extra, auth_env) do
    # Forge credentials stay in env, never argv.
    git_runner().(@hooks_off ++ ["push"] ++ extra ++ [remote, refspec],
      cd: workspace,
      timeout_ms: push_timeout_ms(),
      env: auth_env
    )
  end

  # Push/readback seam supports timeout-outcome tests.
  defp git_runner,
    do: Application.get_env(:fleet_workflow, :git_push_runner, &Fleet.Credentials.Shell.git/2)

  # Retry only explicit history divergence, never generic rejection or server policy refusal.
  defp non_fast_forward?(out) do
    o = String.downcase(out)

    String.contains?(o, "non-fast-forward") or String.contains?(o, "fetch first")
  end

  # Configurable network push bound.
  defp push_timeout_ms do
    Application.get_env(:fleet_workflow, :git_push_timeout_ms, 30_000)
  end

  # Configurable local git-operation bound.
  defp git_local_timeout_ms do
    Application.get_env(:fleet_workflow, :git_local_timeout_ms, 30_000)
  end

  # Forge auth comes from ForgeAuth environment only.
end
