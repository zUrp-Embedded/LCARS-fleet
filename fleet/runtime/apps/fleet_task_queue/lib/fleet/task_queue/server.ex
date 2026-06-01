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
  `:pubsub` (défaut `Fleet.PubSub`), `:topic` (défaut `"fleet.events"`).
  """

  use GenServer
  require Logger

  alias Fleet.TaskQueue.Task

  @default_pubsub Fleet.PubSub
  @default_topic "fleet.events"
  @default_path "/var/lib/lcars/task-queue/state.json"
  @active_states [:pending, :assigned, :in_progress]

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
      pubsub: Keyword.get(opts, :pubsub, @default_pubsub),
      topic: Keyword.get(opts, :topic, @default_topic)
    }

    case load_state(state_path, persist?) do
      :empty -> {:ok, base}
      {:ok, tasks} -> {:ok, %{base | tasks: tasks}}
      {:corrupt, found} -> {:ok, base, {:continue, {:corrupt, found}}}
    end
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
      id: uuid4(),
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
    broadcast(new_state, event(:task_enqueued, task, %{task: task}))
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
        completed = %{task | state: :completed, completed_at: now(), result: result}
        new_state = state |> put_task(completed) |> persist()

        broadcast(
          new_state,
          event(:task_completed, completed, %{task_id: completed.id, result: result})
        )

        {:reply, {:ok, completed}, new_state}
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
    |> Enum.sort_by(& &1.enqueued_at, {:desc, DateTime})
    |> List.first()
  end

  defp latest_for_pod(tasks, pod_id) do
    tasks
    |> Map.values()
    |> Enum.filter(&(&1.pod_id == pod_id))
    |> Enum.sort_by(& &1.enqueued_at, {:desc, DateTime})
    |> List.first()
  end

  defp has_completed?(tasks, pod_id) do
    Enum.any?(Map.values(tasks), &(&1.pod_id == pod_id and &1.state == :completed))
  end

  defp put_task(state, %Task{} = task), do: %{state | tasks: Map.put(state.tasks, task.id, task)}

  defp maybe_schedule_deadline(%Task{deadline: %DateTime{} = dl, id: id}) do
    ms = DateTime.diff(dl, DateTime.utc_now(), :millisecond)
    if ms > 0, do: Process.send_after(self(), {:check_deadline, id}, ms)
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
    Phoenix.PubSub.broadcast(state.pubsub, state.topic, ev)
  rescue
    # PubSub pas démarré (boot très précoce / contexte hors umbrella) → non-bloquant.
    _ -> :ok
  end

  defp now, do: DateTime.utc_now()

  # ============================================================
  # Helpers — persistence (atomic write tmp + rename, DN §D)
  # ============================================================

  defp default_path do
    Application.get_env(:fleet_task_queue, :state_path, @default_path)
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
        tasks =
          for {id, tm} <- tasks_map, {:ok, t} <- [Task.from_map(tm)], into: %{}, do: {id, t}

        {:ok, tasks}

      {:ok, %{"v" => v}} ->
        {:corrupt, v}

      _ ->
        {:corrupt, :unparseable}
    end
  end

  # ============================================================
  # UUID v4 (substrat :crypto, pas de dép externe — DN §A `correlation_id = task.id`)
  # ============================================================

  defp uuid4 do
    <<u0::48, _::4, u1::12, _::2, u2::62>> = :crypto.strong_rand_bytes(16)
    <<a::32, b::16, c::16, d::16, e::48>> = <<u0::48, 4::4, u1::12, 2::2, u2::62>>

    :io_lib.format("~8.16.0b-~4.16.0b-~4.16.0b-~4.16.0b-~12.16.0b", [a, b, c, d, e])
    |> IO.iodata_to_binary()
  end
end
