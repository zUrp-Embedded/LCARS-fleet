defmodule Fleet.Starfleet.AuditConsumer do
  @moduledoc """
  Audit consumer — events lifecycle + security.

  Subscribes to the `Fleet.EventRouter.Bus` topic `fleet.events`, logs at
  audit-grade for events:
    * `:"pod.completed"` / `:"pod.failed"` — Pod GenServer Port stream lifecycle
      (real producers: `Fleet.Spawner.Pod`).
    * `:"fleet.boot_complete"` / `:"fleet.boot_partial"` / `:"fleet.boot_failed"`
      — BootOrchestrator lifecycle.
    * task-queue: `:"work_item.enqueued"` / `:"work_item.assigned"` / `:"work_item.completed"` /
      `:"work_item.cleared"` / `:"work_item.failed"` / `:"state.corrupt"` (producer `Fleet.TaskQueue`).

  ## HALF OF THIS SURVIVES A RESTART, AND IT IS NOT THE HALF YOU WOULD ASSUME

  "Audit-grade" describes the CONTENT of these lines, never their durability. The split is by
  Logger level, and `Fleet.DurableLog` writes `warning` and above:

    * ANOMALIES are durable — `pod.failed`, `work_item.failed`, `state.corrupt`, `boot_partial`,
      `boot_failed`.
    * THE NOMINAL TIMELINE IS NOT — `work_item.enqueued` / `assigned` / `completed` / `cleared` and
      `fleet.boot_complete` are `:info`, so they live in the daemon's console and die with it.

  The consequence, stated because it bites exactly when it is needed: after a restart a durable
  `pod.failed` cannot be tied back to the `work_item.assigned` that produced it. Anomalies are
  reconstructible; the story that led to them is not.

  Raising these to `warning` is NOT the fix and must not be done as one: `info` is the level this
  codebase assigns to a lifecycle milestone, `warning` the level at which something DEGRADED, and
  moving them would both lie about severity and bury the durable trace under routine passes — the
  reason `DurableLog` names for excluding `info` in the first place.

  A durable nominal timeline, if the fleet ever needs one, belongs in a structured ledger and not
  in a level bump. `Fleet.Starfleet.AuditLog` is that shape and is reserved for Cat-5 by design, so
  widening it is a DECISION with a schema behind it, not a patch.

  `:"pod.drift"` handler (type-only clause): DORMANT — NO producer emits it (the claimed
  PermanentBoot producer does not exist). Also consumed by
  DriftMonitor. Kept wired for the day a real drift signal is produced.

  GenServer that subscribes at boot (init/1), dispatches via canonical `%Fleet.Event{}` clauses
  ONLY (no tuple format exists on the Bus). No runtime side effect
  beyond the log (forensics + a separate dashboard subscriber).

  Test-seam: `start_link(opts)` accepts `:subscribe` (default true)
  → tests instantiate without the global subscribe.
  """

  use GenServer
  require Logger

  alias Fleet.EventRouter.Bus

  def start_link(opts \\ []) do
    name = Keyword.get(opts, :name, __MODULE__)
    GenServer.start_link(__MODULE__, opts, name: name)
  end

  @impl true
  def init(opts) do
    if Keyword.get(opts, :subscribe, true), do: :ok = Bus.subscribe()
    {:ok, %{events_count: 0}}
  end

  # Strict canonical %Fleet.Event{} schema (task_queue lifecycle) — every Bus producer emits
  # %Fleet.Event{}, no tuple-format clause exists here.
  @impl true
  def handle_info(%Fleet.Event{source: :task_queue, type: type} = event, state) do
    log_task_queue_event(type, event)
    {:noreply, %{state | events_count: state.events_count + 1}}
  end

  # V2 extensions (MCPMonitor).
  def handle_info(
        %Fleet.Event{source: :starfleet, type: :"sdk.upstream_alert", payload: p},
        state
      ) do
    Logger.warning(
      "AUDIT starfleet.sdk.upstream_alert package=#{inspect(Map.get(p, "package"))} " <>
        "current=#{inspect(Map.get(p, "current"))} " <>
        "upstream=#{inspect(Map.get(p, "upstream"))}"
    )

    {:noreply, %{state | events_count: state.events_count + 1}}
  end

  def handle_info(
        %Fleet.Event{source: :starfleet, type: :"mcp.server_crashed", payload: p},
        state
      ) do
    Logger.error(
      "AUDIT starfleet.mcp.server_crashed target=#{inspect(Map.get(p, "target"))} " <>
        "previous=#{inspect(Map.get(p, "previous_status"))} " <>
        "new=#{inspect(Map.get(p, "new_status"))}"
    )

    {:noreply, %{state | events_count: state.events_count + 1}}
  end

  def handle_info(
        %Fleet.Event{source: :starfleet, type: type, payload: payload},
        state
      )
      when type in [:"fleet.boot_complete", :"fleet.boot_partial", :"fleet.boot_failed"] do
    log_boot_event(type, payload)
    {:noreply, %{state | events_count: state.events_count + 1}}
  end

  def handle_info(
        %Fleet.Event{source: :spawner, type: type, payload: payload},
        state
      )
      when type in [:"pod.completed", :"pod.failed"] do
    log_pod_lifecycle_event(type, payload)
    {:noreply, %{state | events_count: state.events_count + 1}}
  end

  def handle_info(%Fleet.Event{type: :"pod.drift", payload: payload} = event, state) do
    Logger.warning(
      "AUDIT pod.drift pod=#{event.pod_id || Map.get(payload, "pod_id", "?")} " <>
        "count=#{inspect(Map.get(payload, "drift_count", "?"))}"
    )

    {:noreply, %{state | events_count: state.events_count + 1}}
  end

  def handle_info(%Fleet.Event{}, state), do: {:noreply, state}

  def handle_info(_other, state), do: {:noreply, state}

  defp log_task_queue_event(:"work_item.enqueued", %Fleet.Event{pod_id: pid, correlation_id: tid}) do
    Logger.info("AUDIT task_queue.work_item.enqueued pod=#{pid} work_item=#{tid}")
  end

  defp log_task_queue_event(:"work_item.assigned", %Fleet.Event{pod_id: pid, correlation_id: tid}) do
    Logger.info("AUDIT task_queue.work_item.assigned pod=#{pid} work_item=#{tid}")
  end

  defp log_task_queue_event(:"work_item.completed", %Fleet.Event{pod_id: pid, correlation_id: tid}) do
    Logger.info("AUDIT task_queue.work_item.completed pod=#{pid} work_item=#{tid}")
  end

  defp log_task_queue_event(:"work_item.cleared", %Fleet.Event{pod_id: pid, correlation_id: tid}) do
    Logger.info("AUDIT task_queue.work_item.cleared pod=#{pid} work_item=#{tid}")
  end

  defp log_task_queue_event(:"work_item.failed", %Fleet.Event{
         pod_id: pid,
         correlation_id: tid,
         payload: p
       }) do
    reason = Map.get(p, :reason, "?")

    Logger.warning(
      "AUDIT task_queue.work_item.failed pod=#{pid} work_item=#{tid} reason=#{inspect(reason)}"
    )
  end

  defp log_task_queue_event(:"state.corrupt", %Fleet.Event{payload: p}) do
    Logger.error("AUDIT task_queue.state.corrupt #{inspect(p)}")
  end

  defp log_task_queue_event(_other, _event), do: :ok

  defp log_boot_event(:"fleet.boot_complete", payload) do
    Logger.info("AUDIT fleet.boot_complete #{inspect(payload)}")
  end

  defp log_boot_event(:"fleet.boot_partial", payload) do
    Logger.warning("AUDIT fleet.boot_partial #{inspect(payload)}")
  end

  defp log_boot_event(:"fleet.boot_failed", payload) do
    Logger.error("AUDIT fleet.boot_failed #{inspect(payload)}")
  end

  defp log_pod_lifecycle_event(:"pod.completed", payload) do
    Logger.info(
      "AUDIT pod.completed pod=#{Map.get(payload, "pod_id", "?")} " <>
        "issue=#{Map.get(payload, "issue_id", "?")} " <>
        "duration_ms=#{inspect(get_in(payload, ["result", "duration_ms"]) || "?")}"
    )
  end

  defp log_pod_lifecycle_event(:"pod.failed", payload) do
    Logger.warning(
      "AUDIT pod.failed pod=#{Map.get(payload, "pod_id", "?")} " <>
        "issue=#{Map.get(payload, "issue_id", "?")} " <>
        "reason=#{inspect(Map.get(payload, "reason"))}"
    )
  end
end
