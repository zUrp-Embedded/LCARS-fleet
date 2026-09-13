defmodule Fleet.MCP.PodTools.Delegation.IssuePR do
  @moduledoc """
  Finds an issue's PR by feature branch, then merged-seal fallback. Preserve the
  distinction between no PR and an unreadable forge when deciding retirement.
  Selection is a snapshot: it provides no lock against a subsequent state change.
  """

  require Logger

  alias Fleet.Forge.Payload

  # Read before retirement. An already-closed issue needs filiation only and skips
  # PR lookup. Other successful issue responses are treated as open; this is not
  # strict payload validation. A live PR is returned so retirement can close it too.
  @doc false
  @spec target_state_preflight(module(), String.t(), integer() | nil | term()) ::
          {:ok, nil | :closed | :open | {:open, integer()}} | {:error, term()}
  def target_state_preflight(_forge, _repo, nil), do: {:ok, nil}

  def target_state_preflight(forge, repo, n) when is_integer(n) and n > 0 do
    case forge.get_issue(repo, n, []) do
      {:ok, %{"state" => "closed"}} ->
        {:ok, :closed}

      {:ok, _open} ->
        case find_issue_pr(forge, repo, n) do
          {:ok, %{"state" => "open", "number" => pr}} -> {:ok, {:open, pr}}
          {:ok, _closed_pr} -> {:ok, :open}
          :none -> {:ok, :open}
          {:error, _} -> {:error, {:target_unverifiable, n}}
        end

      err ->
        Logger.warning(
          "Delegation: target preflight ##{n} on #{repo} unreadable (#{inspect(err)}) — REFUSED"
        )

        {:error, {:target_unreadable, n}}
    end
  end

  def target_state_preflight(_forge, _repo, _bad), do: {:error, :invalid_target}

  # Propagate PR closure failure so retirement does not continue with a live PR.
  @doc false
  @spec close_live_pr(module(), String.t(), integer() | nil) :: :ok | {:error, term()}
  def close_live_pr(_forge, _repo, nil), do: :ok

  def close_live_pr(forge, repo, pr) do
    case forge.close_pr(repo, pr, []) do
      {:ok, _} -> :ok
      {:error, reason} -> {:error, {:live_pr_not_closed, pr, reason}}
    end
  end

  # Uses the injected forge seam's single-authority feature-branch parser.
  @doc false
  @spec find_issue_pr(module(), String.t(), integer()) ::
          {:ok, map()} | :none | {:error, :forge_unreachable}
  def find_issue_pr(forge, repo, number) do
    case forge.list_pulls(repo, []) do
      {:ok, pulls} ->
        # C-05: parsing remains delegated; this seam owns only selection and merged fallback.
        pulls
        |> Enum.filter(fn pr ->
          head = Payload.head_ref(pr) || ""
          match?({:ok, {^number, _role}}, forge.parse_feature_branch(head))
        end)
        |> pick_pr()
        |> case do
          nil -> merged_pr_fallback(forge, repo, number)
          pr -> {:ok, pr}
        end

      # Preserve forge outage as distinct from no PR.
      err ->
        Logger.warning(
          "Delegation: find_issue_pr #{repo}##{number} forge unreachable (list_pulls → " <>
            "#{inspect(err)}) — typed :forge_unreachable"
        )

        {:error, :forge_unreachable}
    end
  end

  # Deleted merged branches can lose the feature ref; recover through the merge seal.
  defp merged_pr_fallback(forge, repo, number) do
    case forge.merged_pr_of_issue(repo, number, []) do
      {:ok, pr} ->
        {:ok, pr}

      :none ->
        :none

      # Preserve marker-read outage as distinct from no PR.
      err ->
        Logger.warning(
          "Delegation: find_issue_pr #{repo}##{number} forge unreachable (merged_pr_of_issue → " <>
            "#{inspect(err)}) — typed :forge_unreachable"
        )

        {:error, :forge_unreachable}
    end
  end

  # Prefer the first open match in forge order; otherwise choose the highest PR number.
  defp pick_pr([]), do: nil

  defp pick_pr(matches),
    do: Enum.find(matches, &(&1["state"] == "open")) || Enum.max_by(matches, & &1["number"])
end
