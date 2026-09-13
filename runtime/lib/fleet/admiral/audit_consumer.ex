defmodule Fleet.Admiral.AuditConsumer do
  @moduledoc """
  Subscribes in init and logs selected lifecycle events; subscribe:false disables it
  for direct-message tests. Failed subscription prevents startup. No downstream work
  should depend on this lossy observer having received an event.

  DurableLog's warning-and-above policy excludes the nominal info timeline. Anomalies
  are eligible for persistence, not guaranteed delivered or written; after restart,
  their preceding assignments may be unavailable. Do not raise nominal severity to
  obtain persistence: a durable timeline needs a structured ledger.
  events_count includes all task_queue events, even types that produce no log.
  """

  use GenServer
  require Logger

  alias Fleet.Event
  alias Fleet.EventRouter.Bus

  @spec start_link(keyword()) :: GenServer.on_start()
  def start_link(opts \\ []) do
    name = Keyword.get(opts, :name, __MODULE__)
    GenServer.start_link(__MODULE__, opts, name: name)
  end

  @impl true
  def init(opts) do
    if Keyword.get(opts, :subscribe, true), do: :ok = Bus.subscribe()
    {:ok, %{events_count: 0}}
  end

  @impl true
  def handle_info(%Event{source: :task_queue, type: type} = event, state) do
    log_task_queue_event(type, event)
    {:noreply, %{state | events_count: state.events_count + 1}}
  end

  # Keep audited families tied to live producers; retired producers leave misleading handlers.
  def handle_info(
        %Event{source: :admiral, type: :"mcp.server_crashed", payload: p},
        state
      ) do
    Logger.error(
      "AUDIT admiral.mcp.server_crashed target=#{inspect(Map.get(p, "target"))} " <>
        "previous=#{inspect(Map.get(p, "previous_status"))} " <>
        "new=#{inspect(Map.get(p, "new_status"))}"
    )

    {:noreply, %{state | events_count: state.events_count + 1}}
  end

  def handle_info(
        %Event{source: :admiral, type: type, payload: payload},
        state
      )
      when type in [:"fleet.boot_complete", :"fleet.boot_partial", :"fleet.boot_failed"] do
    log_boot_event(type, payload)
    {:noreply, %{state | events_count: state.events_count + 1}}
  end

  def handle_info(
        %Event{source: :spawner, type: type, payload: payload},
        state
      )
      when type in [:"pod.completed", :"pod.failed"] do
    log_pod_lifecycle_event(type, payload)
    {:noreply, %{state | events_count: state.events_count + 1}}
  end

  def handle_info(%Event{}, state), do: {:noreply, state}

  def handle_info(_other, state), do: {:noreply, state}

  defp log_task_queue_event(:"work_item.enqueued", %Event{pod_id: pid, correlation_id: tid}) do
    Logger.info("AUDIT task_queue.work_item.enqueued pod=#{pid} work_item=#{tid}")
  end

  defp log_task_queue_event(:"work_item.assigned", %Event{pod_id: pid, correlation_id: tid}) do
    Logger.info("AUDIT task_queue.work_item.assigned pod=#{pid} work_item=#{tid}")
  end

  defp log_task_queue_event(:"work_item.completed", %Event{pod_id: pid, correlation_id: tid}) do
    Logger.info("AUDIT task_queue.work_item.completed pod=#{pid} work_item=#{tid}")
  end

  defp log_task_queue_event(:"work_item.cleared", %Event{pod_id: pid, correlation_id: tid}) do
    Logger.info("AUDIT task_queue.work_item.cleared pod=#{pid} work_item=#{tid}")
  end

  defp log_task_queue_event(:"work_item.failed", %Event{
         pod_id: pid,
         correlation_id: tid,
         payload: p
       }) do
    reason = Map.get(p, :reason, "?")

    Logger.warning(
      "AUDIT task_queue.work_item.failed pod=#{pid} work_item=#{tid} reason=#{inspect(reason)}"
    )
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
