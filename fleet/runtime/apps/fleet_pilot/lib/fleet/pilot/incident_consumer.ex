defmodule Fleet.Pilot.IncidentConsumer do
  @moduledoc """
  Consumer Bus des events d'**ÉCHEC de pod** (`pod.failed` / `wake.failed`, source `:spawner`) →
  `Fleet.Pilot.IncidentRegistry` (note 1er / escalade récurrent). Subscribe `Fleet.EventRouter.Bus`
  (topic `fleet.events`).

  ## Pourquoi un consumer SÉPARÉ du StepRunConsumer

  Les échecs de pod sont un concern **distinct** de la fin-de-step-run (complétion) : ils ne touchent ni la
  carte, ni la gate, ni l'état de complétion — juste « cet incident, 1er ou récurrent ? » → registre.
  Les deux handlers sont **stateless** (ils ne lisent aucun état du consumer). Les isoler dans leur
  propre singleton : (a) le StepRunConsumer (singleton de complétion) ne porte plus une 2ᵉ responsabilité
  bolted-on, (b) une rafale d'échecs ne partage plus la mailbox du chemin de complétion (blast-radius
  réduit). La POLITIQUE d'escalade (1er=note / récurrent=root-cause, kinds, labels) vit dans
  `IncidentRegistry` ; ce module ne fait que **router l'event vers elle**.

  ## Décision d'escalade (déléguée à `IncidentRegistry`)

    * `pod.failed` — un pod en échec (`transition_failed` : result_timeout/dead-REPL, allocate/launch/
      auth/project). 1er = noté (toléré, possiblement random) ; récurrent = escaladé (pattern → root-cause).
    * `wake.failed` — la boucle ack-driven a épuisé le cap (l'agent n'a JAMAIS acké : ni flag, ni
      send-keys). Récurrence = **SP suspect** (l'inférence vise le SP, pas l'agent : 1×=random, récurrent
      = SP mauvais/dérivé) → `escalate_kind: :sp_suspect` (+ `pane` pour le diag).

  Les littéraux d'atome `:"pod.failed"` / `:"wake.failed"` sont écrits ICI : ils créent aussi l'atome
  dont `best_effort_broadcast` (côté `Fleet.Spawner.Pod`) a besoin pour publier ces events.

  ## Offload (`:runner`)

  `record_or_escalate` touche la forge (lecture/écriture du registre) → OFFLOAD dans une
  `Task.Supervisor` pour ne pas bloquer la mailbox du consumer sur un burst d'échecs. Seam `:runner` :
  défaut `nil` → **SYNC** (l'outcome est loggé en ligne ; tests déterministes sans injection). Prod
  (`application.ex`) injecte `&offload_async/1` → async supervisé (un `record` qui crash est isolé).

  ## Config / seams

    * `:subscribe` — bool défaut `true` (tests : `false` + envoi manuel via `send/2`).
    * `:record_fun` — `fn op, subject, reason, opts -> :recorded | {:escalated|…, _} end`
      (défaut `&Fleet.Pilot.IncidentRegistry.record_or_escalate/4`). Seam test (zéro forge).
    * `:runner` — seam d'offload (cf. ci-dessus). Défaut `nil` → sync.
  """

  use GenServer
  require Logger

  alias Fleet.EventRouter.Bus

  # Superviseur de tasks pour l'offload (prod). Nom partagé entre `application.ex` (qui le démarre AVANT
  # ce consumer) et `offload_async/1`. Propre à ce consumer (pas celui du StepRunConsumer) : séparation nette.
  @task_supervisor Fleet.Pilot.IncidentConsumer.TaskSupervisor

  defstruct record_fun: nil, runner: nil

  @spec start_link(keyword()) :: GenServer.on_start()
  def start_link(opts \\ []) do
    {gs_opts, init_opts} = Keyword.split(opts, [:name])
    name = Keyword.get(gs_opts, :name, __MODULE__)
    GenServer.start_link(__MODULE__, init_opts, name: name)
  end

  @doc false
  def task_supervisor, do: @task_supervisor

  # Runner ASYNC (prod, injecté en `:runner`) — offload le record/escalade dans la `Task.Supervisor`
  # propre au consumer : le forge du registre ne bloque pas la mailbox. Rend `{:ok, :offloaded}` ; échec
  # de spawn → fail-loud loggé (l'incident n'est alors PAS gravé — visible, pas silencieux).
  @doc false
  def offload_async(fun) do
    case Task.Supervisor.start_child(@task_supervisor, fun) do
      {:ok, _pid} ->
        {:ok, :offloaded}

      {:error, reason} ->
        Logger.error(
          "IncidentConsumer: offload Task échoué (#{inspect(reason)}) — incident NON gravé"
        )

        {:error, {:offload_failed, reason}}
    end
  end

  @impl GenServer
  def init(opts) do
    if Keyword.get(opts, :subscribe, true), do: Bus.subscribe()

    state = %__MODULE__{
      record_fun:
        Keyword.get(opts, :record_fun, &Fleet.Pilot.IncidentRegistry.record_or_escalate/4),
      runner: Keyword.get(opts, :runner)
    }

    {:ok, state}
  end

  @impl GenServer
  def handle_info(
        %Fleet.Event{source: :spawner, type: :"pod.failed", payload: %{"pod_id" => pod_id} = p},
        state
      )
      when is_binary(pod_id) do
    record(state, "pod", pod_id, p["reason"], [])
    {:noreply, state}
  end

  def handle_info(
        %Fleet.Event{source: :spawner, type: :"wake.failed", payload: %{"pod_id" => pod_id} = p},
        state
      )
      when is_binary(pod_id) do
    # Récurrence wake = SP suspect (cf. moduledoc) → escalade typée + `pane` pour le diag.
    record(state, "wake", pod_id, p["reason"], escalate_kind: :sp_suspect, pane: p["pane"])
    {:noreply, state}
  end

  # Tout autre message (events non-échec qu'on voit aussi via le Bus, ou non-Fleet.Event) → no-op.
  def handle_info(_other, state), do: {:noreply, state}

  # Route l'incident vers le registre, offloadé via `:runner` (défaut sync). Le 4-uplet
  # `(op, subject, reason, opts)` est le contrat de `IncidentRegistry.record_or_escalate/4` (`op="pod"` →
  # `opts=[]` ; `op="wake"` → `escalate_kind:/pane:`). L'outcome est loggé (jamais avalé) : un incident
  # non gravé / une escalade ratée doit être VISIBLE (forge down ? registre indispo ?).
  defp record(state, op, pod_id, reason, reg_opts) do
    exec = fn ->
      case state.record_fun.(op, pod_id, reason, reg_opts) do
        :recorded ->
          Logger.info(
            "IncidentConsumer #{op}.failed #{pod_id} → incident gravé (#{inspect(reason)})"
          )

        {:escalated, _} ->
          Logger.warning(
            "IncidentConsumer #{op}.failed #{pod_id} RÉCURRENT → escaladé (#{inspect(reason)})"
          )

        {:escalation_failed, e} ->
          Logger.error(
            "IncidentConsumer #{op}.failed #{pod_id} RÉCURRENT mais escalade ÉCHOUÉE — AUCUN issue " <>
              "sysadmin créé (forge down ?) : #{inspect(e)}"
          )

        {:record_failed, e} ->
          Logger.error(
            "IncidentConsumer #{op}.failed #{pod_id} : incident NON gravé (registre indisponible) : #{inspect(e)}"
          )

        other ->
          Logger.warning(
            "IncidentConsumer #{op}.failed #{pod_id} → outcome inattendu #{inspect(other)}"
          )
      end
    end

    (state.runner || (&run_sync/1)).(exec)
  end

  defp run_sync(fun), do: fun.()
end
