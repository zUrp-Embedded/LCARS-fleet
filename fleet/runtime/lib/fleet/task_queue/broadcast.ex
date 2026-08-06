defmodule Fleet.TaskQueue.Broadcast do
  @moduledoc """
  Broadcast policy for broker events using an injected bus and topic.

  Observability events are lossy: failures are logged and flattened to `:ok`.
  `work_item.completed` is required: failures return
  `{:error, {:broadcast_failed, reason}}`, and the server keeps the item active
  for replay.

  Required-broadcast retries assume the current bus fails before delivering to
  any subscriber. A bus capable of partial delivery must provide a different
  replay contract.
  """

  require Logger

  alias Fleet.TaskQueue.WorkItem

  @doc """
  Builds a task-queue event using the work-item ID as correlation ID.
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
  Broadcasts a lossy observability event and always returns `:ok`.

  Exceptions and delivery errors are logged.
  """
  @spec lossy(module(), String.t(), Fleet.Event.t()) :: :ok
  # CI-09
  def lossy(bus, topic, %Fleet.Event{} = ev) do
    case bus.broadcast(topic, ev) do
      {:error, reason} ->
        Logger.warning(
          "Broadcast: lossy #{ev.type} NOT delivered (pod=#{ev.pod_id}): #{inspect(reason)}"
        )

      _ ->
        :ok
    end

    :ok
  rescue
    e ->
      Logger.warning("Broadcast: lossy #{ev.type} failed (pod=#{ev.pod_id}): #{inspect(e)}")

      :ok
  end

  @doc """
  Broadcasts a required lifecycle event, returning `:broadcast_failed` on failure.
  """
  @spec required(module(), String.t(), Fleet.Event.t()) ::
          :ok | {:error, {:broadcast_failed, term()}}
  # CI-03
  def required(bus, topic, %Fleet.Event{} = ev) do
    case bus.broadcast(topic, ev) do
      :ok ->
        :ok

      {:error, reason} ->
        Logger.error(
          "Broadcast: required_broadcast #{ev.type} FAILED (pod=#{ev.pod_id}): #{inspect(reason)} — " <>
            "lifecycle NOT broadcast (the step_run will not finish; propagated to caller, not swallowed)"
        )

        {:error, {:broadcast_failed, reason}}
    end
  rescue
    e ->
      Logger.error(
        "Broadcast: required_broadcast #{ev.type} RAISED (pod=#{ev.pod_id}): #{inspect(e)} — " <>
          "lifecycle NOT broadcast (propagated to caller, not swallowed)"
      )

      {:error, {:broadcast_failed, e}}
  end
end
