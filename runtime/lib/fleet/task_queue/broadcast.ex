defmodule Fleet.TaskQueue.Broadcast do
  @moduledoc """
  Broadcast policy for broker events using an injected bus and topic.

  Observability events are lossy: returned errors and rescued exceptions become :ok.
  `work_item.completed` is required: failures return
  `{:error, {:broadcast_failed, reason}}`, and the server keeps the item active
  for replay.

  Required means the caller must not commit on a returned failure. It is not a delivery
  acknowledgement: zero subscribers can yield :ok, while main-topic delivery can precede
  failed pod fan-out. An injected bus may also deliver then fail. Retries therefore need
  downstream deduplication/reconciliation; this module provides no exactly-once guarantee.

  Topic subscription counts do not prove the intended event consumer is listening: a dashboard
  can satisfy that probe. Pod liveness belongs to Spawner, which this domain cannot depend back
  on. Acknowledgements or durable handoff require a separate protocol; this broker has no outbox.
  Forge reconciliation supplies restart recovery. Neither wrapper catches exits or throws.
  """

  require Logger

  alias Fleet.Event
  alias Fleet.TaskQueue.WorkItem

  @doc """
  Builds a task-queue event using the work-item ID as correlation ID.
  """
  @spec event(atom(), WorkItem.t(), map()) :: Event.t()
  def event(type, %WorkItem{} = work_item, payload) do
    Event.new(:task_queue, type,
      pod_id: work_item.pod_id,
      correlation_id: work_item.id,
      payload: payload
    )
  end

  @doc """
  Broadcasts observability, logging returned errors and rescued exceptions, then returning :ok.
  Other return values are accepted; exits/throws and errors in diagnostic logging can escape.
  """
  @spec lossy(module(), String.t(), Event.t()) :: :ok
  def lossy(bus, topic, %Event{} = ev) do
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

  :ok is the bus result, not subscriber acknowledgement. Returned errors and rescued
  exceptions become broadcast_failed; unexpected return values raise a rescued CaseClauseError.
  A failure can follow partial delivery, so replay may duplicate an event.
  """
  @spec required(module(), String.t(), Event.t()) ::
          :ok | {:error, {:broadcast_failed, term()}}
  def required(bus, topic, %Event{} = ev) do
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
