defmodule Fleet.MCP.PodTools.Delegation.Escalations do
  @moduledoc """
  Reads awaits-arch issues in the pod-bound project, scoped to the configured human.
  Issue-list failure returns inbox_unreadable. Individual verdict-read failures are
  logged and rendered as nil, indistinguishable in the result from no marked comment.
  """

  require Logger

  alias Fleet.Forge.Payload
  alias Fleet.MCP.PodTools.Delegation.Gate

  @doc """
  Lists the current project's `lcars-awaits-arch` issues for architect arbitration.
  """
  @spec list_escalations(map()) :: {:ok, map()} | {:error, term()}
  def list_escalations(state) do
    with {:ok, %{repo: repo}} <- Gate.require_architect(state),
         {:ok, forge} <- Gate.conforming_escalation_forge(),
         {:ok, escalations} <- collect_awaits_arch(forge, repo, escalation_human()) do
      {:ok, %{"count" => length(escalations), "escalations" => escalations}}
    end
  end

  @awaits_arch_label Fleet.Labels.awaits_arch()

  @spec collect_awaits_arch(module(), String.t(), String.t()) ::
          {:ok, [map()]} | {:error, {:inbox_unreadable, String.t(), term()}}
  defp collect_awaits_arch(forge, repo, human) do
    case forge.list_open_issues(repo, assigned_by: human) do
      {:ok, issues} when is_list(issues) ->
        entries =
          issues
          |> Enum.filter(&has_awaits_arch_label?/1)
          |> Enum.map(&escalation_entry(forge, repo, &1))

        {:ok, entries}

      other ->
        Logger.warning(
          "Delegation: list_escalations — inbox unreadable: repo #{repo} (#{inspect(other)}) — " <>
            "surfaced as error, not an empty inbox"
        )

        {:error, {:inbox_unreadable, repo, other}}
    end
  end

  defp has_awaits_arch_label?(issue) do
    Payload.labels(issue)
    |> Enum.any?(&(is_map(&1) and &1["name"] == @awaits_arch_label))
  end

  defp escalation_entry(forge, repo, issue) do
    number = Map.get(issue, "number")

    %{
      "number" => number,
      "title" => Map.get(issue, "title"),
      "verdict" => latest_verdict(forge, repo, number)
    }
  end

  defp latest_verdict(_forge, _repo, number) when not is_integer(number), do: nil

  # Select the escalation marker, not a later architect reply. A recurrence brake
  # can label an issue without posting a verdict, so nil need not mean an outage.
  defp latest_verdict(forge, repo, number) do
    case forge.escalation_verdict(repo, number, []) do
      {:ok, body} ->
        body

      other ->
        Logger.warning(
          "Delegation: list_escalations — comments of #{repo}##{number} unreadable (#{inspect(other)})"
        )

        nil
    end
  end

  defp escalation_human, do: Fleet.Credentials.Human.current!()
end
