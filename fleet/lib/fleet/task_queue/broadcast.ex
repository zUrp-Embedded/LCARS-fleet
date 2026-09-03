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

  ## What `required` buys, and what it does NOT

  It is a ONE-WAY guarantee, and only the refusal side is proven: `{:error, _}` means NOBODY
  received, so the caller may keep the item active and replay honestly. `:ok` means the BUS
  ACCEPTED the message — not that a consumer existed, was alive, or handled it. Zero subscribers
  is `:ok`. The name says "required" about the CALLER's obligation not to commit on failure, never
  about delivery.

  **And the probe that would close the gap cannot live here** — two measured reasons, both
  structural:

    * Every consumer of this fleet subscribes to ONE topic (`fleet.events`) and filters by event
      type itself. "Does this topic have a subscriber?" is answered `true` by an open dashboard
      websocket, so it would certify delivery of `work_item.completed` while its actual consumer is
      dead. An exact answer to a neighbouring question is worse than none: it closes the matter.
    * The precise question — "is THIS work item's pod alive and subscribed?" — belongs to the
      SPAWNER, which is this domain's SOURCE and not its dependency (`Fleet.TaskQueue` declares no
      `Fleet.Spawner`, and the edge would close a cycle boundary refuses). The broker distributes
      and collects; it does not reach back to ask whether the source is still listening.

  So an acknowledged delivery is an ARCHITECTURE decision — a per-event-type subscriber notion in
  `Fleet.EventRouter` (which deliberately has "direct subscribers, no dispatch table"), or the
  durable outbox this fleet does not have, its single queue being EPHEMERAL BY CONSTRUCTION
  (BL-6-113 — cf. `Server`'s moduledoc).
  Until one is taken, the durable half of completion stays the forge reconciliation (F-C050).
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
  Broadcasts a lossy observability event and always returns `:ok`.

  Exceptions and delivery errors are logged.
  """
  @spec lossy(module(), String.t(), Event.t()) :: :ok
  # CI-09
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

  `:ok` proves the bus accepted the message, NOT that a consumer received it — zero subscribers is
  `:ok`. The moduledoc states why the probe that would prove delivery cannot live in this domain.
  """
  @spec required(module(), String.t(), Event.t()) ::
          :ok | {:error, {:broadcast_failed, term()}}
  # CI-03
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
