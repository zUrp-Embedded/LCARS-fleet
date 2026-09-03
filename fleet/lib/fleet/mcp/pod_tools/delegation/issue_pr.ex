defmodule Fleet.MCP.PodTools.Delegation.IssuePR do
  @moduledoc """
  Finding the pull request that belongs to an issue, and refusing a gesture whose target state
  cannot be established.

  The forge has no back-link from an issue to its PR: the tie is the feature branch, and reading
  it is a SEARCH that can fail three different ways — no PR, a PR already merged, a forge that
  cannot be reached. The three are kept apart all the way up, because "no PR" and "I could not
  ask" authorize opposite decisions on a retirement.
  """

  require Logger

  alias Fleet.Forge.Payload

  # Supersede pre-flight — BEFORE any write, fail-loud on anything unverifiable: the retirement
  # is a destructive gesture executed by the SYSTEM on the arch's intent. A mute forge is a refusal,
  # not a guess (a half-checked supersede could retire the wrong brick). An already-closed target is
  # LEGITIMATE (re-take an abandoned brick): filiation only, no retirement to execute.
  #
  # A LIVE PR IS NO LONGER A REFUSAL, AND THE OLD REFUSAL WAS A WORKAROUND. It read as a policy
  # ("let it land"); it was a CONSEQUENCE: nothing in the forge client knew how to close a PR.
  # Retiring the ticket without closing it left the PR open on an INDEPENDENT rail
  # (`dispatch_review` polls pulls, outside the lease) — judged, then merged, into a retired ticket.
  # So the refusal protected against an incoherence the gesture itself should have prevented.
  #
  # And the intent of a retirement — stop the machine, bound the cost — does not depend on whether a
  # PR exists. So the gesture is made COMPLETE (`:with_pr` → the PR closes with the ticket) instead
  # of being forbidden.
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

  # The retired ticket's PR dies with it. A failure PROPAGATES: closing the issue while leaving its
  # PR alive recreates the exact incoherence this gesture exists to prevent.
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

  # Gitea 1.26.4 (live 2026-07-19) rewrites a deleted merged head to `refs/pull/N/head`;
  # use the issue's `[merge:pr-N]` marker to recover that PR.
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

  # Several PRs can match one issue across state=all (a cancelled attempt + its successor):
  # the LIVE one wins, else the most recent (highest number).
  defp pick_pr([]), do: nil

  defp pick_pr(matches),
    do: Enum.find(matches, &(&1["state"] == "open")) || Enum.max_by(matches, & &1["number"])
end
