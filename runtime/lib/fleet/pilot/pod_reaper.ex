defmodule Fleet.Pilot.PodReaper do
  @moduledoc """
  Reaps ticket-bound pods after retirement, producer merge or judge verdict ingestion.
  Instance scope does not imply automatic termination after completion; leaving
  those pods resident can occupy role capacity needed by later tickets.

  reap_issue/2 enumerates reachable registry info maps and matches issue references
  through PodId.parse_ref/2, excluding PR references and ordinary project IDs.
  It inherits that parser's lossy repo-slug matching; unreachable pods are omitted.
  Producer and judge entry points instead construct one ID after checking profiles.
  MCP retirement uses :mcp_pod_reaper to cross its upward dependency boundary;
  :pilot_spawner selects this module's spawner implementation.

  Retiring a superseded ticket also retires its context: reassigning its producer
  would break one-pod/one-ticket ownership and carry reasoning from a retracted
  brief. Useful knowledge should travel in the replacement ticket's written context.

  Reaping does not roll back a preceding merge or retirement. :not_found is benign,
  but this module is not universally best effort: unexpected enumeration shapes
  and unhandled kill results can raise; earlier kills are not undone.
  """

  require Logger

  @doc """
  Kills enumerated pods whose IDs encode repo and issue_n, returning IDs whose
  kill call returned :ok. Skips :not_found; other kill results are not handled.
  """
  @spec reap_issue(String.t(), pos_integer()) :: [String.t()]
  def reap_issue(repo, issue_n) when is_binary(repo) and is_integer(issue_n) do
    for pod_id <- live_pod_ids(),
        {:ok, {:issue, ^issue_n}} <- [Fleet.PodId.parse_ref(pod_id, repo)],
        reaped?(repo, issue_n, pod_id) do
      pod_id
    end
  end

  @doc """
  Attempts the issue-bound producer ID after loading an instance-scoped profile.
  Project scope, empty names and failed profile loads skip the kill. :not_found
  is benign; other returned kill errors raise through the unmatched case.
  The caller is responsible for invoking this after sealing.
  """
  @spec reap_producer(String.t(), pos_integer(), String.t()) :: :ok
  def reap_producer(repo, issue_n, producer) when is_binary(repo) and is_integer(issue_n) do
    with true <- producer != "",
         {:ok, profile} <- Fleet.CapProfile.load(producer),
         "instance" <- Fleet.CapProfile.slot_scope(profile) do
      pod_id = Fleet.PodId.for_issue(repo, issue_n, producer)

      case spawner().kill_pod(pod_id) do
        :ok ->
          Logger.info(
            "PodReaper: #{repo}##{issue_n} sealed — ticket-scoped producer pod #{pod_id} reaped " <>
              "(its context lived until the merge, as designed)"
          )

        {:error, :not_found} ->
          :ok
      end
    else
      _ -> :ok
    end
  end

  # Construct IDs through PodId and retain the scope guard even for judges:
  # a project-scoped judge would be shared across tickets.
  @doc """
  Attempts a PR-bound ID only for a loaded judge profile with instance scope.
  Intended after verdict ingestion. Returned kill errors are logged and return
  :ok; exceptions are not rescued. Missing or unsuitable profiles skip the kill.
  """
  @spec reap_judge(String.t(), integer(), String.t()) :: :ok
  def reap_judge(repo, pr, role) when is_binary(role) and role != "" do
    with {:ok, profile} <- Fleet.CapProfile.load(role),
         "judge" <- Fleet.CapProfile.brief_kind(profile),
         "instance" <- Fleet.CapProfile.slot_scope(profile) do
      pod_id = Fleet.PodId.for_pr(repo, pr, role)

      case spawner().kill_pod(pod_id) do
        :ok ->
          Logger.info(
            "PodReaper: #{repo}##{pr} verdict INGESTED — judge pod #{pod_id} reaped " <>
              "(its context lived until its review held, as designed)"
          )

        {:error, :not_found} ->
          :ok

        {:error, reason} ->
          # A failed reap leaves occupied capacity without undoing the ingested verdict.
          Logger.warning(
            "PodReaper: #{repo}##{pr} judge pod #{pod_id} NOT reaped (#{inspect(reason)}) " <>
              "— the verdict stands; the pod will be swept by its class"
          )
      end
    else
      _ -> :ok
    end
  end

  def reap_judge(_repo, _pr, _role), do: :ok

  # Spawner enumerates info maps, not IDs. Extract explicitly: silently feeding
  # maps into PodId.parse_ref would make every issue reap return an empty list.
  defp live_pod_ids do
    Enum.flat_map(spawner().list_pods(), fn
      %{pod_id: pod_id} when is_binary(pod_id) ->
        [pod_id]

      # Unidentifiable maps are skipped with a warning; do not guess a kill target.
      info when is_map(info) ->
        Logger.warning(
          "PodReaper: registry entry without :pod_id (#{inspect(Map.keys(info))}) — skipped, " <>
            "it cannot be bound to a ticket"
        )

        []

      # Non-map entries indicate a broken enumeration contract.
      other ->
        raise ArgumentError,
              "PodReaper: the pod enumeration seam returned #{inspect(other)} — expected a map " <>
                "carrying :pod_id. This module KILLS pods; it must never guess what it is looking at."
    end)
  end

  defp reaped?(repo, issue_n, pod_id) do
    case spawner().kill_pod(pod_id) do
      :ok ->
        Logger.info(
          "PodReaper: #{repo}##{issue_n} retired — pod #{pod_id} reaped (dead ticket, dead pod)"
        )

        true

      {:error, :not_found} ->
        false
    end
  end

  # Seam (test): the pod supervisor. Default = the prod module.
  defp spawner, do: Application.get_env(:lcars_fleet, :pilot_spawner, Fleet.Spawner)
end
