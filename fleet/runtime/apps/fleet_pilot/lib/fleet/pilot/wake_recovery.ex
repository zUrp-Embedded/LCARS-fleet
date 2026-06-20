defmodule Fleet.Pilot.WakeRecovery do
  @moduledoc """
  Durcissement de `Fleet.Spawner.wake_pod/1` (#5.2). Un échec de wake (pod injoignable : `:not_found`,
  tmux absent/mort) n'est PAS bloquant en soi :

    - **1er fail = event aléatoire** (1000 causes random) → on **re-roll** (re-spawn + re-wake), pas de bruit ;
    - **2e fail = pattern vérifié + debuggable** → **escalade** : ticket système sur `fleet/lcars`, label
      `error_system`, assignee `starfleet` (= rôle **sysadmin**), corps portant le `reason` préservé.

  Frontière (graphe 2-frontières) : un wake raté = **problème de FLEET → starfleet** (sysadmin, qui peut
  re-spawner/réparer), PAS le gatekeeper (juge de projet, qui ne peut rien en faire). Le compteur per-pod
  est owné par `Fleet.Spawner.PodWarden` (survit aux pods → compte même un `:not_found` ; reset au succès).

  Le wrapper vit ici (fleet_pilot : `ForgeClient` + les appelants hop_consumer/stage_dispatcher) ; l'état
  (compteur) vit dans fleet_spawner (PodWarden). Seams (fonctions) pour le test ; défauts = les vraies fns.
  """
  require Logger

  @doc """
  Réveille `pod_id` avec recovery. `respawn_fun/0` = le re-spawn **type-spécifique** injecté par l'appelant
  (reap + `ensure_booted` pour un permanent ; `spawn_pod`/`:recreate` pour un worker). Pré-requis : le
  mandat est DÉJÀ en file (`wake_pod` n'est qu'un trigger).

  Returns `:ok` | `{:error, term()}` (du re-wake) | `{:error, {:escalated, reason}}`.
  """
  @spec wake(String.t(), (-> any()), keyword()) :: :ok | {:error, term()}
  def wake(pod_id, respawn_fun, opts \\ [])
      when is_binary(pod_id) and is_function(respawn_fun, 0) do
    wake_fun = Keyword.get(opts, :wake_fun, &Fleet.Spawner.wake_pod/1)
    note_fun = Keyword.get(opts, :note_fail_fun, &Fleet.Spawner.PodWarden.note_wake_fail/1)
    clear_fun = Keyword.get(opts, :clear_fail_fun, &Fleet.Spawner.PodWarden.clear_wake_fail/1)
    reroll_max = Keyword.get(opts, :reroll_max, 1)

    case wake_fun.(pod_id) do
      :ok ->
        _ = clear_fun.(pod_id)
        :ok

      {:error, reason} ->
        case note_fun.(pod_id) do
          n when n <= reroll_max ->
            Logger.warning(
              "WakeRecovery #{pod_id} : wake fail ##{n} (#{inspect(reason)}) → re-roll (re-spawn + re-wake)"
            )

            _ = respawn_fun.()
            wake_fun.(pod_id)

          n ->
            Logger.error(
              "WakeRecovery #{pod_id} : wake fail ##{n} (#{inspect(reason)}) → escalade système (starfleet)"
            )

            _ = escalate(pod_id, reason, n, opts)
            {:error, {:escalated, reason}}
        end
    end
  end

  # Ticket système → starfleet (sysadmin). Label = signal DURABLE (toujours posé). Assignee = best-effort :
  # le compte rôle `starfleet` doit exister sur la forge ; sinon Gitea rejette → fallback label-only (le
  # label reste le canal de découverte). cf. BL « ping starfleet à la création d'un ticket système ».
  defp escalate(pod_id, reason, count, opts) do
    create_fun = Keyword.get(opts, :create_issue_fun, &Fleet.Pilot.ForgeClient.create_issue/4)
    repo = opts[:repo] || Application.get_env(:fleet_pilot, :system_ticket_repo, "fleet/lcars")

    label =
      opts[:label] || Application.get_env(:fleet_pilot, :system_ticket_label, "error_system")

    assignee =
      opts[:assignee] || Application.get_env(:fleet_pilot, :system_ticket_assignee, "starfleet")

    title = "[#{label}] pod injoignable : #{pod_id}"

    body = """
    Pod `#{pod_id}` injoignable après #{count} tentative(s) de wake (re-roll inclus).
    Dernière raison : `#{inspect(reason)}`.

    Domaine SYSADMIN (panne du substrat : tmux / bwrap / launch) — PAS un problème de projet.
    Action : vérifier le substrat, re-spawner ou diagnostiquer.

    (Ticket auto — durcissement wake_pod #5.2.)
    """

    case create_fun.(repo, title, body, labels: [label], assignees: [assignee]) do
      {:ok, _} = ok -> ok
      {:error, _} -> create_fun.(repo, title, body, labels: [label])
    end
  end
end
