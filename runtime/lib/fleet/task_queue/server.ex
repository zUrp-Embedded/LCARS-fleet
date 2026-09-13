defmodule Fleet.TaskQueue.Server do
  @moduledoc """
  Serializes an in-memory broker. Restart begins empty; forge-driven callers redispatch
  from durable issue/route/PR state. This server does not itself recover or persist work;
  adding a state file would require reconciling mandates already superseded by the forge.

  Options: name (nil for anonymous), topic (default fleet.events), bus (broadcast/2 module,
  default EventRouter.Bus), retention_terminal_max (default 500) and poll_retention_ms
  (default one day). Retention values also have task_queue_* application-config defaults.
  Options are not validated here. Terminal retention excludes active items; it is not a
  total memory bound. Poll pruning runs only on subsequent polls, and connection marks
  persist until explicit clear/restart. All transitions and broadcasts run on this process.

  Enqueue supersedes the pod's active items. Pull assigns once; completion requires a pulled
  item and checks a supplied work_item_id before state. Completion broadcasts before terminal
  commit; returned failures leave state unchanged for retry. Other transitions use lossy events.
  Broadcast documents why neither :ok nor an error establishes consumer delivery, and why
  partial delivery can duplicate work on retries. Completion history and deduplication are
  bounded by retention and lost on restart.

  The pull prerequisite matches Poller.Reconciliation's @pulled_states [:assigned]
  ownership rule: a pending admission alone does not establish an executor.

  Deadlines are queued checks against wall-clock time, not hard cutoffs on pull/submit.
  Checks and timer arming stay together because send_after targets this server; retention
  shares WorkItem.active_states/0 with selection, supersession and deadline handling.
  """

  use GenServer
  require Logger

  alias Fleet.EventRouter.Bus
  alias Fleet.TaskQueue.Broadcast
  alias Fleet.TaskQueue.WorkItem

  @active_states WorkItem.active_states()

  @max_timer 4_294_967_295
  @default_retention_terminal 500
  @default_poll_retention_ms 86_400_000

  @spec start_link(keyword()) :: GenServer.on_start()
  def start_link(opts \\ []) do
    case Keyword.fetch(opts, :name) do
      {:ok, nil} -> GenServer.start_link(__MODULE__, opts)
      {:ok, name} -> GenServer.start_link(__MODULE__, opts, name: name)
      :error -> GenServer.start_link(__MODULE__, opts, name: __MODULE__)
    end
  end

  @impl GenServer
  def init(opts) do
    base = %{
      work_items: %{},
      # Empty pulls also record activity; restart forgets it.
      polls: %{},
      # MCP traffic is a startup hint earlier than a work poll, not continuous liveness.
      connects: %{},
      topic: Keyword.get(opts, :topic, Bus.main_topic()),
      # Per-server failure seam avoids mutating the global bus registry in tests.
      bus: Keyword.get(opts, :bus, Bus),
      retention_terminal_max:
        Keyword.get(opts, :retention_terminal_max) ||
          Application.get_env(
            :lcars_fleet,
            :task_queue_retention_terminal_max,
            @default_retention_terminal
          ),
      poll_retention_ms:
        Keyword.get(opts, :poll_retention_ms) ||
          Application.get_env(
            :lcars_fleet,
            :task_queue_poll_retention_ms,
            @default_poll_retention_ms
          )
    }

    {:ok, base}
  end

  # Cast avoids blocking MCP responses on this mailbox. Later inbound lines may repeat a lost mark.
  @impl GenServer
  def handle_cast({:mark_connected, pod_id}, state) do
    {:noreply, %{state | connects: Map.put_new(state.connects, pod_id, true)}}
  end

  @impl GenServer
  def handle_call({:enqueue, pod_id, attrs}, _from, state) do
    case WorkItem.new(pod_id, attrs) do
      {:error, _} = err ->
        {:reply, err, state}

      {:ok, work_item} ->
        # Clear both pending and assigned predecessors at write time. Selecting only the newest
        # on reads would hide stale active items from callers while leaking ownership state.
        {state, superseded} = supersede_active(state, pod_id)

        new_state = state |> put_work_item(work_item)

        # Emit each supersession so audit/context consumers can retire the old mandate.
        # These events remain lossy; :superseded distinguishes them from explicit clear.
        for t <- superseded do
          Logger.debug("Server: enqueue pod=#{pod_id} supersedes stale active item #{t.id}")

          lossy_broadcast(
            new_state,
            event(:"work_item.cleared", t, %{work_item_id: t.id, reason: :superseded})
          )
        end

        lossy_broadcast(
          new_state,
          event(:"work_item.enqueued", work_item, %{work_item_id: work_item.id})
        )

        maybe_schedule_deadline(work_item)
        {:reply, {:ok, work_item}, new_state}
    end
  end

  def handle_call({:get_for_pod, pod_id}, _from, state) do
    state = record_poll(state, pod_id)

    case find_active(state.work_items, pod_id) do
      nil ->
        {:reply, {:error, :no_work_item}, state}

      %WorkItem{state: :pending} = work_item ->
        assigned = %{work_item | state: :assigned, assigned_at: now()}
        new_state = state |> put_work_item(assigned)

        lossy_broadcast(
          new_state,
          event(:"work_item.assigned", assigned, %{work_item_id: assigned.id})
        )

        {:reply, {:ok, assigned}, new_state}

      %WorkItem{} = work_item ->
        # already :assigned → idempotent (no re-broadcast, no double dispatch)
        {:reply, {:ok, work_item}, state}
    end
  end

  def handle_call({:submit_result, pod_id, result}, _from, state) do
    case find_active(state.work_items, pod_id) do
      nil ->
        if completed_submit?(state.work_items, pod_id, result),
          do: {:reply, {:error, :double_submit_ignored}, state},
          else: {:reply, {:error, :no_active_work_item}, state}

      %WorkItem{} = work_item ->
        submit_into(work_item, result, state)
    end
  end

  # Clear every active item, including duplicates injected into corrupt test state.
  def handle_call({:clear_for_pod, pod_id}, _from, state) do
    # Remove startup marks even when no active item remains; work-item retention does not prune them.
    state = %{
      state
      | polls: Map.delete(state.polls, pod_id),
        connects: Map.delete(state.connects, pod_id)
    }

    active =
      state.work_items
      |> Map.values()
      |> Enum.filter(&(&1.pod_id == pod_id and &1.state in @active_states))

    case active do
      [] ->
        {:reply, :ok, state}

      work_items ->
        cleared = Enum.map(work_items, &%{&1 | state: :cleared})
        new_state = Enum.reduce(cleared, state, &put_work_item(&2, &1))

        for t <- cleared,
            do:
              lossy_broadcast(
                new_state,
                event(:"work_item.cleared", t, %{work_item_id: t.id})
              )

        {:reply, :ok, new_state}
    end
  end

  def handle_call(:list_pending, _from, state) do
    pending = state.work_items |> Map.values() |> Enum.filter(&(&1.state == :pending))
    {:reply, pending, state}
  end

  def handle_call(:list_active, _from, state) do
    active = state.work_items |> Map.values() |> Enum.filter(&(&1.state in @active_states))
    {:reply, active, state}
  end

  def handle_call({:pod_status, pod_id}, _from, state) do
    status =
      case latest_for_pod(state.work_items, pod_id) do
        nil -> nil
        %WorkItem{state: s} -> s
      end

    {:reply, {:ok, status}, state}
  end

  def handle_call({:pod_active_issue_id, pod_id}, _from, state) do
    issue =
      case latest_for_pod(state.work_items, pod_id) do
        nil -> nil
        %WorkItem{issue_id: t} -> t
      end

    {:reply, {:ok, issue}, state}
  end

  # TaskProbe uses presence as a startup hint. Timestamps/TTL use wall clock and can be
  # affected by clock adjustments; reading last_poll does not itself prune stale entries.
  def handle_call({:last_poll, pod_id}, _from, state) do
    {:reply, Map.get(state.polls, pod_id), state}
  end

  def handle_call({:connected?, pod_id}, _from, state) do
    {:reply, Map.has_key?(state.connects, pod_id), state}
  end

  @impl GenServer
  def handle_info({:check_deadline, work_item_id}, state) do
    case Map.get(state.work_items, work_item_id) do
      %WorkItem{state: s} = work_item when s in @active_states ->
        if deadline_reached?(work_item) do
          failed = %{work_item | state: :failed}
          new_state = state |> put_work_item(failed)

          lossy_broadcast(
            new_state,
            event(:"work_item.failed", failed, %{
              work_item_id: failed.id,
              reason: :deadline_expired
            })
          )

          {:noreply, new_state}
        else
          maybe_schedule_deadline(work_item)
          {:noreply, state}
        end

      _ ->
        {:noreply, state}
    end
  end

  def handle_info(_msg, state), do: {:noreply, state}

  defp submit_into(work_item, result, state) do
    case result["work_item_id"] || result[:work_item_id] do
      tid when tid != nil and tid != work_item.id ->
        {:reply, {:error, :work_item_id_mismatch}, state}

      # Enforce pull-before-close in state, not by assuming only a reader could know the id.
      # Check the correlator first so a stale submission names the id error, not the new item's state.
      _ok when work_item.state == :pending ->
        {:reply, {:error, :work_item_not_pulled}, state}

      _ok ->
        commit_submission(work_item, result, state)
    end
  end

  defp commit_submission(work_item, result, state) do
    clean_result =
      result
      |> Map.delete("work_item_id")
      |> Map.delete(:work_item_id)
      |> put_runtime_brief(work_item)

    completed = %{
      work_item
      | state: :completed,
        completed_at: now(),
        result: clean_result
    }

    ev =
      event(:"work_item.completed", completed, %{
        work_item_id: completed.id,
        role: completed.role,
        issue_id: completed.issue_id,
        result: clean_result,
        metadata: completed.metadata
      })

    # Publish before terminal commit so failures remain retryable. The pod's monitoring path
    # forwards completion toward StepRunConsumer; neither hop is acknowledged here. A failure
    # may follow partial delivery, or this process may die after broadcast and before commit:
    # retries can duplicate events. The broker is not durable; forge reconciliation remains needed.
    case required_broadcast(state, ev) do
      :ok -> {:reply, {:ok, completed}, put_work_item(state, completed)}
      {:error, _} = err -> {:reply, err, state}
    end
  end

  defp find_active(work_items, pod_id) do
    work_items
    |> Map.values()
    |> Enum.filter(&(&1.pod_id == pod_id and &1.state in @active_states))
    |> Enum.max_by(& &1.enqueued_at, DateTime, fn -> nil end)
  end

  # Prefer the dispatched brief's provenance over pod-supplied string keys when a SHA exists.
  # Without it, leave the result unchanged. Atom-keyed citations are not removed by this helper.
  defp put_runtime_brief(result, %WorkItem{brief_sha: sha, brief_ref: ref}) when is_binary(sha) do
    result |> Map.put("brief_sha", sha) |> Map.put("brief_ref", ref)
  end

  defp put_runtime_brief(result, _work_item), do: result

  defp latest_for_pod(work_items, pod_id) do
    work_items
    |> Map.values()
    |> Enum.filter(&(&1.pod_id == pod_id))
    |> Enum.max_by(& &1.enqueued_at, DateTime, fn -> nil end)
  end

  # Return every cleared item for per-mandate events; later terminal pruning may discard history.
  # A supplied old id is refused against the replacement. Id-less direct submissions can still
  # close a replacement once pulled; the pod-facing MCP boundary must require the correlator.
  defp supersede_active(state, pod_id) do
    superseded =
      state.work_items
      |> Map.values()
      |> Enum.filter(&(&1.pod_id == pod_id and &1.state in @active_states))
      |> Enum.map(&%{&1 | state: :cleared})

    work_items =
      Enum.reduce(superseded, state.work_items, fn t, acc -> Map.put(acc, t.id, t) end)

    {%{state | work_items: work_items}, superseded}
  end

  # Correlate to this pod's retained completed id, not any earlier completion by the pod.
  # Otherwise completed A followed by cleared B could falsely acknowledge B's late result.
  # No id or pruned history cannot establish a duplicate; a new active item takes the other branch.
  defp completed_submit?(work_items, pod_id, result) do
    case result["work_item_id"] || result[:work_item_id] do
      nil ->
        false

      id ->
        case Map.get(work_items, id) do
          %WorkItem{pod_id: ^pod_id, state: :completed} -> true
          _ -> false
        end
    end
  end

  defp record_poll(state, pod_id) when is_binary(pod_id) do
    now = now()

    polls = state.polls |> prune_stale_polls(now, state.poll_retention_ms) |> Map.put(pod_id, now)
    %{state | polls: polls}
  end

  defp prune_stale_polls(polls, now, ttl_ms) do
    cutoff = DateTime.add(now, -ttl_ms, :millisecond)
    Map.reject(polls, fn {_pod, ts} -> DateTime.compare(ts, cutoff) == :lt end)
  end

  defp put_work_item(state, %WorkItem{} = work_item) do
    work_items = Map.put(state.work_items, work_item.id, work_item)
    %{state | work_items: prune_terminal(work_items, state.retention_terminal_max)}
  end

  defp prune_terminal(work_items, max) do
    terminal = for {_id, t} <- work_items, t.state not in @active_states, do: t

    if length(terminal) <= max do
      work_items
    else
      drop_ids =
        terminal
        |> Enum.sort_by(&recency/1, {:desc, DateTime})
        |> Enum.drop(max)
        |> MapSet.new(& &1.id)

      Map.reject(work_items, fn {id, _t} -> MapSet.member?(drop_ids, id) end)
    end
  end

  defp recency(%WorkItem{} = t), do: t.completed_at || t.assigned_at || t.enqueued_at

  defp maybe_schedule_deadline(%WorkItem{deadline: %DateTime{} = dl, id: id}) do
    ms = DateTime.diff(dl, DateTime.utc_now(), :millisecond)

    cond do
      ms <= 0 ->
        send(self(), {:check_deadline, id})

      ms > @max_timer ->
        Process.send_after(self(), {:check_deadline, id}, @max_timer)

      true ->
        Process.send_after(self(), {:check_deadline, id}, ms)
    end

    :ok
  end

  defp maybe_schedule_deadline(_), do: :ok

  defp deadline_reached?(%WorkItem{deadline: %DateTime{} = dl}),
    do: DateTime.compare(DateTime.utc_now(), dl) != :lt

  defp deadline_reached?(_), do: false

  defp event(type, %WorkItem{} = work_item, payload),
    do: Broadcast.event(type, work_item, payload)

  defp lossy_broadcast(state, %Fleet.Event{} = ev),
    do: Broadcast.lossy(state.bus, state.topic, ev)

  defp required_broadcast(state, %Fleet.Event{} = ev),
    do: Broadcast.required(state.bus, state.topic, ev)

  defp now, do: DateTime.utc_now()
end
