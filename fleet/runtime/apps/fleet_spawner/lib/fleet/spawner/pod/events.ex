defmodule Fleet.Spawner.Pod.Events do
  @moduledoc """
  Broadcasts BUS du cycle de vie pod — cluster extrait de `Fleet.Spawner.Pod`.

  Un seul rôle : diffuser sur le bus `fleet.events` les events de cycle de vie d'un pod, sous
  l'enveloppe canon stricte `%Fleet.Event{source: :spawner}`. La SÉPARATION load-bearing vs
  best-effort (cf. le commentaire de section ci-dessous) est le cœur du module : un `pod.completed`
  avalé en silence wedgerait le step_run (verrou forge à vie), un `pod.failed`/`wake.failed` avalé n'est
  qu'une perte d'observabilité.

  Aucun state, aucun Port, aucun timer : le `Pod` passe `event_type` (binaire) + `payload` (map) en
  arguments ; le module construit l'enveloppe et broadcaste. Le bus est lu via un SEAM app-env
  (`:fleet_spawner, :event_bus`, défaut `Fleet.EventRouter.Bus`) → un test injecte un bus stub sans
  toucher le registry global.

  ## Contrat (appelé par `Pod`)

  - `best_effort_broadcast/2` (PUBLIC) — OBSERVABILITÉ/escalade (`pod.failed`, `wake.failed`).
    Un échec est non-bloquant (rescue → log) ; rend toujours `:ok`.
  - `required_broadcast/2` (PUBLIC) — LIFECYCLE load-bearing (`pod.completed`). L'échec n'est PAS
    avalé : rend `:ok` | `{:error, {:broadcast_failed, _}}`. `do_extract` NE release/kill PAS le pod
    sur une complétion orpheline.

  `event_bus/0` et `build_spawner_event/2` sont internes (appelés UNIQUEMENT par les deux broadcasts).
  """

  require Logger

  alias Fleet.EventRouter.Bus

  # Classification load-bearing vs best-effort du broadcast (cf. task_queue/server.ex, même move).
  # Un `safe_broadcast` unique qui avalerait TOUTE exception en `:ok` engloutirait aussi `pod.completed`
  # dont le StepRunConsumer DÉPEND pour finir le step_run : un `pod.completed` avalé = le pod « réussit » (release/
  # kill pour un one-shot) MAIS la fin-de-step-run ne se déclenche jamais → verrou forge conservé à vie (wedge
  # silencieux). D'où la SÉPARATION :
  #   - `best_effort_broadcast/2` : OBSERVABILITÉ/escalade (`pod.failed`, `wake.failed`). Un échec est
  #     non-bloquant (rescue → log) — un consumer fleet_pilot les enregistre en best-effort, personne ne
  #     FINIT un step_run dessus.
  #   - `required_broadcast/2` : LIFECYCLE load-bearing (`pod.completed`). L'échec n'est PAS avalé : il
  #     remonte `{:error, {:broadcast_failed, _}}` → `do_extract` NE release/kill PAS le pod sur une
  #     complétion orpheline ; il reste vivant (re-wake re-fire l'extract), fail-loud. Les deux passent
  #     par l'enveloppe canon stricte `%Fleet.Event{source: :spawner}` (build_spawner_event).

  # Broadcast Bus avec rescue : un crash event_router (bus down, atom invalide) ne doit JAMAIS faire crash
  # le Pod GenServer. RÉSERVÉ aux events NON-lifecycle (observabilité/escalade).
  # Enveloppe : schema canon strict %Fleet.Event{source: :spawner}.
  def best_effort_broadcast(event_type, payload) when is_binary(event_type) do
    event_bus().broadcast("fleet.events", build_spawner_event(event_type, payload))
  rescue
    e ->
      Logger.warning(
        "Pod best_effort_broadcast #{event_type} rescue (non-fatal) — #{Exception.message(e)}"
      )

      :ok
  end

  # Broadcast LIFECYCLE load-bearing (`pod.completed`) : l'échec n'est PAS avalé. Retourne `:ok` ou
  # `{:error, {:broadcast_failed, reason}}` (raise OU `{:error, _}` de Bus.broadcast). Loggé ERROR : un
  # `pod.completed` non diffusé = wedge potentiel (le step_run ne finit pas, verrou conservé).
  def required_broadcast(event_type, payload) when is_binary(event_type) do
    case event_bus().broadcast("fleet.events", build_spawner_event(event_type, payload)) do
      :ok ->
        :ok

      {:error, reason} ->
        Logger.error(
          "Pod required_broadcast #{event_type} ÉCHEC (pod=#{Map.get(payload, "pod_id")}) : " <>
            "#{inspect(reason)} — lifecycle NON diffusé (le step_run ne finira pas ; pod pas release/kill, fail-loud)"
        )

        {:error, {:broadcast_failed, reason}}
    end
  rescue
    e ->
      Logger.error(
        "Pod required_broadcast #{event_type} a LEVÉ (pod=#{Map.get(payload, "pod_id")}) : " <>
          "#{Exception.message(e)} — lifecycle NON diffusé (pod pas release/kill, fail-loud)"
      )

      {:error, {:broadcast_failed, e}}
  end

  # Seam du bus (défaut = le vrai `Fleet.EventRouter.Bus`). App-env override (même pattern que les
  # autres seams pod : claude_dir, state_fs_root…) → un test injecte un bus stub qui rend `{:error,_}` / lève
  # sur `pod.completed`, sans toucher le registry global.
  defp event_bus, do: Application.get_env(:fleet_spawner, :event_bus, Bus)

  # Construit l'enveloppe canon %Fleet.Event{source: :spawner} (factorisé — un seul site de construction
  # pour best_effort/required, schema canon strict).
  defp build_spawner_event(event_type, payload) do
    Fleet.Event.new(:spawner, String.to_existing_atom(event_type),
      pod_id: Map.get(payload, "pod_id"),
      payload: payload
    )
  end
end
