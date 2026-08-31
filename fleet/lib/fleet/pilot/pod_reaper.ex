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

    * the MERGE — `Fleet.Pilot.MergeAndPromote` reaps the producer it just sealed (it knows the
      role, so it kills one precise id);
    * the SUPERSEDE — `Fleet.MCP`'s delegation retires an issue and calls THIS module through the
      `:pod_reaper` upward seam (MCP cannot reference `Fleet.Pilot`, cf. the `:forge_client`
      precedent), because it does NOT know which roles were live on that ticket.

  **The registry is the source of truth, never an enumeration of roles.** We kill every live pod
  whose id encodes THIS issue — `Fleet.PodId.parse_ref/2`, the authority that BUILDS the
  format is the one that recognizes it. A project-scoped pod (`<repo>-<role>`, the architect)
  encodes no instance → `parse_ref` rejects it → it is never touched, which is the whole point:
  it outlives the tickets by design.

  **Why a superseded ticket loses its pods** (⚖ user): handing the live
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
  """

  require Logger

  @doc """
  Kills every live pod bound to `issue_n` of `repo`. Returns the ids actually reaped.
  """
  @spec reap_issue(String.t(), pos_integer()) :: [String.t()]
  def reap_issue(repo, issue_n) when is_binary(repo) and is_integer(issue_n) do
    for pod_id <- live_pod_ids(),
        {:ok, {:issue, ^issue_n}} <- [Fleet.PodId.parse_ref(pod_id, repo)],
        reaped?(repo, issue_n, pod_id) do
      pod_id
    end
  end

  # ⚠ `Fleet.Spawner.list_pods/0` ENUMERE LES MAPS `:info` DES PODS, PAS LEURS IDS. Les lire comme
  # des ids fait tomber chaque map dans la clause fourre-tout `:error` de `PodId.parse_ref/2`, qui
  # garde sur `is_binary` : la comprehension filtre alors TOUT, `reap_issue/2` rend `[]` a chaque
  # appel, et comme ses deux appelants (le sceau et le supersede) sont best-effort par conception,
  # RIEN NE SE PLAINT. Un faucheur qui ne fauche rien, en silence, aux deux bouts de chaque ticket —
  # le producteur d'un ticket retire continue de travailler et merge sa PR dedans.
  #
  # The extraction is EXPLICIT rather than a pattern-match in the comprehension head: a seam whose
  # shape drifts again must fail loudly here, not filter silently one caller further down.
  defp live_pod_ids do
    Enum.flat_map(spawner().list_pods(), fn
      %{pod_id: pod_id} when is_binary(pod_id) ->
        [pod_id]

      # A map WITHOUT `pod_id` is a registry entry we cannot identify — we skip it (killing what we
      # cannot name is worse than not killing) but we SAY it: a silent skip is how the whole defect
      # above stayed invisible.
      info when is_map(info) ->
        Logger.warning(
          "PodReaper: registry entry without :pod_id (#{inspect(Map.keys(info))}) — skipped, " <>
            "it cannot be bound to a ticket"
        )

        []

      # NOT a map = the seam's shape drifted (bare ids where maps are expected, the shape above
      # guards against). Loud: a module that KILLS pods must never guess what it is looking at.
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
