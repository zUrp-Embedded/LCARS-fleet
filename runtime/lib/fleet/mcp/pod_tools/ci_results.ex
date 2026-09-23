defmodule Fleet.MCP.PodTools.CiResults do
  @moduledoc """
  What the CI proved on the head a judge is judging: the forge's aggregate verdict for that SHA,
  each workflow run with its outcome, and the end of the log of every run that failed.

  The CI is the environment of record. A suite that needs system packages (a browser, a toolchain)
  runs there, never in a pod: a judge reads its result instead of replaying it, and does not have to
  conclude « proved by reading » (2026-09-23: judges could not run `test_app.js`, the CI ran it on
  every push). Probe runs (`probe-*`) are left out: they measure the suite, they are not the suite.

  Read-only. The PR comes from the pod's identity (`JudgeTarget`), never from the arguments.
  """

  alias Fleet.MCP.PodTools.JudgeTarget

  @log_tail_lines 80

  @doc "Reads the CI results of the head of the PR the pod judges."
  @spec run(String.t(), keyword()) :: {:ok, map()} | {:error, term()}
  def run(pod_id, opts \\ []) when is_binary(pod_id) do
    fopts = Keyword.get(opts, :forge_opts, [])

    with {:ok, %{repo: repo, pr: pr, refs: %{head_sha: head}}} <-
           JudgeTarget.resolve(pod_id, forge(), fopts),
         {:ok, {verdict, contexts}} <- forge().commit_ci_report(repo, head, fopts),
         {:ok, runs} <- actions().runs_for_sha(repo, head, [], fopts) do
      {:ok,
       %{
         "pr" => pr,
         "head_sha" => head,
         "verdict" => Atom.to_string(verdict),
         "contexts" => contexts,
         "runs" => runs |> Enum.reject(&probe?/1) |> Enum.map(&describe(repo, &1, fopts))
       }}
    end
  end

  defp probe?(%{"path" => path}) when is_binary(path), do: String.contains?(path, "probe-")
  defp probe?(_), do: false

  defp describe(repo, run, fopts) do
    base = %{
      "run_id" => run["id"],
      "workflow" => run["path"],
      "event" => run["event"],
      "status" => run["status"],
      "conclusion" => run["conclusion"]
    }

    if run["conclusion"] == "failure" and is_integer(run["id"]),
      do: Map.put(base, "log_tail", log_tail(repo, run["id"], fopts)),
      else: base
  end

  # The end of the log is where a CI failure says why; the whole log would drown the judge.
  defp log_tail(repo, run_id, fopts) do
    case actions().run_logs(repo, run_id, fopts) do
      {:ok, logs} ->
        logs |> String.split("\n") |> Enum.take(-@log_tail_lines) |> Enum.join("\n")

      {:error, reason} ->
        "journal illisible : #{inspect(reason)}"
    end
  end

  defp forge, do: Application.get_env(:lcars_fleet, :mcp_probe_forge_client, Fleet.Forge.Client)

  defp actions,
    do: Application.get_env(:lcars_fleet, :forge_actions, Fleet.Forge.Client.Actions)
end
