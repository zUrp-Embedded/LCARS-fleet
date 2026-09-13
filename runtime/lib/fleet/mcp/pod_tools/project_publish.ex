defmodule Fleet.MCP.PodTools.ProjectPublish do
  @moduledoc """
  Worker body for project_publish tasks under Fleet.MCP.PublishTaskSupervisor.
  The caller enqueues work so whole-history rewriting does not block its tool turn.

  Reads the per-human ~/.lcars/publish/<owner__name>.json binding written by lcars
  approve, then calls publish-rail.sh. The rail force-pushes a rolling branch and
  opens/updates a PR/MR when its CLI is available, otherwise returns a manual URL.
  External authentication stays with host CLI/credential helpers. The internal
  forge token is obtained from Authority and written to a temporary file.

  Reports done/failed through the lossy Bus, including requester and manual-URL
  status. Returned failures and rescued exceptions become failed events; throws
  and exits are not caught, and publication is not rolled back by a reporting failure.
  """

  require Logger
  alias Fleet.EventRouter.Bus

  # Generous wall deadline: the rail re-clones the internal repo and filter-repo rewrites its whole
  # history on every run. Shell.run kills the whole process-group at the deadline.
  @rail_timeout_ms 15 * 60 * 1000

  @doc """
  Runs a linked publication and reports its outcome through the Bus, returning :ok
  on handled paths. Rescues exceptions; cleanup is in do_run's normal/error branches,
  not an after block, so an exception can bypass cleanup.
  """
  @spec run(String.t(), String.t() | nil) :: :ok
  def run(repo, requester \\ nil) when is_binary(repo) do
    case do_run(repo) do
      {:ok, {url, manual}} ->
        Logger.info("ProjectPublish: #{repo} -> #{outcome_log(url, manual)}")

        safe_emit(
          :"project_publish.done",
          %{"repo" => repo, "url" => url, "manual" => manual, "requester_pod_id" => requester},
          repo
        )

      {:error, reason} ->
        {cat, detail} = Fleet.Event.reason_fields(reason)
        Logger.warning("ProjectPublish: #{repo} FAILED — #{detail}")

        safe_emit(
          :"project_publish.failed",
          %{
            "repo" => repo,
            "reason" => cat,
            "reason_detail" => detail,
            "requester_pod_id" => requester
          },
          repo
        )
    end

    :ok
  rescue
    e ->
      Logger.error("ProjectPublish: #{repo} RAISED — #{Exception.message(e)}")

      safe_emit(
        :"project_publish.failed",
        %{
          "repo" => repo,
          "reason" => "raised",
          "reason_detail" => Exception.message(e),
          "requester_pod_id" => requester
        },
        repo
      )

      :ok
  end

  @doc """
  Org-qualified binding filename key: owner/name becomes owner__name.
  Must match bin/lcars cmd_approve's encoding so reads find the written binding.
  """
  @spec binding_key(String.t()) :: String.t()
  def binding_key(repo) when is_binary(repo), do: String.replace(repo, "/", "__")

  @token_basename ".forge-token"

  defp do_run(repo) do
    slug = binding_key(repo)
    base = fresh_work(slug)
    work = Path.join(base, "clone")

    with {:ok, b} <- read_binding(slug),
         {:ok, forge_url} <- env("FORGE_BASE_URL"),
         {:ok, forge_tok} <- materialise_token(base),
         args = rail_args(repo, b, forge_url, forge_tok, work),
         {:ok, {out, code}} <-
           Fleet.Credentials.Shell.run(rail_path(), args, timeout_ms: @rail_timeout_ms) do
      # Attempt token removal before sweep: exit 6 deliberately keeps the clone for inspection.
      # Removal results are ignored, so this is not a guaranteed secret cleanup.
      _ = File.rm(Path.join(base, @token_basename))
      _ = sweep_work(base, code)

      case code do
        0 -> {:ok, parse_result(out)}
        _ -> {:error, {:rail_exit, code, last_line(out)}}
      end
    else
      # Clean partial token setup on any nonmatching with result, not just error tuples.
      other ->
        _ = File.rm_rf(base)
        other
    end
  end

  # Request the internal forge token from Authority rather than reading a projected store path.
  # The rail accepts a filename: passing the token itself in argv would expose it in cmdline.
  # Use a 0700 parent, exclusive file creation and 0600 mode; cleanup follows in do_run.
  defp materialise_token(base) do
    with {:ok, account} <- forge_account(),
         {:ok, token} <- ask_authority(account),
         :ok <- File.mkdir_p(base),
         :ok <- File.chmod(base, 0o700),
         path = Path.join(base, @token_basename),
         :ok <- File.write(path, token, [:exclusive]),
         :ok <- File.chmod(path, 0o600) do
      {:ok, path}
    else
      {:error, {_, _} = named} -> {:error, named}
      {:error, reason} -> {:error, {:forge_token_unavailable, reason}}
    end
  end

  defp forge_account do
    case Fleet.Credentials.ForgeAuth.account() do
      nil -> {:error, {:env_missing, "FORGE_PUSH_ACCOUNT"}}
      account -> {:ok, account}
    end
  end

  defp ask_authority(account) do
    case Fleet.Credentials.ForgeAuth.token_for(account) do
      {:ok, token} -> {:ok, token}
      {:error, cause} -> {:error, {:forge_token_unavailable, cause}}
    end
  end

  # The caller owns --work cleanup. Exit 6 preserves evidence of a nondeterministic rewrite.
  # Unique integers are VM-local; failed cleanup can leave paths that collide after restart.
  @keep_work_on_exit 6

  @doc false
  @spec sweep_work(String.t(), integer()) ::
          :kept_for_inspection | {:ok, [binary()]} | {:error, term(), binary()}
  def sweep_work(_work, @keep_work_on_exit), do: :kept_for_inspection
  def sweep_work(work, _code), do: File.rm_rf(work)

  # Require an explicit destination base: defaulting to main could silently target the wrong branch.
  # Missing or empty required strings return binding_incomplete.
  defp read_binding(slug) do
    path = Path.join([System.user_home!(), ".lcars", "publish", "#{slug}.json"])

    with {:ok, raw} <- file_read(path, {:not_linked, slug}),
         {:ok, map} when is_map(map) <- decode(raw, {:binding_invalid, path}),
         :ok <- require_keys(map, ~w(host dest_host dest_repo base), path) do
      {:ok, map}
    end
  end

  defp file_read(path, err) do
    case File.read(path) do
      {:ok, r} -> {:ok, r}
      {:error, _} -> {:error, err}
    end
  end

  defp decode(raw, err) do
    case Jason.decode(raw) do
      {:ok, m} -> {:ok, m}
      {:error, _} -> {:error, err}
    end
  end

  defp require_keys(map, keys, path) do
    missing = Enum.reject(keys, fn k -> is_binary(Map.get(map, k)) and Map.get(map, k) != "" end)
    if missing == [], do: :ok, else: {:error, {:binding_incomplete, path, missing}}
  end

  defp env(var) do
    case System.get_env(var) do
      v when is_binary(v) and v != "" -> {:ok, v}
      _ -> {:error, {:env_missing, var}}
    end
  end

  defp rail_args(repo, b, forge_url, forge_tok, work) do
    [
      "--project",
      repo,
      "--forge",
      forge_url,
      "--forge-token-file",
      forge_tok,
      "--host",
      b["host"],
      "--dest-repo",
      b["dest_repo"],
      "--dest-host",
      b["dest_host"],
      "--base",
      b["base"],
      "--work",
      work
    ]
  end

  # Resolve the co-installed rail from launcher configuration without an MCP-to-Spawner call.
  defp rail_path do
    launcher =
      Application.get_env(
        :lcars_fleet,
        :spawner_claude_launch_path,
        "/usr/local/bin/claude_launch.sh"
      )

    Path.join(Path.dirname(launcher), "publish-rail.sh")
  end

  # Keep the token in the parent and pass its absent clone child as --work;
  # the rail refuses a work path that already exists.
  defp fresh_work(slug) do
    Path.join(System.tmp_dir!(), "lcars-publish-#{slug}-#{System.unique_integer([:positive])}")
  end

  # Read the last -> URL. Compare/new-MR URL shape means manual completion;
  # a successful no-op has no URL. This does not verify the request remotely.
  defp parse_result(out) do
    url = parse_url(out)
    {url, manual_url?(url)}
  end

  defp parse_url(out) do
    out
    |> String.split("\n", trim: true)
    |> Enum.reverse()
    |> Enum.find_value("", fn line ->
      case Regex.run(~r{->\s*(https?://\S+)}, line) do
        [_, url] -> url
        _ -> false
      end
    end)
  end

  defp manual_url?(url), do: url =~ ~r{/compare/} or url =~ ~r{/merge_requests/new}

  defp outcome_log(url, _manual) when url == "", do: "nothing to publish"
  defp outcome_log(url, true), do: "pushed, PR/MR to open -> #{url}"
  defp outcome_log(url, false), do: url

  defp last_line(out) do
    out |> String.split("\n", trim: true) |> List.last() |> Kernel.||("")
  end

  # Bus delivery is lossy; discard its return explicitly to preserve run's :ok contract.
  @spec safe_emit(atom(), map(), String.t()) :: :ok
  defp safe_emit(type, payload, repo) do
    _ = Bus.safe_emit(:mcp, type, [payload: payload], context: "ProjectPublish: #{repo}")
    :ok
  end
end
