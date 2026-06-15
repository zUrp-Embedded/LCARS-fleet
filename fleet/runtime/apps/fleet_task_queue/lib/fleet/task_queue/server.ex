defmodule Fleet.TaskQueue.Server do
  @moduledoc """
  GenServer source unique de vérité de la queue. Cf. DN `orchestration/task-queue` §C-3
  (un seul écrivain), §D (persistence atomique `state.json` versionné `v: 1`), §E (events).

  Broadcast `%Fleet.Event{source: :task_queue, ...}` sur `Phoenix.PubSub`
  topic `fleet.events`, `correlation_id = task.id`. Recovery cross-restart via
  `state.json` (fail-loud `:state_corrupt` sur schema mismatch, fallback non-bloquant).

  ## Bottleneck assumé (otp-thinking Iron Law)
  GenServer = sérialisation voulue des transitions d'état (idempotence + écriture
  atomique `state.json`). L'optimisation ETS-reads / pool est **différée** (DN §354,
  critère : latence get_task/submit_result > 100ms). MVP : tout passe par `call`.

  ## Options
  `:name` (`nil` → anonyme, isolation tests), `:state_path`, `:persist`,
  `:topic` (défaut `"fleet.events"`), `:retention_terminal_max` (F148 — nombre max
  de tâches TERMINALES conservées, défaut 500 ; borne `tasks` en mémoire ET la taille
  de `state.json` réécrit à chaque mutation. Les tâches ACTIVES ne comptent pas).
  """

  use GenServer
  require Logger

  alias Fleet.TaskQueue.Task

  @default_topic "fleet.events"
  @active_states [:pending, :assigned, :in_progress]
  # F148 — borne de rétention des tâches terminales (:completed/:failed/:cleared). Sans elle,
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
      state_path: state_path,
      persist: persist?,
      topic: Keyword.get(opts, :topic, @default_topic),
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
    # Recovery (audit deep-02 P1) : les deadlines ne sont armées qu'à l'enqueue. Après restart, on ré-arme
    # les tâches ACTIVES ; une deadline dépassée pendant le downtime → check immédiat (→ :task_failed via
    # handle_info), pas active-pour-toujours.
    for {_id, %Task{state: s} = t} <- state.tasks, s in @active_states do
      maybe_schedule_deadline(t)
    end

    {:noreply, state}
  end

  @impl GenServer
  def handle_continue({:corrupt, found}, state) do
    # Fallback non-bloquant (DN §D) : state vide + event de boot anomaly post-init.
    broadcast(state, %Fleet.Event{
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

    new_state = state |> put_task(task) |> persist()
    # F144/F019 : payload = `%{task_id}` (cohérent avec tous les autres task_* events), PAS le
    # `%Task{}` brut — Task n'a pas de @derive Jason.Encoder → l'ancien `%{task: task}` crashait
    # `Jason.encode!` chez tout consommateur d'events JSON (Fleet.API.WS à chaque enqueue). Aucun
    # consommateur n'a besoin du struct (deck = count, audit = pod_id/correlation_id).
    broadcast(new_state, event(:task_enqueued, task, %{task_id: task.id}))
    maybe_schedule_deadline(task)
    {:reply, {:ok, task}, new_state}
  end

  def handle_call({:get_for_pod, pod_id}, _from, state) do
    case find_active(state.tasks, pod_id) do
      nil ->
        {:reply, {:error, :no_task}, state}

      %Task{state: :pending} = task ->
        assigned = %{task | state: :assigned, assigned_at: now()}
        new_state = state |> put_task(assigned) |> persist()
        broadcast(new_state, event(:task_assigned, assigned, %{task_id: assigned.id}))
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
            # §A.70 : correlation_id du livrable ≠ mandat actif du pod → rejet, aucune mutation.
            {:reply, {:error, :task_id_mismatch}, state}

          _ok ->
            completed = %{task | state: :completed, completed_at: now(), result: result}
            new_state = state |> put_task(completed) |> persist()

            broadcast(
              new_state,
              # role/ticket_id additifs (traça 2026-06-14 : le DeliveryPublisher stampe l'identité de
              # l'agent d'origine sur le commit forge). Les consumers existants ignorent les clés extra.
              event(:task_completed, completed, %{
                task_id: completed.id,
                role: completed.role,
                ticket_id: completed.ticket_id,
                result: result
              })
            )

            {:reply, {:ok, completed}, new_state}
        end
    end
  end

  def handle_call({:clear_for_pod, pod_id}, _from, state) do
    case find_active(state.tasks, pod_id) do
      nil ->
        {:reply, :ok, state}

      %Task{} = task ->
        cleared = %{task | state: :cleared}
        new_state = state |> put_task(cleared) |> persist()
        broadcast(new_state, event(:task_cleared, cleared, %{task_id: cleared.id}))
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

  # ============================================================
  # Deadline (transition :failed)
  # ============================================================

  @impl GenServer
  def handle_info({:check_deadline, task_id}, state) do
    case Map.get(state.tasks, task_id) do
      %Task{state: s} = task when s in @active_states ->
        failed = %{task | state: :failed}
        new_state = state |> put_task(failed) |> persist()

        broadcast(
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

  defp has_completed?(tasks, pod_id) do
    Enum.any?(Map.values(tasks), &(&1.pod_id == pod_id and &1.state == :completed))
  end

  defp put_task(state, %Task{} = task) do
    tasks = Map.put(state.tasks, task.id, task)
    %{state | tasks: prune_terminal(tasks, state.retention_terminal_max)}
  end

  # F148 — garde au plus `max` tâches TERMINALES (les plus récentes), élague les plus vieilles.
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

  defp broadcast(state, %Fleet.Event{} = ev) do
    # F147 — passe par Bus.broadcast (validation registry `assert_authorized!`) au lieu
    # de Phoenix.PubSub direct : les events task ont la même garde que les autres.
    Fleet.EventRouter.Bus.broadcast(state.topic, ev)
  rescue
    # PubSub pas démarré (boot précoce / hors umbrella) → non-bloquant. MAIS pour un event lifecycle-
    # critique (task_completed), un échec silencieux = le pod ne reçoit jamais sa complétion → timeout
    # (audit deep-02). On LOG au minimum ; rendre fatal/retry pour ces events = décision design différée.
    e ->
      require Logger
      Logger.warning("TaskQueue broadcast #{ev.type} échec (pod=#{ev.pod_id}) : #{inspect(e)}")
      :ok
  end

  defp now, do: DateTime.utc_now()

  # ============================================================
  # Helpers — persistence (atomic write tmp + rename, DN §D)
  # ============================================================

  defp default_path do
    Application.get_env(:fleet_task_queue, :state_path, default_state_path())
  end

  # Doctrine 2026-06-11 (fleet sous l'humain) : défaut home-relatif `~/.lcars/task-queue`, comme le
  # pod state_fs_root (cf. `Fleet.Spawner.Pod.default_state_fs_root`). Avant : `/var/lib/lcars` en dur,
  # non-ownable hors du compte `lcars`. Fallback `/var/lib/lcars` si home irrésoluble (jamais en pratique).
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
      e -> Logger.warning("fleet_task_queue persist failed (path=#{path}): #{inspect(e)}")
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

  # fail-loud (fix audit deep-02) : une tâche non-désérialisable (state corrompu / champ requis absent)
  # → `{:corrupt, ...}`, PAS un drop silencieux. L'ancien `for {:ok,t} <- [from_map]` FILTRAIT la tâche
  # corrompue (état tronqué en silence) ; + `from_map` RAISAIT avant le fix `task.ex` (bypass du fallback).
  defp decode_tasks(tasks_map) do
    Enum.reduce_while(tasks_map, {:ok, %{}}, fn {id, tm}, {:ok, acc} ->
      case Task.from_map(tm) do
        {:ok, t} -> {:cont, {:ok, Map.put(acc, id, t)}}
        {:error, reason} -> {:halt, {:corrupt, {:task, id, reason}}}
      end
    end)
  end

  # UUID v4 (`correlation_id = task.id`, DN §A) via la dép `:uuid` (déjà shippée
  # dans l'umbrella) — F149 : ex-uuid4/0 hand-rolled :crypto retiré (dedup).
end
