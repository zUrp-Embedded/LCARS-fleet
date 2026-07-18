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

  `:"pod.drift"` handler (type-only clause): producer LIVE — `Fleet.Spawner.PermanentBoot`
  (source `:spawner`, F-C043); also consumed by DriftMonitor. `pod.refuse_pattern_match` left with the
  legacy stack (removed from the registry, 0 producer / 0 consumer).

  GenServer that subscribes at boot (init/1), dispatches via canonical `%Fleet.Event{}` clauses
  (the legacy `{atom, map}` tuple stack is RAZED — 0 producer). No runtime side effect
  beyond the log (forensics + a separate dashboard subscriber).

  Test-seam: `start_link(opts)` accepts `:subscribe` (default true)
  → tests instantiate without the global subscribe.

  **Last revised**: 2026-07-18
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

  # Legacy {atom, map} tuple stack RAZED (conformance 2026-07-04): NO producer of the tuple
  # format on the Bus anymore (verified: zero Bus.broadcast outside %Fleet.Event{}); the clauses
  # lay dormant, duplicating the logging of the canonical clauses below (boot_*, pod.completed/failed).

  # Strict canonical %Fleet.Event{} schema (task_queue lifecycle).
  @impl true
  def handle_info(%Fleet.Event{source: :task_queue, type: type} = event, state) do
    log_task_queue_event(type, event)
    {:noreply, %{state | events_count: state.events_count + 1}}
  end

  # V2 extensions (MCPWatcher + MCPMonitor).
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

  # boot_orchestrator events migrated to the canonical schema.
  def handle_info(
        %Fleet.Event{source: :starfleet, type: type, payload: payload},
        state
      )
      when type in [:"fleet.boot_complete", :"fleet.boot_partial", :"fleet.boot_failed"] do
    log_boot_event(type, payload)
    {:noreply, %{state | events_count: state.events_count + 1}}
  end

  # Pod GenServer Port stream lifecycle migrated to the canonical schema.
  def handle_info(
        %Fleet.Event{source: :spawner, type: type, payload: payload},
        state
      )
      when type in [:"pod.completed", :"pod.failed"] do
    log_pod_lifecycle_event(type, payload)
    {:noreply, %{state | events_count: state.events_count + 1}}
  end

  # git.published/git.publish_failed clause RAZED (conformance 2026-07-04): 0 producer AND, since this
  # raze, 0 consumer → both keys are now REMOVED from events.yaml too (registry-lie cleanup: a 0/0 key
  # must not linger claiming "consumer wired"). Re-add a clause here only if a producer + registry key return.

  # pod.drift: producer LIVE via `Fleet.Spawner.PermanentBoot` (source :spawner, F-C043). This
  # AuditConsumer clause stays TYPE-ONLY (audit rail, no anti-spoof), UNLIKE DriftMonitor which
  # matches source: :spawner.
  def handle_info(%Fleet.Event{type: :"pod.drift", payload: payload} = event, state) do
    Logger.warning(
      "AUDIT pod.drift pod=#{event.pod_id || Map.get(payload, "pod_id", "?")} " <>
        "count=#{inspect(Map.get(payload, "drift_count", "?"))}"
    )

    {:noreply, %{state | events_count: state.events_count + 1}}
  end

  # Ignore other unhandled %Fleet.Event{} (the audit trail is selective, not exhaustive).
  def handle_info(%Fleet.Event{}, state), do: {:noreply, state}

  def handle_info(_other, state), do: {:noreply, state}

  # task_queue lifecycle.
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
    # Clé ATOME seule : l'unique producteur (task_queue/server) émet %{reason: …} et le Bus est
    # in-process (Phoenix.PubSub, aucun round-trip JSON qui stringifierait) — un fallback
    # string-key serait de la re-validation d'une forme que la frontière garantit déjà.
    reason = Map.get(p, :reason, "?")

    Logger.warning(
      "AUDIT task_queue.work_item.failed pod=#{pid} work_item=#{tid} reason=#{inspect(reason)}"
    )
  end

  defp log_task_queue_event(:"state.corrupt", %Fleet.Event{payload: p}) do
    Logger.error("AUDIT task_queue.state.corrupt #{inspect(p)}")
  end

  defp log_task_queue_event(_other, _event), do: :ok

  # boot_orchestrator canonical schema dispatcher.
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
