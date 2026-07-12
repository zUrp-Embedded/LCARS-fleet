defmodule Fleet.TaskQueue.Broadcast do
  @moduledoc """
  Broker broadcast policy — load-bearing vs lossy-observability classification,
  extracted from `Fleet.TaskQueue.Server` (same move as `Fleet.Spawner.Pod.Events`
  on the spawner side). No GenServer state: `bus`, `topic` and the event arrive as
  explicit arguments.

  ## Why TWO regimes (the core of the module)

  A single `broadcast/2` that would swallow EVERY exception into `:ok` — including for
  `work_item.completed`, on which the StepRunConsumer DEPENDS to finish the step_run — would be
  a trap: a swallowed `work_item.completed` = submit OK returned to the pod, BUT the step_run
  finish never triggered → forge lock held for life (silent wedge). Hence the SEPARATION:

    * `lossy/3` — pure OBSERVABILITY (`work_item.enqueued`/`assigned`/`cleared`/
      `failed`-deadline, `state.corrupt`). A failure is non-blocking (rescue → log
      warning, always returns `:ok`) — no one FINISHES a step_run on it.
    * `required/3` — load-bearing LIFECYCLE (`work_item.completed`). The failure is NOT
      swallowed: it surfaces `{:error, {:broadcast_failed, _}}` → the caller (`submit_result`
      on the Server side) propagates it to the pod, which sees an honest failure instead of a
      false "task closed". Recovery is NOT a pod re-submit (the item is already
      `:completed`+persisted BEFORE the broadcast → a re-submit lands in
      `:double_submit_ignored`): the durable backstop is the forge/poller reconciliation,
      which reclaims the orphaned lock and re-dispatches the step (cf.
      `Fleet.MCP.PodTools.WorkItems.submit_result/3`).

  In-process `Phoenix.PubSub.broadcast` almost never raises (local supervised process);
  the realistic failure mode is `UnregisteredError` (lifecycle type outside the registry = build/config
  bug, caught in test) or PubSub not started (early boot). Both become
  LOUD on the lifecycle side.

  ## Why NOT `Fleet.EventRouter.Bus.safe_emit/4`

  `safe_emit` is the Ring 0 protected-emission core — but it emits via `emit/3` →
  `broadcast_main/1`, i.e. ALWAYS the real Bus on the main topic. The broker
  carries two per-instance knobs (`:bus` seam + `:topic`, options of `Server.start_link/1`)
  that serve test isolation (stub bus that fails/raises on `work_item.completed`, dedicated topic
  per async test): both paths must go through the INJECTED bus/topic, out of
  reach of `safe_emit`. The `required/3` path is in any case DELIBERATELY outside
  `safe_emit` (cf. its moduledoc: it flattens every failure into `:ok`, indistinguishable from a
  success) — same exclusion as `Fleet.Spawner.Pod.Events.required_broadcast/2`.
  """

  require Logger

  alias Fleet.TaskQueue.WorkItem

  @doc """
  Builds the canonical envelope `%Fleet.Event{source: :task_queue}` of a work
  item event: `pod_id` and `correlation_id` (= `work_item.id`) come from the `%WorkItem{}`,
  the `payload` is supplied by the caller (never the raw struct — `WorkItem` has no
  `@derive Jason.Encoder`, a struct in the payload would crash `Jason.encode!`
  at any JSON event consumer).
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
  OBSERVABILITY broadcast (lossy): emits `event` on `topic` via `bus.broadcast/2`
  (registry validation `assert_authorized!` included when `bus` is the real
  `Fleet.EventRouter.Bus`: task events have the same guard as the others).

  ALWAYS returns `:ok` (fire-and-forget contract): an exception is rescued + logged
  warning; an `{:error, _}` PubSub passthrough is discarded — no caller FINISHES a
  step_run on these events, a failure is merely an observability loss.
  """
  @spec lossy(module(), String.t(), Fleet.Event.t()) :: :ok
  def lossy(bus, topic, %Fleet.Event{} = ev) do
    _ = bus.broadcast(topic, ev)
    :ok
  rescue
    e ->
      Logger.warning("Broadcast: lossy #{ev.type} failed (pod=#{ev.pod_id}): #{inspect(e)}")

      :ok
  end

  @doc """
  Load-bearing LIFECYCLE broadcast (`work_item.completed`): the failure is NOT swallowed.

  Returns `:ok` or `{:error, {:broadcast_failed, reason}}` (raise OR `{:error, _}` from
  `bus.broadcast/2`). Logged as ERROR (not warning): a non-broadcast `work_item.completed`
  = potential wedge (step_run never finished), it is an incident — the caller (`submit_result`)
  propagates the error to the pod, no mute `:ok` that would leave the forge lock for life.
  """
  @spec required(module(), String.t(), Fleet.Event.t()) ::
          :ok | {:error, {:broadcast_failed, term()}}
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
