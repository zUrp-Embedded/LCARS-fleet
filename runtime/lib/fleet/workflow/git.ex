defmodule Fleet.Workflow.Git do
  @moduledoc """
  System-side Git operations with per-command timeouts (30 seconds by default).

  commit/1 and push/3 are separate so a deliverable gate can run between them.
  Shell supplies safe configuration arguments. Positional validation rejects empty
  and option-like arguments, not Git refspec semantics: caller-supplied + force
  refspecs and deletion refspecs are accepted. Calls require exclusive workspace
  access if the caller needs a stable commit between validation and publication.
  """

  require Logger

  alias Fleet.Credentials.Shell

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
  @hooks_off Shell.git_safe_config_args()

  @doc """
  Stages add_paths (default ["."]) and commits the entire index, including paths
  already staged by another operation. Returns HEAD after the commit; failures do
  not roll back staged files or a completed commit. Paths retain Git pathspec semantics.
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

  defp git_add(opts) do
    paths = Map.get(opts, :add_paths, ["."])

    case validate_add_paths(paths) do
      :ok ->
        # `--` makes option-like pathspecs literal; Shell bounds hangs and neutralizes config.
        case Shell.git(@hooks_off ++ ["add", "--" | paths],
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
        case Shell.git(@hooks_off ++ ["commit", "-m", opts.message],
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
    case Shell.git(@hooks_off ++ ["diff", "--cached", "--quiet"],
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
    case Shell.git(@hooks_off ++ ["rev-parse", "HEAD"],
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
      case Shell.git(@hooks_off ++ ["log", "-1", "--format=%H", "--", path],
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
  Tests whether sha resolves to a commit; revision expressions are accepted.
  Every nonzero Git exit becomes {:ok, false}, including errors other than absence.
  Shell failures remain typed errors.
  """
  @spec commit_exists?(Path.t(), String.t()) :: {:ok, boolean()} | {:error, term()}
  def commit_exists?(workspace, sha) do
    with :ok <- validate_cli_arg(sha, :invalid_sha) do
      case Shell.git(@hooks_off ++ ["cat-file", "-e", sha <> "^{commit}"],
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
      case Shell.git(
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

      case Shell.git(args, cd: workspace, timeout_ms: git_local_timeout_ms()) do
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
      case Shell.git(@hooks_off ++ ["show", "#{sha}:#{path}"],
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

  @provenance_ref_prefix "refs/lcars/provenance/"

  @doc """
  Returns refs/lcars/provenance/<sha> without validating the SHA.
  Naming by commit keeps lookup independent of a moving branch head and separates
  attestations for different commits. Writers for the same commit still share a ref.
  """
  @spec provenance_ref(String.t()) :: String.t()
  def provenance_ref(sha) when is_binary(sha) and sha != "", do: @provenance_ref_prefix <> sha

  @doc """
  Writes json bytes as a local Git blob and unconditionally updates provenance_ref(sha).
  Does not validate JSON, its relation to sha, or an existing ref value. An update
  failure can leave the blob behind. Publication is a separate caller operation.
  """
  @spec write_provenance(Path.t(), String.t(), String.t()) :: :ok | {:error, term()}
  def write_provenance(workspace, sha, json)
      when is_binary(sha) and sha != "" and is_binary(json) do
    with {:ok, blob} <- hash_object(workspace, json),
         do: update_ref(workspace, provenance_ref(sha), blob)
  end

  @doc """
  Reads cat-file -p output at the local provenance ref; does not fetch, check out,
  or validate object type/JSON. Every nonzero Git exit becomes :no_provenance_ref,
  including errors other than a missing ref; Shell failures remain distinct.
  """
  @spec read_provenance(Path.t(), String.t()) :: {:ok, String.t()} | {:error, term()}
  def read_provenance(dir, sha) when is_binary(sha) and sha != "" do
    case Shell.git(@hooks_off ++ ["cat-file", "-p", provenance_ref(sha)],
           cd: dir,
           timeout_ms: git_local_timeout_ms()
         ) do
      {:ok, {out, 0}} -> {:ok, out}
      {:ok, {_out, _rc}} -> {:error, :no_provenance_ref}
      {:error, {:timeout, ms}} -> {:error, {:git_cat_file_timeout, ms}}
      {:error, reason} -> {:error, {:git_cat_file_failed, reason}}
    end
  end

  # Shell has no stdin interface. A temporary file outside the worktree avoids
  # passing content in argv or dirtying the tree just checked by the deliverable gate.
  defp hash_object(workspace, json) do
    tmp =
      Path.join(System.tmp_dir!(), "lcars-provenance-#{System.unique_integer([:positive])}.json")

    try do
      with :ok <- File.write(tmp, json),
           {:ok, {out, 0}} <-
             Shell.git(@hooks_off ++ ["hash-object", "-w", tmp],
               cd: workspace,
               timeout_ms: git_local_timeout_ms()
             ) do
        {:ok, String.trim(out)}
      else
        other -> {:error, {:git_hash_object_failed, other}}
      end
    after
      File.rm(tmp)
    end
  end

  defp update_ref(workspace, ref, object) do
    case Shell.git(@hooks_off ++ ["update-ref", ref, object],
           cd: workspace,
           timeout_ms: git_local_timeout_ms()
         ) do
      {:ok, {_out, 0}} -> :ok
      other -> {:error, {:git_update_ref_failed, other}}
    end
  end

  @doc """
  Pushes one or more refspecs in one command, without --atomic: refs can land
  partially even when Git reports an error. Malformed credentials prevent an attempt.

  A nonzero result whose text contains non-fast-forward or fetch first triggers
  one retry leased against the first target's local remote-tracking SHA, without
  fetching. Other refspecs have no added lease. Rejection classification also uses
  output substrings, not a structured server verdict.

  Initial timeout recovery compares only the first source commit and remote target,
  read after the timeout; equality returns success even if other refs are missing.
  A timeout during the leased retry has no readback. Default Shell calls are bounded
  individually; an injected runner controls its own execution and error shapes.
  """
  @spec push(Path.t(), String.t(), String.t() | [String.t()]) :: {:ok, true} | {:error, term()}
  def push(workspace, remote, refspec) when is_binary(refspec),
    do: push(workspace, remote, [refspec])

  def push(workspace, remote, refspecs) when is_list(refspecs) and refspecs != [] do
    with :ok <- validate_cli_arg(remote, :invalid_remote),
         :ok <- validate_refspecs(refspecs),
         # DR-024: malformed forge credentials fail before a push attempt.
         {:ok, auth_env} <- Fleet.Credentials.ForgeAuth.git_env_result() do
      do_push(workspace, remote, refspecs, auth_env)
    end
  end

  # Validate every argument before issuing the command; Git validates refspec syntax.
  defp validate_refspecs(refspecs) do
    Enum.reduce_while(refspecs, :ok, fn r, _ ->
      case validate_cli_arg(r, :invalid_refspec) do
        :ok -> {:cont, :ok}
        err -> {:halt, err}
      end
    end)
  end

  # Git parses positional args starting with `-` as options; reject them fail-closed.
  defp validate_cli_arg(arg, err) when is_binary(arg) and arg != "" do
    if String.starts_with?(arg, "-"), do: {:error, {err, arg}}, else: :ok
  end

  defp validate_cli_arg(_arg, err), do: {:error, err}

  defp do_push(workspace, remote, refspecs, auth_env) do
    case run_push(workspace, remote, refspecs, [], auth_env) do
      {:ok, {_out, 0}} ->
        {:ok, true}

      {:ok, {out, rc}} ->
        # Classification examines the whole output, including any echoed paths.
        if non_fast_forward?(out),
          do: force_push(workspace, remote, refspecs, auth_env),
          else: {:error, {:git_push_failed, rc, String.trim(out)}}

      {:error, {:timeout, _ms}} ->
        # Only the first ref is compared; this says nothing about accompanying attestations.
        confirm_push_after_timeout(workspace, remote, hd(refspecs), auth_env)

      {:error, {:exit, reason}} ->
        {:error, {:git_push_exit, reason}}
    end
  end

  # Equality is observed after timeout; the log's claim about when it landed is stronger.
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

  # Lease only the first target against recorded remote-tracking state; no fetch here.
  defp force_push(workspace, remote, refspecs, auth_env) do
    refspec = hd(refspecs)
    target = target_of_refspec(refspec)

    case read_remote_tracking_sha(workspace, remote, target) do
      {:ok, expected} ->
        lease = "--force-with-lease=#{target}:#{expected}"

        workspace
        |> run_push(remote, refspecs, [lease], auth_env)
        |> leased_push_verdict(target)

      :absent ->
        {:error, {:git_push_no_lease_basis, target}}

      {:error, reason} ->
        {:error, {:git_push_no_lease_basis, {target, reason}}}
    end
  end

  # The caller distinguishes stale-lease errors, but the classifier also matches
  # generic "rejected" output and therefore does not establish a concurrent ref move.
  defp leased_push_verdict({:ok, {_out, 0}}, _target), do: {:ok, true}

  defp leased_push_verdict({:ok, {out, rc}}, target) do
    if lease_stale?(out),
      do: {:error, {:git_push_lease_stale, target, String.trim(out)}},
      else: {:error, {:git_push_failed, rc, String.trim(out)}}
  end

  defp leased_push_verdict({:error, {:timeout, _ms}}, _target),
    do: {:error, {:git_push_timeout, push_timeout_ms()}}

  defp leased_push_verdict({:error, {:exit, reason}}, _target),
    do: {:error, {:git_push_exit, reason}}

  # The remote-side target is the final refspec segment.
  defp target_of_refspec(refspec), do: refspec |> String.split(":") |> List.last()

  # Remote-tracking SHA is the lease basis; absent means no force retry.
  defp read_remote_tracking_sha(workspace, remote, target) do
    case Shell.git(
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

  # Text heuristic: generic rejection can also be classified as a stale lease.
  defp lease_stale?(out) do
    o = String.downcase(out)
    String.contains?(o, "stale info") or String.contains?(o, "rejected")
  end

  # Shell bounds the entire git process group, including transport helpers.
  defp run_push(workspace, remote, refspecs, extra, auth_env) do
    # Forge credentials stay in env, never argv.
    git_runner().(@hooks_off ++ ["push"] ++ extra ++ [remote | refspecs],
      cd: workspace,
      timeout_ms: push_timeout_ms(),
      env: auth_env
    )
  end

  # Push/readback seam supports timeout-outcome tests.
  defp git_runner,
    do: Application.get_env(:lcars_fleet, :workflow_git_push_runner, &Shell.git/2)

  # Output substring heuristic, not a structured check of the rejected ref or reason.
  defp non_fast_forward?(out) do
    o = String.downcase(out)

    String.contains?(o, "non-fast-forward") or String.contains?(o, "fetch first")
  end

  # Configurable network push bound.
  defp push_timeout_ms do
    Application.get_env(:lcars_fleet, :workflow_git_push_timeout_ms, 30_000)
  end

  # Configurable local git-operation bound.
  defp git_local_timeout_ms do
    Application.get_env(:lcars_fleet, :workflow_git_local_timeout_ms, 30_000)
  end

  # Forge auth comes from ForgeAuth environment only.
end
