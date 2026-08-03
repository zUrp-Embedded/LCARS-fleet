defmodule Fleet.Pilot.PodReaper do
  @moduledoc """
  Reaps the pods bound to a DEAD ticket.

  Exists because a `slot_scope: instance` producer is context-long: nothing kills it on its own
  (`Pod`'s post-completion branch — "Release only on external kill_pod or deadline timeout" — and
  `PodWarden` only sweeps the substrate of ALREADY-dead pods). Every terminal end of a ticket must
  therefore name its reaping, or the role's pool seats fill with pods nobody is waiting on and
  every later ticket of that role is deferred on `wait/capacity` — a fleet that looks busy while
  it is only un-harvested.

  Two callers, two ends of a ticket:

    * the MERGE — `Fleet.Pilot.GatekeeperSeal` reaps the producer it just sealed (it knows the
      role, so it kills one precise id);
    * the SUPERSEDE — `Fleet.MCP`'s delegation retires an issue and calls THIS module through the
      `:pod_reaper` upward seam (MCP cannot reference `Fleet.Pilot`, cf. the `:forge_client`
      precedent), because it does NOT know which roles were live on that ticket.

  **The registry is the source of truth, never an enumeration of roles.** We kill every live pod
  whose id encodes THIS issue — `Fleet.Pilot.PodId.parse_ref/2`, the authority that BUILDS the
  format is the one that recognizes it. A project-scoped pod (`<repo>-<role>`, the architect)
  encodes no instance → `parse_ref` rejects it → it is never touched, which is the whole point:
  it outlives the tickets by design.

  **Why a superseded ticket loses its pods** (user arbitrage 2026-08-03): handing the live
  producer over to the replacement ticket was rejected on three counts — it would re-create the
  resident-that-changes-subject the ticket-live lot just removed, breaking "one pod, one ticket"
  at its first exception; a supersede happens BECAUSE the brief was wrong, so the producer
  reasoned from a RETRACTED premise and would have to un-believe it selectively; and the
  knowledge worth keeping already travels IN WRITING (the new ticket's body states what the old
  one got wrong) — a fact is never carried by RAM alone. A lost warm context costs a re-read; a
  dead premise carried forward costs a deliverable, and it surfaces late.

  Best-effort by construction: the retirement/merge that precedes it is authoritative and never
  rolls back for a failed reaping; `{:error, :not_found}` is the NOMINAL case (already dead, or
  replay), hence no error path and idempotence.

  **Last revised**: 2026-08-03
  """

  require Logger

  @doc """
  Kills every live pod bound to `issue_n` of `repo`. Returns the ids actually reaped.
  """
  @spec reap_issue(String.t(), pos_integer()) :: [String.t()]
  def reap_issue(repo, issue_n) when is_binary(repo) and is_integer(issue_n) do
    for pod_id <- spawner().list_pods(),
        {:ok, {:issue, ^issue_n}} <- [Fleet.Pilot.PodId.parse_ref(pod_id, repo)],
        reaped?(repo, issue_n, pod_id) do
      pod_id
    end
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
  defp spawner, do: Application.get_env(:fleet_pilot, :spawner, Fleet.Spawner)
end
