defmodule Fleet.Pilot.WakeRecovery do
  @moduledoc """
  Durcissement de `Fleet.Spawner.wake_pod/1`. Un échec de wake (pod injoignable : `:not_found`,
  tmux absent/mort) n'est PAS bloquant en soi. Le modèle :

    - **déjà vu** — l'incident est dans le registre persistant `Fleet.Pilot.IncidentRegistry` (donc déjà
      survenu, éventuellement en session précédente) → **escalade DIRECTE** : pattern, pas random → root-cause ;
    - **1er coup** → **re-roll** (re-spawn injecté + re-wake) :
        - re-wake OK → **récupéré** → on GRAVE l'incident dans le registre (ancre pour la prochaine fois) ;
        - re-wake FAIL → le re-roll n'a pas réparé → **escalade IMMÉDIATE** (problème actif).

  Escalade = issue système (`fleet/lcars`, label `error_system`, assignee `starfleet`=sysadmin), `reason`
  préservé, 2 portes distinctes (`:recurrence` / `:reroll_failed`). Frontière : un wake raté = **problème
  de FLEET → starfleet** (qui peut re-spawner/réparer), PAS le gatekeeper (juge de projet). **La mémoire
  vit dans le PROJET** (registre `work/ops`), pas la session : session exécute, projet se souvient,
  système répare.

  Seams (fonctions) pour le test ; défauts = les vraies fns. API `wake/3` inchangée pour les appelants.
  """
  require Logger

  alias Fleet.Pilot.IncidentRegistry

  @doc """
  Réveille `pod_id` avec recovery. `respawn_fun/0` = le re-spawn type-spécifique injecté par l'appelant
  (reboot du gatekeeper ; re-spawn worker). Pré-requis : le brief est DÉJÀ en file.

  Returns `:ok` | `{:error, term()}` (du re-wake) | `{:error, {:escalated, reason}}` (issue sysadmin
  RÉELLEMENT ouvert) | `{:error, {:escalation_failed, reason}}` (récurrence/re-roll KO mais l'ouverture du
  issue a échoué — forge down ? — AUCUN issue n'existe : retour HONNÊTE, pas un `:escalated` rassurant).
  """
  @spec wake(String.t(), (-> any()), keyword()) :: :ok | {:error, term()}
  def wake(pod_id, respawn_fun, opts \\ [])
      when is_binary(pod_id) and is_function(respawn_fun, 0) do
    wake_fun = Keyword.get(opts, :wake_fun, &Fleet.Spawner.wake_pod/1)

    case wake_fun.(pod_id) do
      :ok -> :ok
      {:error, reason} -> handle_fail(pod_id, reason, respawn_fun, wake_fun, opts)
    end
  end

  defp handle_fail(pod_id, reason, respawn_fun, wake_fun, opts) do
    seen_before_fun = Keyword.get(opts, :seen_before_fun, &IncidentRegistry.seen_before?/1)
    note_fun = Keyword.get(opts, :note_fun, &IncidentRegistry.note/2)
    op = Keyword.get(opts, :op, "wake")
    sig = IncidentRegistry.signature(op, pod_id, reason)

    if seen_before_fun.(sig) do
      Logger.error(
        "WakeRecovery #{pod_id} : #{inspect(reason)} DÉJÀ VU (#{sig}) → escalade directe (récurrence)"
      )

      escalate_or_signal(:recurrence, pod_id, reason, sig, opts)
    else
      Logger.warning("WakeRecovery #{pod_id} : #{inspect(reason)} (1er — #{sig}) → re-roll")
      _ = respawn_fun.()
      re_wake(pod_id, reason, sig, wake_fun, note_fun, opts)
    end
  end

  defp re_wake(pod_id, reason, sig, wake_fun, note_fun, opts) do
    case wake_fun.(pod_id) do
      :ok ->
        _ = note_fun.(sig, reason)
        Logger.info("WakeRecovery #{pod_id} : re-roll OK → incident gravé (#{sig})")
        :ok

      err ->
        Logger.error(
          "WakeRecovery #{pod_id} : re-roll n'a pas réparé (#{inspect(err)}) → escalade immédiate"
        )

        escalate_or_signal(:reroll_failed, pod_id, reason, sig, opts)
    end
  end

  # Ouvre le issue sysadmin ET propage le résultat CONSTATÉ (jamais `:escalated` par optimisme) :
  #   - issue ouvert (`{:ok, _}`) → `{:error, {:escalated, reason}}` (wake raté + alarme passée) ;
  #   - ouverture KO (`{:error, _}`, forge down ?) → log LOUD + `{:error, {:escalation_failed, _}}` :
  #     AUCUN issue n'existe, l'appelant ne doit pas croire qu'un sysadmin a été prévenu.
  # Partagé par les 2 portes d'escalade (récurrence directe / re-roll épuisé) — même propagation.
  defp escalate_or_signal(kind, pod_id, reason, sig, opts) do
    case IncidentRegistry.escalate(kind, pod_id, reason, sig, opts) do
      {:ok, _num} ->
        {:error, {:escalated, reason}}

      {:error, e} ->
        Logger.error(
          "WakeRecovery #{pod_id} : escalade (#{kind}) ÉCHOUÉE — AUCUN issue sysadmin créé " <>
            "(forge down ?) : #{inspect(e)} ; l'incident N'EST PAS escaladé"
        )

        {:error, {:escalation_failed, e}}
    end
  end
end
