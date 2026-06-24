defmodule Fleet.TaskQueue.Server do
  @moduledoc """
  GenServer porteur de la queue EN RAM (un seul écrivain). Persistence atomique `state.json`
  versionné `v: 1` (**opt-in**) ; events `%Fleet.Event{}` sur le bus.

  AXIOME source-unique : la **forge** est la vérité du travail (issues/routes/PR) ; le
  broker n'en est que le FRONT en RAM. Aucun champ du `Task` n'est broker-only-durable (tout est
  re-dérivable au re-dispatch forge) → **en prod le broker tourne ÉPHÉMÈRE** (`persist: false`, cf.
  `Application`) : pas de `state.json`, donc pas de tâches stale persistées qui survivent aux reboots
  (cause des 1124 "en cours" accumulées). Au restart, la queue se re-dérive des polls forge (rail de
  réconciliation canonique). La persistance ci-dessous reste un mécanisme **opt-in** (testé) pour un
  futur état broker-only-durable — il n'en existe AUCUN à ce jour.

  Broadcast `%Fleet.Event{source: :task_queue, ...}` sur `Phoenix.PubSub`
  topic `fleet.events`, `correlation_id = task.id`. Recovery cross-restart via
  `state.json` (fail-loud `:state_corrupt` sur schema mismatch au READ, fallback
  non-bloquant). Côté WRITE : `persist/1` est best-effort — un échec d'écriture est
  loggé **error** (durabilité du point de recovery rompue), **non-fatal** (on
  ne crashe pas le broker sur un blip disque) ; la réconciliation passe par le rail
  forge-driven (re-dispatch depuis l'état forge), pas par cette persistance locale.

  ## Bottleneck assumé
  GenServer = sérialisation voulue des transitions d'état (idempotence + écriture
  atomique `state.json`). L'optimisation ETS-reads / pool est **différée** (critère
  de déclenchement : latence get_task/submit_result > 100ms). MVP : tout passe par `call`.

  ## Options
  `:name` (`nil` → anonyme, isolation tests), `:state_path`, `:persist`,
  `:topic` (défaut `"fleet.events"`), `:retention_terminal_max` (nombre max
  de tâches TERMINALES conservées, défaut 500 ; borne `tasks` en mémoire ET la taille
  de `state.json` réécrit à chaque mutation. Les tâches ACTIVES ne comptent pas),
  `:bus` (seam, défaut `Fleet.EventRouter.Bus` ; module `broadcast/2` — injecté en test pour
  exercer le chemin lifecycle non-avalé `task_completed`).

  ## Broadcast — load-bearing vs best-effort
  `task_completed` est LIFECYCLE load-bearing (le HopConsumer en dépend pour finir le hop) →
  `required_broadcast` : un échec n'est PAS avalé, il propage `{:error, {:broadcast_failed, _}}` au caller
  de `submit_result` (plus de `:ok` muet qui laisse le verrou forge à vie). Les autres events
  (enqueued/assigned/cleared/failed-deadline/state_corrupt) = `best_effort_broadcast` (observabilité, rescue).
  """

  use GenServer
  require Logger

  alias Fleet.TaskQueue.Task

  @default_topic "fleet.events"
  @active_states [:pending, :assigned, :in_progress]
  # Borne de rétention des tâches terminales (:completed/:failed/:cleared). Sans elle,
  # `tasks` croît sans borne et `persist/1` réécrit un `state.json` toujours plus gros à CHAQUE
  # mutation. On garde les N plus récentes ; les actives ne comptent pas (cf. prune_terminal/2).
  @default_retention_terminal 500

  # ============================================================
  # Lifecycle
  # ============================================================

  @spec start_link(keyword()) :: GenServer.on_start()
  def start_link(opts \\ []) do
    # `name: nil` → serveur anonyme (isolation tests). Absent → nom canonique.
    case Keyword.fetch(opts, :name) do
      {:ok, nil} -> GenServer.start_link(__MODULE__, opts)
      {:ok, name} -> GenServer.start_link(__MODULE__, opts, name: name)
      :error -> GenServer.start_link(__MODULE__, opts, name: __MODULE__)
    end
  end

  @impl GenServer
  def init(opts) do
    persist? = Keyword.get(opts, :persist, true)
    state_path = Keyword.get(opts, :state_path, default_path())

    base = %{
      tasks: %{},
      # Last-poll par pod (l'agent a appelé get_for_pod = ACK in-band, MÊME sans mandat → signal
      # bootstrap « l'agent est up + a tendu la main »). In-mem/éphémère : la récence vit en runtime, pas
      # persisté (un restart re-établit via les polls suivants).
      polls: %{},
      state_path: state_path,
      persist: persist?,
      topic: Keyword.get(opts, :topic, @default_topic),
      # Seam du bus (défaut = le vrai `Fleet.EventRouter.Bus`). Module avec `broadcast/2`. Permet
      # de tester le chemin lifecycle non-avalé (un bus stub qui rend `{:error,_}` / lève sur task_completed)
      # sans toucher le registry global `:persistent_term`.
      bus: Keyword.get(opts, :bus, Fleet.EventRouter.Bus),
      retention_terminal_max:
        Keyword.get(opts, :retention_terminal_max) ||
          Application.get_env(
            :fleet_task_queue,
            :retention_terminal_max,
            @default_retention_terminal
          )
    }

    case load_state(state_path, persist?) do
      :empty -> {:ok, base}
      {:ok, tasks} -> {:ok, %{base | tasks: tasks}, {:continue, :reschedule_deadlines}}
      {:corrupt, found} -> {:ok, base, {:continue, {:corrupt, found}}}
    end
  end

  @impl GenServer
  def handle_continue(:reschedule_deadlines, state) do
    # Recovery : les deadlines ne sont armées qu'à l'enqueue. Après restart, on ré-arme
    # les tâches ACTIVES ; une deadline dépassée pendant le downtime → check immédiat (→ :task_failed via
    # handle_info), pas active-pour-toujours.
    for {_id, %Task{state: s} = t} <- state.tasks, s in @active_states do
      maybe_schedule_deadline(t)
    end

    {:noreply, state}
  end

  @impl GenServer
  def handle_continue({:corrupt, found}, state) do
    # Fallback non-bloquant : state vide + event de boot anomaly post-init.
    best_effort_broadcast(state, %Fleet.Event{
      source: :task_queue,
      type: :state_corrupt,
      timestamp: now(),
      pod_id: nil,
      correlation_id: nil,
      payload: %{expected: 1, found: found}
    })

    {:noreply, state}
  end

  # ============================================================
  # Command Port
  # ============================================================

  @impl GenServer
  def handle_call({:enqueue, pod_id, attrs}, _from, state) do
    task = %Task{
      id: UUID.uuid4(),
      pod_id: pod_id,
      ticket_id: attrs[:ticket_id] || attrs["ticket_id"],
      role: attrs[:role] || attrs["role"],
      brief: attrs[:brief] || attrs["brief"],
      deadline: attrs[:deadline] || attrs["deadline"],
      enqueued_at: now(),
      state: :pending,
      metadata: attrs[:metadata] || attrs["metadata"] || %{}
    }

    # AXIOME « 1 mandat ACTIF/pod » tenu À L'ÉCRITURE. Un mandat FRAIS SUPERSÈDE TOUTE active du pod :
    # le `:pending` jamais pullé (drop) ET l'`:assigned`/`:in_progress` en cours (→ `:cleared`). Un re-mandate
    # remplace l'ancien : le pod prendra le nouveau (seul actif restant) au prochain `get_for_pod`. L'unicité
    # DOIT être tenue ici, pas seulement à la lecture : garder une `:assigned` stale à côté du nouveau pending
    # la laisserait ACTIVE et invisible aux gardes (`find_active` = `max_by(enqueued_at)` sert la + récente mais
    # MASQUE la fuite → état « 2 actives/pod » non borné, invariant violé). Unicité tenue À L'ÉCRITURE →
    # `find_active`/`max_by` devient moot (au plus 1 active/pod par construction).
    {state, superseded} = supersede_active(state, pod_id)

    if superseded > 0,
      do: Logger.debug("TaskQueue: enqueue pod=#{pod_id} supersède #{superseded} active(s) stale")

    new_state = state |> put_task(task) |> persist()

    # payload = `%{task_id}` (cohérent avec tous les autres task_* events), PAS le `%Task{}` brut —
    # Task n'a pas de @derive Jason.Encoder, donc un `%{task: task}` ferait crasher `Jason.encode!`
    # chez tout consommateur d'events JSON (Fleet.API.WS à chaque enqueue). Aucun consommateur n'a
    # besoin du struct (deck = count, audit = pod_id/correlation_id).
    best_effort_broadcast(new_state, event(:task_enqueued, task, %{task_id: task.id}))
    maybe_schedule_deadline(task)
    {:reply, {:ok, task}, new_state}
  end

  def handle_call({:get_for_pod, pod_id}, _from, state) do
    # last-poll AVANT le case : l'agent a tendu la main = ACK in-band, qu'il reçoive un mandat ou non
    # (le cas `:no_task` est le signal bootstrap « l'agent est up + armé »).
    state = record_poll(state, pod_id)

    case find_active(state.tasks, pod_id) do
      nil ->
        {:reply, {:error, :no_task}, state}

      %Task{state: :pending} = task ->
        assigned = %{task | state: :assigned, assigned_at: now()}
        new_state = state |> put_task(assigned) |> persist()
        best_effort_broadcast(new_state, event(:task_assigned, assigned, %{task_id: assigned.id}))
        {:reply, {:ok, assigned}, new_state}

      %Task{} = task ->
        # déjà :assigned/:in_progress → idempotent (pas de re-broadcast, pas de double dispatch)
        {:reply, {:ok, task}, state}
    end
  end

  def handle_call({:submit_result, pod_id, result}, _from, state) do
    case find_active(state.tasks, pod_id) do
      nil ->
        if has_completed?(state.tasks, pod_id),
          do: {:reply, {:error, :double_submit_ignored}, state},
          else: {:reply, {:error, :no_active_task}, state}

      %Task{} = task ->
        case result["task_id"] || result[:task_id] do
          tid when tid != nil and tid != task.id ->
            # correlation_id du livrable ≠ mandat actif du pod → rejet, aucune mutation. C'est le 2e verrou
            # anti-impersonation (le 1er = la capability côté fleet_mcp) : même un pod prouvé ne peut clôturer
            # qu'EXACTEMENT son mandat actif, jamais « la dernière active » d'un autre. fleet_mcp rend le
            # task_id OBLIGATOIRE côté pod → ce corrélateur est toujours présent et vérifié.
            {:reply, {:error, :task_id_mismatch}, state}

          _ok ->
            # `task_id` retiré du livrable STOCKÉ : c'est un corrélateur de transport (preuve « je clôs CE
            # mandat »), pas une donnée métier du résultat. Le mandat est déjà identifié par `task.id` ; le
            # garder dans `result` ne ferait que dupliquer/polluer le livrable broadcasté.
            clean_result = result |> Map.delete("task_id") |> Map.delete(:task_id)
            completed = %{task | state: :completed, completed_at: now(), result: clean_result}
            new_state = state |> put_task(completed) |> persist()

            # `task_completed` est LIFECYCLE load-bearing : le HopConsumer en DÉPEND pour finir le
            # hop (lever le verrou forge). Le broadcast passe par `required_broadcast` : son échec n'est PLUS
            # avalé en `:ok`. Si la diffusion échoue, on NE rend PAS `{:ok, completed}` (qui ferait croire au
            # pod « tâche close » alors que le hop ne finira jamais → verrou conservé à vie) : on propage
            # `{:error, {:broadcast_failed, _}}`. La tâche RESTE `:completed`+persistée (le livrable n'est
            # pas perdu ; le rail forge-driven re-dérive au besoin), mais le pod voit un échec honnête.
            # role/ticket_id additifs : le DeliveryPublisher stampe l'identité de l'agent d'origine
            # sur le commit forge. Les consumers existants ignorent les clés extra.
            # `metadata` additif : le verdict task_completed porte le metadata de la TÂCHE (qui
            # survit dans le broker au crash du HopConsumer seul). Pour une éval gatekeeper il porte le
            # contexte de reprise (`gate_eval`/`payload`/`pipeline`/…) → le HopConsumer redémarré (gate_evals
            # RAM vide) RECONSTRUIT l'eval_ctx du metadata au lieu d'un `{:noreply}` silencieux (wedge à vie).
            ev =
              event(:task_completed, completed, %{
                task_id: completed.id,
                role: completed.role,
                ticket_id: completed.ticket_id,
                result: clean_result,
                metadata: completed.metadata
              })

            case required_broadcast(new_state, ev) do
              :ok ->
                {:reply, {:ok, completed}, new_state}

              {:error, _} = err ->
                {:reply, err, new_state}
            end
        end
    end
  end

  # Purge TOUTES les actives du pod (pas seulement la + récente via `find_active`). Avec l'invariant
  # « 1 active/pod » tenu à l'enqueue (`supersede_active`), il n'y en a normalement qu'une ; mais un clear doit
  # rester TOTAL (pas de stale `:assigned` résiduelle qui échapperait au clear et fuirait — symétrique de
  # l'enqueue). Un broadcast `:task_cleared` par tâche clearée ; aucune active → no-op idempotent.
  def handle_call({:clear_for_pod, pod_id}, _from, state) do
    active =
      state.tasks
      |> Map.values()
      |> Enum.filter(&(&1.pod_id == pod_id and &1.state in @active_states))

    case active do
      [] ->
        {:reply, :ok, state}

      tasks ->
        cleared = Enum.map(tasks, &%{&1 | state: :cleared})
        new_state = Enum.reduce(cleared, state, &put_task(&2, &1)) |> persist()

        for t <- cleared,
            do: best_effort_broadcast(new_state, event(:task_cleared, t, %{task_id: t.id}))

        {:reply, :ok, new_state}
    end
  end

  # ============================================================
  # Query Port (aucun side-effect, aucun broadcast)
  # ============================================================

  def handle_call(:list_pending, _from, state) do
    pending = state.tasks |> Map.values() |> Enum.filter(&(&1.state == :pending))
    {:reply, pending, state}
  end

  def handle_call({:pod_status, pod_id}, _from, state) do
    status =
      case latest_for_pod(state.tasks, pod_id) do
        nil -> nil
        %Task{state: s} -> s
      end

    {:reply, {:ok, status}, state}
  end

  # Last-poll du pod (`DateTime | nil`) = l'ACK in-band du bootstrap (« l'agent a tendu la main »,
  # même sans mandat). Le consommateur (boucle wake ack-driven) compare avec son instant de trigger.
  def handle_call({:last_poll, pod_id}, _from, state) do
    {:reply, Map.get(state.polls, pod_id), state}
  end

  # ============================================================
  # Deadline (transition :failed)
  # ============================================================

  @impl GenServer
  def handle_info({:check_deadline, task_id}, state) do
    case Map.get(state.tasks, task_id) do
      %Task{state: s} = task when s in @active_states ->
        failed = %{task | state: :failed}
        new_state = state |> put_task(failed) |> persist()

        # `:task_failed` (deadline) = watchdog de l'IRRÉDUCTIBLE, pas une complétion
        # caller-facing : best-effort (un handle_info n'a personne à qui propager). La garde reste, honnête.
        best_effort_broadcast(
          new_state,
          event(:task_failed, failed, %{task_id: failed.id, reason: :deadline_expired})
        )

        {:noreply, new_state}

      _ ->
        {:noreply, state}
    end
  end

  def handle_info(_msg, state), do: {:noreply, state}

  # ============================================================
  # Helpers — sélection
  # ============================================================

  defp find_active(tasks, pod_id) do
    tasks
    |> Map.values()
    |> Enum.filter(&(&1.pod_id == pod_id and &1.state in @active_states))
    |> Enum.max_by(& &1.enqueued_at, DateTime, fn -> nil end)
  end

  defp latest_for_pod(tasks, pod_id) do
    tasks
    |> Map.values()
    |> Enum.filter(&(&1.pod_id == pod_id))
    |> Enum.max_by(& &1.enqueued_at, DateTime, fn -> nil end)
  end

  # Supersède TOUTE active du pod (un mandat frais à l'enqueue remplace l'ancien). Le `:pending`
  # jamais pullé est DROPPÉ (jamais servi → rien à tracer) ; l'`:assigned`/`:in_progress` en cours est
  # transitionné `:cleared` (le pod l'abandonne : `submit_result` du vieux mandat tombera sur `find_active`
  # = nil → `:no_active_task`/`:double_submit_ignored`, jamais une mutation du nouveau). Garde tout le reste
  # (autres pods, terminaux du pod). Borne la queue à 1 active/pod À L'ÉCRITURE. Retourne
  # `{state, n_superseded}`.
  defp supersede_active(state, pod_id) do
    tasks =
      Map.new(state.tasks, fn {id, t} ->
        if t.pod_id == pod_id and t.state in @active_states do
          {id, %{t | state: :cleared}}
        else
          {id, t}
        end
      end)

    superseded =
      Enum.count(state.tasks, fn {_id, t} ->
        t.pod_id == pod_id and t.state in @active_states
      end)

    {%{state | tasks: tasks}, superseded}
  end

  defp has_completed?(tasks, pod_id) do
    Enum.any?(Map.values(tasks), &(&1.pod_id == pod_id and &1.state == :completed))
  end

  defp record_poll(state, pod_id) when is_binary(pod_id),
    do: %{state | polls: Map.put(state.polls, pod_id, now())}

  defp put_task(state, %Task{} = task) do
    tasks = Map.put(state.tasks, task.id, task)
    %{state | tasks: prune_terminal(tasks, state.retention_terminal_max)}
  end

  # Garde au plus `max` tâches TERMINALES (les plus récentes), élague les plus vieilles.
  # No-op tant qu'on est sous le cap. Les tâches ACTIVES ne comptent pas et ne sont JAMAIS coupées
  # (mandats en cours). L'ordre par récence (≠ ordre d'enqueue) protège la détection double-submit :
  # une tâche juste complétée est la plus récente → jamais élaguée en premier (has_completed?/1).
  defp prune_terminal(tasks, max) do
    terminal = for {_id, t} <- tasks, t.state not in @active_states, do: t

    if length(terminal) <= max do
      tasks
    else
      drop_ids =
        terminal
        |> Enum.sort_by(&recency/1, {:desc, DateTime})
        |> Enum.drop(max)
        |> MapSet.new(& &1.id)

      Map.reject(tasks, fn {id, _t} -> MapSet.member?(drop_ids, id) end)
    end
  end

  # Récence pour l'ordre de rétention : completed_at si complétée, sinon assigned_at, sinon
  # enqueued_at (toujours présent — @enforce_keys). Toujours un %DateTime{}, jamais nil.
  defp recency(%Task{} = t), do: t.completed_at || t.assigned_at || t.enqueued_at

  defp maybe_schedule_deadline(%Task{deadline: %DateTime{} = dl, id: id}) do
    ms = DateTime.diff(dl, DateTime.utc_now(), :millisecond)

    # ms>0 : arme à l'échéance. ms<=0 (deadline DÉJÀ dépassée, ex. au recovery) : check immédiat → fail
    # via handle_info, au lieu de l'ignorer silencieusement (= tâche active pour toujours).
    if ms > 0,
      do: Process.send_after(self(), {:check_deadline, id}, ms),
      else: send(self(), {:check_deadline, id})

    :ok
  end

  defp maybe_schedule_deadline(_), do: :ok

  # ============================================================
  # Helpers — events
  # ============================================================

  defp event(type, %Task{} = task, payload) do
    %Fleet.Event{
      source: :task_queue,
      type: type,
      timestamp: now(),
      pod_id: task.pod_id,
      correlation_id: task.id,
      payload: payload
    }
  end

  # Classification load-bearing vs best-effort. Un `broadcast/2` unique qui avalerait TOUTE exception en
  # `:ok` — y compris pour `task_completed`, dont le HopConsumer DÉPEND pour finir le hop — serait piégeux :
  # un `task_completed` avalé = submit OK rendu au pod, MAIS fin-de-hop jamais déclenchée → verrou forge
  # conservé à vie (wedge silencieux). On SÉPARE donc les deux régimes :
  #
  #   - `best_effort_broadcast/2` : OBSERVABILITÉ pure (task_enqueued/assigned/cleared/failed-deadline,
  #     state_corrupt). Un échec est non-bloquant (rescue → log) — personne ne FINIT un hop dessus.
  #   - `required_broadcast/2` : LIFECYCLE load-bearing (task_completed). L'échec n'est PAS avalé : il
  #     remonte `{:error, {:broadcast_failed, _}}` → le caller (`submit_result`) le propage au pod (qui ne
  #     reçoit PAS un faux "tâche close" et peut re-soumettre) au lieu d'un `:ok` qui ment.
  #
  # In-process `Phoenix.PubSub.broadcast` ne lève quasi jamais (process local supervisé) ; le mode de panne
  # réaliste est `UnregisteredError` (type lifecycle hors registry = bug build/config, attrapé en test) ou
  # PubSub pas démarré (boot précoce). Les deux deviennent LOUD côté lifecycle. (Durcissement ultérieur
  # possible : un constructeur `%Fleet.Event{}` prouvé-enregistré au build tuerait la classe UnregisteredError
  # à la source — refactor cross-app event_router + producteurs, non fait à ce jour.)
  defp best_effort_broadcast(state, %Fleet.Event{} = ev) do
    # Passe par Bus.broadcast (validation registry `assert_authorized!`) au lieu
    # de Phoenix.PubSub direct : les events task ont la même garde que les autres.
    state.bus.broadcast(state.topic, ev)
  rescue
    e ->
      require Logger

      Logger.warning(
        "TaskQueue best_effort_broadcast #{ev.type} échec (pod=#{ev.pod_id}) : #{inspect(e)}"
      )

      :ok
  end

  # Broadcast LIFECYCLE load-bearing : l'échec n'est PAS avalé. Retourne `:ok` ou
  # `{:error, {:broadcast_failed, reason}}` (raise OU `{:error, _}` de Bus.broadcast). Loggé en ERROR (pas
  # warning) : un `task_completed` non diffusé = wedge potentiel (hop jamais fini), c'est un incident.
  defp required_broadcast(state, %Fleet.Event{} = ev) do
    case state.bus.broadcast(state.topic, ev) do
      :ok ->
        :ok

      {:error, reason} ->
        require Logger

        Logger.error(
          "TaskQueue required_broadcast #{ev.type} ÉCHEC (pod=#{ev.pod_id}) : #{inspect(reason)} — " <>
            "lifecycle NON diffusé (le hop ne finira pas ; propagé au caller, pas avalé)"
        )

        {:error, {:broadcast_failed, reason}}
    end
  rescue
    e ->
      require Logger

      Logger.error(
        "TaskQueue required_broadcast #{ev.type} a LEVÉ (pod=#{ev.pod_id}) : #{inspect(e)} — " <>
          "lifecycle NON diffusé (propagé au caller, pas avalé)"
      )

      {:error, {:broadcast_failed, e}}
  end

  defp now, do: DateTime.utc_now()

  # ============================================================
  # Helpers — persistence (atomic write tmp + rename)
  # ============================================================

  defp default_path do
    Application.get_env(:fleet_task_queue, :state_path, default_state_path())
  end

  # Le fleet tourne sous l'humain → défaut home-relatif `~/.lcars/task-queue`, comme le pod state_fs_root
  # (`Fleet.Spawner.Pod.default_state_fs_root`) : un `/var/lib/lcars` en dur ne serait pas ownable hors du
  # compte `lcars`. Fallback `/var/lib/lcars` si le home est irrésoluble (jamais en pratique).
  defp default_state_path do
    Path.join(System.user_home() || "/var/lib/lcars", ".lcars/task-queue/state.json")
  end

  defp persist(%{persist: false} = state), do: state
  defp persist(%{state_path: nil} = state), do: state

  defp persist(%{state_path: path, tasks: tasks} = state) do
    data = %{"v" => 1, "tasks" => Map.new(tasks, fn {id, t} -> {id, Task.to_map(t)} end)}

    try do
      File.mkdir_p!(Path.dirname(path))
      tmp = path <> ".tmp"
      File.write!(tmp, Jason.encode!(data))
      File.rename!(tmp, path)
    rescue
      e ->
        # Un échec d'écriture rompt la durabilité du point de recovery cross-restart. C'est
        # une ERREUR, pas un warning : la queue RAM avance mais state.json diverge → un restart
        # relirait un état stale. On NE crashe PAS le broker (un blip disque transitoire ne doit pas
        # tuer les mandats en vol) ; la réconciliation passe par le rail forge-driven (re-dispatch
        # depuis l'état forge). Le breach devient LOUD (error-level → monitoring),
        # plus de dégradé silencieux.
        Logger.error(
          "fleet_task_queue persist ÉCHEC — durabilité du point de recovery rompue (non-fatal, " <>
            "réconciliation forge-driven ; path=#{path}): #{inspect(e)}"
        )
    end

    state
  end

  defp load_state(_path, false), do: :empty
  defp load_state(nil, _persist), do: :empty

  defp load_state(path, true) do
    case File.read(path) do
      {:ok, content} -> decode_state(content)
      {:error, :enoent} -> :empty
      {:error, reason} -> {:corrupt, reason}
    end
  end

  defp decode_state(content) do
    case Jason.decode(content) do
      {:ok, %{"v" => 1, "tasks" => tasks_map}} when is_map(tasks_map) ->
        decode_tasks(tasks_map)

      {:ok, %{"v" => v}} ->
        {:corrupt, v}

      _ ->
        {:corrupt, :unparseable}
    end
  end

  # fail-loud : une tâche non-désérialisable (state corrompu / champ requis absent) → `{:corrupt, ...}`,
  # PAS un drop silencieux. `reduce_while` HALTE sur la 1re tâche corrompue plutôt que de la FILTRER (état
  # tronqué en silence) ; `Task.from_map` rend `{:error, _}` au lieu de RAISER (le fallback `:corrupt` tient).
  defp decode_tasks(tasks_map) do
    Enum.reduce_while(tasks_map, {:ok, %{}}, fn {id, tm}, {:ok, acc} ->
      case Task.from_map(tm) do
        {:ok, t} -> {:cont, {:ok, Map.put(acc, id, t)}}
        {:error, reason} -> {:halt, {:corrupt, {:task, id, reason}}}
      end
    end)
  end

  # UUID v4 (`correlation_id = task.id`) via la dép `:uuid` (déjà shippée dans l'umbrella) —
  # source unique, pas de génération hand-rolled `:crypto` en parallèle.
end
