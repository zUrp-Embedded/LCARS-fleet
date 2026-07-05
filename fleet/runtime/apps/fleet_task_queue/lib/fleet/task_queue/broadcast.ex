defmodule Fleet.TaskQueue.Broadcast do
  @moduledoc """
  Policy de broadcast du broker — classification load-bearing vs best-effort,
  extraite de `Fleet.TaskQueue.Server` (même move que `Fleet.Spawner.Pod.Events`
  côté spawner). Aucun state GenServer : `bus`, `topic` et l'event arrivent en
  arguments explicites.

  ## Pourquoi DEUX régimes (le cœur du module)

  Un `broadcast/2` unique qui avalerait TOUTE exception en `:ok` — y compris pour
  `work_item.completed`, dont le StepRunConsumer DÉPEND pour finir le step_run — serait
  piégeux : un `work_item.completed` avalé = submit OK rendu au pod, MAIS fin-de-step-run
  jamais déclenchée → verrou forge conservé à vie (wedge silencieux). D'où la SÉPARATION :

    * `best_effort/3` — OBSERVABILITÉ pure (`work_item.enqueued`/`assigned`/`cleared`/
      `failed`-deadline, `state.corrupt`). Un échec est non-bloquant (rescue → log
      warning, rend toujours `:ok`) — personne ne FINIT un step_run dessus.
    * `required/3` — LIFECYCLE load-bearing (`work_item.completed`). L'échec n'est PAS
      avalé : il remonte `{:error, {:broadcast_failed, _}}` → le caller (`submit_result`
      côté Server) le propage au pod (qui ne reçoit PAS un faux « tâche close » et peut
      re-soumettre) au lieu d'un `:ok` qui ment.

  In-process `Phoenix.PubSub.broadcast` ne lève quasi jamais (process local supervisé) ;
  le mode de panne réaliste est `UnregisteredError` (type lifecycle hors registry = bug
  build/config, attrapé en test) ou PubSub pas démarré (boot précoce). Les deux deviennent
  LOUD côté lifecycle.

  ## Pourquoi PAS `Fleet.EventRouter.Bus.safe_emit/4`

  `safe_emit` est le cœur best-effort Ring 0 — mais il émet via `emit/3` →
  `broadcast_main/1`, c'est-à-dire TOUJOURS le vrai Bus sur le topic principal. Le broker
  porte deux knobs par-instance (`:bus` seam + `:topic`, options de `Server.start_link/1`)
  qui servent l'isolation test (bus stub qui échoue/lève sur `work_item.completed`, topic
  dédié par test async) : les deux chemins doivent passer par le bus/topic INJECTÉS, hors
  de portée de `safe_emit`. Le chemin `required/3` est de toute façon VOLONTAIREMENT hors
  de `safe_emit` (cf. son moduledoc : il aplatit tout échec en `:ok`, indistinguable d'un
  succès) — même exclusion que `Fleet.Spawner.Pod.Events.required_broadcast/2`.
  """

  require Logger

  alias Fleet.TaskQueue.WorkItem

  @doc """
  Construit l'enveloppe canon `%Fleet.Event{source: :task_queue}` d'un event de work
  item : `pod_id` et `correlation_id` (= `work_item.id`) viennent du `%WorkItem{}`,
  le `payload` est fourni par l'appelant (jamais le struct brut — `WorkItem` n'a pas
  de `@derive Jason.Encoder`, un struct dans le payload ferait crasher `Jason.encode!`
  chez tout consommateur d'events JSON).
  """
  @spec event(atom(), WorkItem.t(), map()) :: Fleet.Event.t()
  def event(type, %WorkItem{} = work_item, payload) do
    Fleet.Event.new(:task_queue, type,
      pod_id: work_item.pod_id,
      correlation_id: work_item.id,
      payload: payload
    )
  end

  @doc """
  Broadcast OBSERVABILITÉ (best-effort) : émet `event` sur `topic` via `bus.broadcast/2`
  (validation registry `assert_authorized!` incluse quand `bus` est le vrai
  `Fleet.EventRouter.Bus` : les events task ont la même garde que les autres).

  Rend TOUJOURS `:ok` (contrat fire-and-forget) : une exception est rescue + loggée
  warning ; un `{:error, _}` passthrough PubSub est jeté — aucun appelant ne FINIT un
  step_run sur ces events, un échec n'est qu'une perte d'observabilité.
  """
  @spec best_effort(module(), String.t(), Fleet.Event.t()) :: :ok
  def best_effort(bus, topic, %Fleet.Event{} = ev) do
    _ = bus.broadcast(topic, ev)
    :ok
  rescue
    e ->
      Logger.warning(
        "TaskQueue best_effort_broadcast #{ev.type} échec (pod=#{ev.pod_id}) : #{inspect(e)}"
      )

      :ok
  end

  @doc """
  Broadcast LIFECYCLE load-bearing (`work_item.completed`) : l'échec n'est PAS avalé.

  Retourne `:ok` ou `{:error, {:broadcast_failed, reason}}` (raise OU `{:error, _}` de
  `bus.broadcast/2`). Loggé en ERROR (pas warning) : un `work_item.completed` non diffusé
  = wedge potentiel (step_run jamais fini), c'est un incident — le caller (`submit_result`)
  propage l'erreur au pod, pas de `:ok` muet qui laisserait le verrou forge à vie.
  """
  @spec required(module(), String.t(), Fleet.Event.t()) ::
          :ok | {:error, {:broadcast_failed, term()}}
  def required(bus, topic, %Fleet.Event{} = ev) do
    case bus.broadcast(topic, ev) do
      :ok ->
        :ok

      {:error, reason} ->
        Logger.error(
          "TaskQueue required_broadcast #{ev.type} ÉCHEC (pod=#{ev.pod_id}) : #{inspect(reason)} — " <>
            "lifecycle NON diffusé (le step_run ne finira pas ; propagé au caller, pas avalé)"
        )

        {:error, {:broadcast_failed, reason}}
    end
  rescue
    e ->
      Logger.error(
        "TaskQueue required_broadcast #{ev.type} a LEVÉ (pod=#{ev.pod_id}) : #{inspect(e)} — " <>
          "lifecycle NON diffusé (propagé au caller, pas avalé)"
      )

      {:error, {:broadcast_failed, e}}
  end
end
