defmodule Fleet.MCP.PodTools.GithubPublish do
  @moduledoc """
  ASYNC worker behind the `github_publish` tool (phase 2 of chantier-publication-github).

  The tool call itself only ENQUEUES (a Task under `Fleet.MCP.PublishTaskSupervisor`) and returns
  `queued` — filter-repo rewrites the WHOLE history every run (O(history), ~minutes on a large repo),
  so the pod's turn must not block on it. This module IS that Task's body.

  It resolves the project's PER-HUMAN publish binding (`~/.lcars/publish/<slug>.json`, written by
  `lcars approve`), then runs the host-side rail `bin/publish-rail.sh` — which force-pushes a rolling
  branch and, if the forge CLI is present+authed (Tier 1), opens/updates the PR/MR; otherwise (Tier 2)
  it hands back a ready-to-open compare/new-MR URL. NO EXTERNAL TOKEN IS HANDLED here or by the rail:
  auth is the forge's official CLI (`gh`/`glab`, the wired git credential helper) or the operator's own
  wired helper — nothing token-shaped ever enters a pod, an argv, or a config we write.

  The outcome is emitted on the Bus (lossy/observability, `safe_emit` — a missing subscriber never
  crashes the Task): `github_publish.done` with the url and a `manual` flag (true = Tier 2, the url is a
  "PR/MR to open" link, not an opened request), or `github_publish.failed` with the reason. Not-linked /
  missing forge config / a non-zero rail / a raise all land as `.failed`, never a crash.
  """

  require Logger
  alias Fleet.EventRouter.Bus

  # Generous wall deadline: the rail re-clones the internal repo and filter-repo rewrites its whole
  # history on every run. Shell.run kills the whole process-group at the deadline.
  @rail_timeout_ms 15 * 60 * 1000

  @doc """
  Runs one publish of `repo` (internal `owner/name`) to its linked external forge, start to finish.

  Meant to be the body of a `Fleet.MCP.PublishTaskSupervisor` Task (the tool enqueues it). Always
  returns `:ok` and reports the outcome ONLY on the Bus (`github_publish.done` / `.failed`) — every
  failure path, including a raise, is turned into a `.failed` event, never a crash that the supervisor
  would restart into a re-publish.
  """
  @spec run(String.t(), String.t() | nil) :: :ok
  def run(repo, requester \\ nil) when is_binary(repo) do
    case do_run(repo) do
      {:ok, {url, manual}} ->
        Logger.info("GithubPublish: #{repo} -> #{outcome_log(url, manual)}")

        safe_emit(
          :"github_publish.done",
          %{"repo" => repo, "url" => url, "manual" => manual, "requester_pod_id" => requester},
          repo
        )

      {:error, reason} ->
        {cat, detail} = Fleet.Event.reason_fields(reason)
        Logger.warning("GithubPublish: #{repo} FAILED — #{detail}")

        safe_emit(
          :"github_publish.failed",
          %{"repo" => repo, "reason" => cat, "reason_detail" => detail, "requester_pod_id" => requester},
          repo
        )
    end

    :ok
  rescue
    e ->
      Logger.error("GithubPublish: #{repo} RAISED — #{Exception.message(e)}")

      safe_emit(
        :"github_publish.failed",
        %{"repo" => repo, "reason" => "raised", "reason_detail" => Exception.message(e), "requester_pod_id" => requester},
        repo
      )

      :ok
  end

  defp do_run(repo) do
    slug = repo |> String.split("/") |> List.last()

    with {:ok, b} <- read_binding(slug),
         {:ok, forge_url} <- env("FORGE_BASE_URL"),
         {:ok, forge_tok} <- env("FORGE_TOKEN_FILE"),
         args = rail_args(repo, b, forge_url, forge_tok, fresh_work(slug)),
         {:ok, {out, 0}} <- Fleet.Credentials.Shell.run(rail_path(), args, timeout: @rail_timeout_ms) do
      {:ok, parse_result(out)}
    else
      {:ok, {out, code}} -> {:error, {:rail_exit, code, last_line(out)}}
      {:error, _} = err -> err
    end
  end

  # The per-human binding is the source of truth for WHERE this project publishes (chantier §5bis).
  defp read_binding(slug) do
    path = Path.join([System.user_home!(), ".lcars", "publish", "#{slug}.json"])

    with {:ok, raw} <- file_read(path, {:not_linked, slug}),
         {:ok, map} when is_map(map) <- decode(raw, {:binding_invalid, path}),
         :ok <- require_keys(map, ~w(host dest_host dest_repo), path) do
      {:ok, map}
    end
  end

  defp file_read(path, err), do: (case File.read(path), do: ({:ok, r} -> {:ok, r}; {:error, _} -> {:error, err}))
  defp decode(raw, err), do: (case Jason.decode(raw), do: ({:ok, m} -> {:ok, m}; {:error, _} -> {:error, err}))

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
      "--project", repo,
      "--forge", forge_url,
      "--forge-token-file", forge_tok,
      "--host", b["host"],
      "--dest-repo", b["dest_repo"],
      "--dest-host", b["dest_host"],
      "--base", Map.get(b, "base") || "main",
      "--work", work
    ]
  end

  # publish-rail.sh is co-located with the launchers (moved to bin/, install manifest). The bin dir is
  # the one already resolved for the launcher; reading its config keeps a single source of the bin
  # location without an MCP->Spawner call (config read, not a boundary edge). Namespace is the post-D-07
  # `:lcars_fleet` app with a domain-prefixed key; the pre-migration spawner atom is dead.
  defp rail_path do
    launcher = Application.get_env(:lcars_fleet, :spawner_claude_launch_path, "/usr/local/bin/claude_launch.sh")
    Path.join(Path.dirname(launcher), "publish-rail.sh")
  end

  # The rail REFUSES an existing --work; a unique fresh path per run satisfies that.
  defp fresh_work(slug) do
    Path.join(System.tmp_dir!(), "lcars-publish-#{slug}-#{System.unique_integer([:positive])}")
  end

  # The rail prints the url after `-> ` on success. Two shapes:
  #   Tier 1 auto: "PR/MR ouverte -> <pull/MR url>" / "actualisee ... -> <pull/MR url>"
  #   Tier 2 degraded: "branche ... poussee -- ouvre la PR/MR ici -> <compare|merge_requests/new url>"
  # "rien a publier" is a legitimate no-op success with no url. `manual` is inferred from the URL SHAPE
  # (compare / new-MR forms), not from prose: the rail's Tier-2 outcome is a "one more click", relayed
  # to the pod as such rather than as an opened request.
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

  defp safe_emit(type, payload, repo) do
    Bus.safe_emit(:mcp, type, [payload: payload], context: "GithubPublish: #{repo}")
  end
end
