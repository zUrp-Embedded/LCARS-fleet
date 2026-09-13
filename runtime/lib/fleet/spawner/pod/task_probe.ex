defmodule Fleet.Spawner.Pod.TaskProbe do
  @moduledoc """
  Read-only TaskQueue probes for pod kicks, deadlines, reporting and brief admission.
  Broker exceptions and exits become `false` for boolean probes or `:unknown` for decisions
  that must distinguish an unavailable broker from idle/free state. Callers own timers and logs.
  """

  @doc """
  Whether TaskQueue has recorded a get_work_item poll for `state.pod_id`.
  This acknowledges an agent request, unlike mere process presence. Broker failure returns false.
  """
  @spec polled?(term()) :: boolean()
  def polled?(%{pod_id: pod_id}) when is_binary(pod_id) do
    Fleet.TaskQueue.last_poll(pod_id) != nil
  rescue
    _ -> false
  catch
    # GenServer.call exits on broker loss; rescue alone does not contain it.
    :exit, _ -> false
  end

  def polled?(_), do: false

  @doc """
  Whether the MCP client has spoken on the pod socket, before any get_work_item poll is required.
  The kick handler uses this weaker readiness signal to avoid buffered input during cold start.
  Broker failure returns false, delaying input until readiness can be observed.
  """
  @spec repl_up?(String.t()) :: boolean()
  def repl_up?(pod_id) when is_binary(pod_id) do
    Fleet.TaskQueue.connected?(pod_id)
  rescue
    _ -> false
  catch
    :exit, _ -> false
  end

  def repl_up?(_), do: false

  defp safe_pod_status(pod_id) do
    Fleet.TaskQueue.pod_status(pod_id)
  rescue
    _ -> :error
  catch
    :exit, _ -> :error
  end

  @doc """
  Reporting boolean for pending/assigned work; false includes broker failure.
  Deadline decisions must use `active_task_state/1` to distinguish idle from unknown.
  """
  @spec pod_has_active_task?(String.t()) :: boolean()
  def pod_has_active_task?(pod_id),
    do: match?({:ok, s} when s in [:pending, :assigned], safe_pod_status(pod_id))

  @doc """
  Deadline decision: `:active` for pending/assigned, `:idle` for other known statuses,
  `:unknown` for broker failure. At expiry, Pod fails active work, lets idle deadlines lapse,
  and re-arms unknown state. Treating unknown as idle could leave a hung pod without a watchdog.
  """
  @spec active_task_state(String.t()) :: :active | :idle | :unknown
  def active_task_state(pod_id) do
    case safe_pod_status(pod_id) do
      {:ok, s} when s in [:pending, :assigned] -> :active
      {:ok, _} -> :idle
      :error -> :unknown
    end
  end

  @doc """
  True only for assigned/completed work, which acknowledges a pull and stops kicks.
  Pending, absent, cleared, failed or unavailable status returns false: these do not establish
  a pull. This also covers the spawn/enqueue race; retries remain bounded by the handler.
  """
  @spec brief_pulled?(String.t()) :: boolean()
  def brief_pulled?(pod_id),
    do: match?({:ok, s} when s in [:assigned, :completed], safe_pod_status(pod_id))

  @doc """
  True only for `{:ok, nil}` task status, selecting the no-brief bootstrap cadence.
  Other statuses and broker failure return false, retaining the pending-brief retry policy.
  """
  @spec no_pending_brief?(String.t()) :: boolean()
  def no_pending_brief?(pod_id),
    do: match?({:ok, nil}, safe_pod_status(pod_id))

  @doc """
  Admission state: `:free` for nil task status, `:occupied` for any other known status,
  `:unknown` for broker failure. Brief admission skips unknown state to avoid double-enqueue
  and logs the failure, since silently dropping an admin brief could leave the pod idle.
  """
  @spec brief_slot(String.t()) :: :free | :occupied | :unknown
  def brief_slot(pod_id) do
    case safe_pod_status(pod_id) do
      {:ok, nil} -> :free
      {:ok, _} -> :occupied
      :error -> :unknown
    end
  end
end
