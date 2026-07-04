defmodule Fleet.Spawner.Pod.Events do
  @moduledoc """
  Broadcasts BUS du cycle de vie pod — cluster extrait de `Fleet.Spawner.Pod`.

  Un seul rôle : diffuser sur le bus `fleet.events` les events de cycle de vie d'un pod, sous
  l'enveloppe canon stricte `%Fleet.Event{source: :spawner}`. La SÉPARATION load-bearing vs
  best-effort (cf. le commentaire de section ci-dessous) est le cœur du module : un `pod.completed`
  avalé en silence wedgerait le step_run (verrou forge à vie), un `pod.failed`/`wake.failed` avalé n'est
  qu'une perte d'observabilité.

  Aucun state, aucun Port, aucun timer : le `Pod` passe `event_type` (binaire) + `payload` (map) en
  arguments ; le module construit l'enveloppe et broadcaste.

  ## Contrat (appelé par `Pod`)

  - `best_effort_broadcast/2` (PUBLIC) — OBSERVABILITÉ/escalade (`pod.failed`, `wake.failed`).
    Un échec est non-bloquant ; rend toujours `:ok`. Émet via le cœur protégé
    `Fleet.EventRouter.Bus.safe_emit/4` (politique best-effort UNIFIÉE Ring 0 : échec loggé,
    jamais un crash du pod).
  - `required_broadcast/2` (PUBLIC) — LIFECYCLE load-bearing (`pod.completed`). L'échec n'est PAS
    avalé : rend `:ok` | `{:error, {:broadcast_failed, _}}`. L'état `:extracting` (`do_extract_proceed`)
    NE release/kill PAS le pod sur une complétion orpheline. VOLONTAIREMENT hors de `Bus.safe_emit`
    (cf. son commentaire — safe_emit aplatit tout échec en `:ok`, indistinguable d'un succès).

  Le SEAM app-env (`:fleet_spawner, :event_bus`, défaut `Fleet.EventRouter.Bus`) ne porte QUE le
  chemin load-bearing `required_broadcast/2` : il sert à injecter un échec DÉTERMINISTE sur
  `pod.completed` en test (stub qui lève / rend `{:error,_}`) sans toucher le registry global —
  injecter un échec sur un broadcast best-effort n'a pas d'observable (l'échec y est avalé par
  contrat). `event_bus/0` et `build_spawner_event/2` sont internes (appelés UNIQUEMENT par
  `required_broadcast/2`).
  """

  require Logger

  alias Fleet.EventRouter.Bus

  # Classification load-bearing vs best-effort du broadcast (cf. task_queue/server.ex, même move).
  # Un `safe_broadcast` unique qui avalerait TOUTE exception en `:ok` engloutirait aussi `pod.completed`
  # dont le StepRunConsumer DÉPEND pour finir le step_run : un `pod.completed` avalé = le pod « réussit » (release/
  # kill pour un one-shot) MAIS la fin-de-step-run ne se déclenche jamais → verrou forge conservé à vie (wedge
  # silencieux). D'où la SÉPARATION :
  #   - `best_effort_broadcast/2` : OBSERVABILITÉ/escalade (`pod.failed`, `wake.failed`). Un échec est
  #     non-bloquant (loggé par `Bus.safe_emit/4`, le cœur best-effort partagé) — un consumer fleet_pilot
  #     les enregistre en best-effort, personne ne FINIT un step_run dessus.
  #   - `required_broadcast/2` : LIFECYCLE load-bearing (`pod.completed`). L'échec n'est PAS avalé : il
  #     remonte `{:error, {:broadcast_failed, _}}` → l'état `:extracting` NE release/kill PAS le pod sur une
  #     complétion orpheline ; il reste vivant (re-wake re-fire l'extract), fail-loud. Les deux passent
  #     par l'enveloppe canon stricte `%Fleet.Event{source: :spawner}`.

  # OBSERVABILITÉ/escalade : émission via le cœur protégé `Bus.safe_emit/4` (le rescue local dupliqué
  # est retiré — la politique best-effort a UNE autorité, Ring 0). Un crash event_router (event malformé,
  # nom de type inconnu) ne doit JAMAIS faire crash le process pod (gen_statem) : safe_emit logge et
  # neutralise. Le `event_type` BINAIRE est passé tel quel — la conversion anti atom-leak
  # (`to_existing_atom`) vit SOUS le rescue de safe_emit. `:on_unregistered` défaut (`:log`) : la perte
  # d'un event d'observabilité reste visible en log. Rend toujours `:ok` (contrat fire-and-forget — le
  # `{:error,_}` passthrough PubSub est jeté : personne ne FINIT un step_run sur ces events).
  def best_effort_broadcast(event_type, payload) when is_binary(event_type) do
    _ =
      Bus.safe_emit(
        :spawner,
        event_type,
        [pod_id: Map.get(payload, "pod_id"), payload: payload],
        context: "Pod best_effort_broadcast #{event_type} (non-fatal)"
      )

    :ok
  end

  # Broadcast LIFECYCLE load-bearing (`pod.completed`) : l'échec n'est PAS avalé. VOLONTAIREMENT hors
  # du cœur `Bus.safe_emit/4` : safe_emit aplatit tout échec en `:ok` loggé (contrat best-effort
  # « ne jamais crasher l'émetteur ») — indistinguable d'un succès pour l'appelant, alors qu'ici
  # l'état `:extracting` DOIT distinguer pour retenir le pod. Retourne `:ok` ou
  # `{:error, {:broadcast_failed, reason}}` (raise OU `{:error, _}` de Bus.broadcast). Loggé ERROR : un
  # `pod.completed` non diffusé = wedge potentiel (le step_run ne finit pas, verrou conservé).
  def required_broadcast(event_type, payload) when is_binary(event_type) do
    case event_bus().broadcast(Bus.main_topic(), build_spawner_event(event_type, payload)) do
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
  # sur `pod.completed`, sans toucher le registry global. Porte UNIQUEMENT le chemin load-bearing
  # `required_broadcast/2` : le best-effort passe par `Bus.safe_emit/4` en direct (un stub d'échec n'y a
  # pas d'observable, l'échec est avalé par contrat).
  defp event_bus, do: Application.get_env(:fleet_spawner, :event_bus, Bus)

  # Construit l'enveloppe canon %Fleet.Event{source: :spawner} pour le chemin load-bearing
  # (`required_broadcast/2` — le best-effort construit la sienne via `Bus.safe_emit/4`/`Fleet.Event.new`).
  defp build_spawner_event(event_type, payload) do
    Fleet.Event.new(:spawner, String.to_existing_atom(event_type),
      pod_id: Map.get(payload, "pod_id"),
      payload: payload
    )
  end
end
