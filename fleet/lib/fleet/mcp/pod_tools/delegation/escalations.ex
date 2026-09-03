defmodule Fleet.MCP.PodTools.Delegation.Escalations do
  @moduledoc """
  ESCALATION channel — the architect's inbox: the tickets a producer handed back, labelled
  `awaits-arch` and assigned to the human the fleet runs as.

  An unreadable inbox is surfaced as `{:inbox_unreadable, repo, reason}`, never as an EMPTY
  inbox: "nothing to arbitrate" and "I could not look" are the same screen and the opposite
  situation.
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

  # LE DERNIER COMMENTAIRE N'EST PAS UN VERDICT. Cette fonction rendait le dernier corps non vide du
  # fil, sans filtre : des que l'arch avait repondu a une escalade, l'inbox lui renvoyait SA PROPRE
  # REPONSE comme etant la question a trancher — sous une description d'outil qui promet « the
  # worker's escalation comment — the reasoning ». On cherche donc le marqueur d'escalade, pas la
  # recence.
  #
  # `nil` quand aucun commentaire n'en porte, et c'est un resultat : le frein sur recurrence
  # (`IncidentConsumer.default_brake/3`) pose le label SANS commentaire, donc il n'y a rien a
  # rendre. Mieux vaut « pas de verdict enregistre » qu'un texte qui n'en est pas un.
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
