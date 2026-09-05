defmodule Fleet.Pilot.PodReaper do
  @moduledoc """
  Reaps the pods bound to a DEAD ticket.

  Exists because a `slot_scope: instance` producer is context-long: nothing kills it on its own
  (`Pod`'s post-completion branch — "Release only on external kill_pod or deadline timeout" — and
  `PodWarden` only sweeps the substrate of ALREADY-dead pods). Every terminal end of a ticket must
  therefore name its reaping, or the role's pool seats fill with pods nobody is waiting on and
  every later ticket of that role is deferred on `wait/capacity` — a fleet that looks busy while
  it is only un-harvested.

  Three callers, the three ends a pod can meet, ONE reader of the `:pilot_spawner` seam:

    * the MERGE — `Fleet.Pilot.MergeAndPromote` reaps the producer it just sealed through
      `reap_producer/3` (it knows the role, so one precise id dies, and only a ticket-scoped one);
    * the VERDICT — `Fleet.Pilot.StepRunCompleter` reaps the one-shot judge whose review it just
      ingested (`reap_judge/3`), never before: the pod's context lives until its verdict holds;
    * the SUPERSEDE — `Fleet.MCP`'s delegation retires an issue and calls THIS module through the
      `:mcp_pod_reaper` upward seam (MCP cannot reference `Fleet.Pilot` at compile time), because
      it does NOT know which roles were live on that ticket.

  **The registry is the source of truth, never an enumeration of roles.** We kill every live pod
  whose id encodes THIS issue — `Fleet.PodId.parse_ref/2`, the authority that BUILDS the
  format is the one that recognizes it. A project-scoped pod (`<repo>-<role>`, the architect)
  encodes no instance → `parse_ref` rejects it → it is never touched, which is the whole point:
  it outlives the tickets by design.

  **Why a superseded ticket loses its pods** (⚖ user): handing the live producer over to the
  replacement ticket is wrong on three counts — it re-creates the resident-that-changes-subject,
  breaking "one pod, one ticket" at its first exception; a supersede happens BECAUSE the brief was
  wrong, so the producer reasoned from a RETRACTED premise and would have to un-believe it
  selectively; and the
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

  @doc """
  Kills the ticket-scoped producer `producer` of `issue_n` once its PR is sealed — one precise id,
  and only when the profile is `slot_scope: instance`: a project-scoped producer (one pod for the
  whole repo) outlives its tickets by design and is never touched. `:ok` whatever happened, and
  `{:error, :not_found}` is the nominal case (a one-shot producer is already dead at seal time).
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

  # L'identite se CONSTRUIT comme le dispatcher la construit (`PodId.for_pr/3`), jamais comme une
  # chaine devinee — meme discipline que le jumeau producteur, qui lit `slot_scope` avant de tuer
  # pour ne pas faucher un pod partage par tout un projet.
  #
  # Un juge est `slot_scope: instance` par derivation (`one-shot`), donc la garde ci-dessous ne
  # devrait jamais mordre. Elle est la quand meme : le jour ou un role de jugement deviendrait
  # lie au PROJET, son pod serait partage, et le tuer sur un verdict couperait les autres.
  @doc """
  Kills the one-shot judge `role` of PR `pr` once its verdict is INGESTED — one precise id
  (`PodId.for_pr/3`), and only a `judge` of `slot_scope: instance`; a project-bound judge would be
  shared, so it is never touched. `:ok` whatever happened, a survivor said.
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
          # Un pod qui survit coute une place, il ne corrompt rien. On le DIT et on continue.
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

  # ⚠ `Fleet.Spawner.list_pods/0` ENUMERE LES MAPS `:info` DES PODS, PAS LEURS IDS. Les lire comme
  # des ids fait tomber chaque map dans la clause fourre-tout `:error` de `PodId.parse_ref/2`, qui
  # garde sur `is_binary` : la comprehension filtre alors TOUT, `reap_issue/2` rend `[]` a chaque
  # appel, et comme son appelant (le supersede MCP) est best-effort par conception, RIEN NE SE
  # PLAINT. Un faucheur qui ne fauche rien, en silence, a la retraite de chaque ticket —
  # le producteur d'un ticket retire continue de travailler et merge sa PR dedans.
  #
  # The extraction is EXPLICIT rather than a pattern-match in the comprehension head: a seam whose
  # shape drifts again must fail loudly here, not filter silently one caller further down.
  defp live_pod_ids do
    Enum.flat_map(spawner().list_pods(), fn
      %{pod_id: pod_id} when is_binary(pod_id) ->
        [pod_id]

      # A map WITHOUT `pod_id` is a registry entry we cannot identify — we skip it (killing what we
      # cannot name is worse than not killing) but we SAY it: a silent skip is how the defect
      # above would stay invisible.
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
