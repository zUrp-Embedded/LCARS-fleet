defmodule Fleet.Spawner.Pod.StateFs do
  @moduledoc """
  PERSISTANCE FS du substrat recovery d'un pod — île d'écritures extraite de `Fleet.Spawner.Pod`.

  Deux gestes complémentaires : l'ÉCRITURE du `state.json` de recovery (l'état durable du pod sur disque,
  relu au prochain `init/1` par `recover_or_init` côté `Pod`) et l'EFFACEMENT des tombstones terminales :

  - `write_state_fs/1` — sérialise le snapshot `{v, session_id, cap_profile_name, started_at, phase,
    conditions, ticket_id}` du `state` dans `state.state_fs_path` (écriture ATOMIQUE `.tmp`+`rename`,
    `mkdir_p` de la racine). Un échec d'écriture = perte du point de recovery durable → LOUD (error-level →
    monitoring) mais NON-fatal (`:ok` rendu, on ne crashe pas le pod ici). Appelé à 4 sites du `Pod`
    (post-ALLOCATE, transitions, `transition_failed`).
  - `clear_terminal_snapshot/3` — efface la tombstone d'un `pod_id` AVANT un (re)spawn délibéré (no-op si
    pas de snapshot, snapshot illisible, ou phase EN VOL — on ne touche QUE les tombstones terminales).
    Appelé DIRECTEMENT par `Fleet.Spawner.spawn_pod/3` via `Fleet.Spawner.Pod.StateFs.clear_terminal_snapshot/3`.
  - `rm_terminal_artifacts/2` — efface les DEUX dossiers de l'empreinte disque d'un pod terminé (state-dir
    + pod_dir), geste PARTAGÉ appelé par `clear_terminal_snapshot/3` (local, même module) ET par le
    `PodWarden` (GC périodique des tombstones orphelines) via `Fleet.Spawner.Pod.StateFs.rm_terminal_artifacts/2`.

  Île d'I-O (File + Logger), pas de calcul pur : ne porte aucun state, aucun Port, aucun timer. Le `Pod`
  lui passe le `state` (write) ou `pod_id`/`cap_profile`/`opts` (clear/rm) en arguments ; le module ne
  rappelle aucun private de `Pod` (pas de cycle). Dépend de `Fleet.Spawner.Pod.Paths` (résolution des
  chemins state.json/pod_dir), `Fleet.Spawner.Pod.Recovery` (`phase_from_string`) et `Fleet.CapProfile`
  (source unique du `name` du snapshot) — déjà des deps de l'app.

  ## Contrat (appelants)

  - `write_state_fs/1` — appelé aux 4 sites internes du `Pod`.
  - `clear_terminal_snapshot/3` — appelé DIRECTEMENT via `Fleet.Spawner.Pod.StateFs.clear_terminal_snapshot/3`
    (valeur par défaut `opts \\ []`) par `Fleet.Spawner.spawn_pod/3` ET le test `pod_test.exs` (plus de
    wrapper délégant côté `Pod`).
  - `rm_terminal_artifacts/2` — appelé DIRECTEMENT via `Fleet.Spawner.Pod.StateFs.rm_terminal_artifacts/2`
    par le `PodWarden` (plus de defdelegate côté `Pod`).
  """

  require Logger

  alias Fleet.Spawner.Pod.Paths
  alias Fleet.Spawner.Pod.Recovery

  @doc """
  Efface la TOMBSTONE d'un `pod_id` AVANT un (re)spawn délibéré (appelé par
  `Fleet.Spawner.spawn_pod/3`).

  Sous l'id pod DÉTERMINISTE, un re-dispatch retombe sur le MÊME `pod_id`
  (`issue-N-role`). Si un `state.json` TERMINAL (`:succeeded`/`:released`/`:killed`)
  subsiste d'un cycle précédent — même d'une AUTRE issue #N sur un autre repo, l'id
  ne porte que le numéro —, `recover_or_init` le lit → `recovery_action` rend
  `:release` → le pod s'arrête AUSSITÔT (`do_release` sur backend nil, `{:stop,
  :normal}` MUET) sans rien lancer. Le poller voit alors le verrou in-flight sans
  complétion → réclame l'orphelin → re-dispatch → MÊME tombstone → boucle infinie
  (le pod ne lance jamais de claude).

  Un (re)spawn est TOUJOURS délibéré (sous `:temporary` le superviseur ne ressuscite
  jamais) → une tombstone terminale n'a rien à protéger ici : on l'efface + le pod_dir
  → `init` repart FRESH (`:allocate`). **No-op** si pas de snapshot, snapshot illisible,
  ou phase EN VOL (`:launching`/`:monitoring`/… → la recovery `:recreate` reste
  intacte — on ne touche QUE les tombstones).
  """
  @spec clear_terminal_snapshot(String.t(), Fleet.CapProfile.t(), keyword()) :: :ok
  def clear_terminal_snapshot(pod_id, %Fleet.CapProfile{} = cap_profile, opts \\ [])
      when is_binary(pod_id) and is_list(opts) do
    state_fs_path = Paths.state_fs_path_for(pod_id, cap_profile, opts)

    with {:ok, json} <- File.read(state_fs_path),
         {:ok, %{"phase" => phase_str}} <- Jason.decode(json),
         phase when phase in [:succeeded, :released, :killed] <-
           Recovery.phase_from_string(phase_str) do
      rm_terminal_artifacts(
        Path.dirname(state_fs_path),
        Paths.pod_dir_for(pod_id, opts)
      )

      Logger.info(
        "Pod.clear_terminal_snapshot #{pod_id}: tombstone :#{phase} effacée (re-spawn FRESH, BL-055)"
      )

      :ok
    else
      _ -> :ok
    end
  end

  @doc """
  Efface les DEUX dossiers qui composent l'empreinte disque d'un pod terminé : son **state-dir** (le
  dossier du `state.json`) et son **pod_dir** (clone git + `.lcars`/`.claude`/`tickets`) — deux arbres
  distincts. Idempotent (`rm_rf` ne lève pas sur l'absent). Geste PARTAGÉ, un seul site qui sait quels
  deux dossiers forment l'empreinte d'un pod : appelé par `clear_terminal_snapshot/3` (au re-spawn du
  même pod_id) ET par le `PodWarden` (GC périodique des tombstones orphelines jamais re-briefées). Ne
  lit ni ne vérifie la phase : l'appelant garantit déjà que le pod est terminal. Sûr car le seed
  `--resume` vit ailleurs (seed-store `projects.work/<projet>/pods/`), pas dans le pod_dir.
  """
  @spec rm_terminal_artifacts(String.t(), String.t()) :: :ok
  def rm_terminal_artifacts(state_dir, pod_dir)
      when is_binary(state_dir) and is_binary(pod_dir) do
    _ = File.rm_rf(state_dir)
    _ = File.rm_rf(pod_dir)
    :ok
  end

  @spec write_state_fs(map()) :: :ok
  def write_state_fs(state) do
    # Schéma complet du snapshot :
    # {v, session_id, cap_profile_name, started_at, phase, conditions, ticket_id}.
    payload = %{
      "v" => 1,
      "session_id" => state.session_id,
      "cap_profile_name" => Fleet.CapProfile.name(state.cap_profile),
      "started_at" => DateTime.to_iso8601(state.started_at),
      "phase" => Atom.to_string(state.phase),
      "conditions" => state.conditions |> MapSet.to_list() |> Enum.map(&Atom.to_string/1),
      "ticket_id" => state.ticket_id
    }

    tmp = state.state_fs_path <> ".tmp"

    # write_state_fs est appelé depuis transition_failed et d'autres sites — un
    # crash ici ferait régresser le cleanup. Non-bang (le {:stop, ...} prévu se
    # passe quand même).
    result =
      with :ok <- File.mkdir_p(Path.dirname(state.state_fs_path)),
           :ok <- File.write(tmp, Jason.encode!(payload, pretty: true)),
           :ok <- File.rename(tmp, state.state_fs_path) do
        :ok
      end

    case result do
      :ok ->
        :ok

      {:error, reason} ->
        # Échec d'écriture state.json = perte du point de recovery durable. C'est une
        # ERREUR (pas un warning) — `:ok` reste rendu (non-fatal : ne pas crasher ici)
        # mais le breach est LOUD (error-level → monitoring).
        Logger.error(
          "pod #{state.pod_id} write_state_fs ÉCHEC — point de recovery durable perdu " <>
            "(non-fatal) : #{inspect(reason)}"
        )

        :ok
    end
  end
end
