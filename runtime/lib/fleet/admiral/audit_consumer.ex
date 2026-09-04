defmodule Fleet.Admiral.AuditConsumer do
  @moduledoc """
  Audit consumer — events lifecycle + security.

  Subscribes to the `Fleet.EventRouter.Bus` topic `fleet.events` and logs, at audit grade, the
  lifecycle of pods, of the boot, and of the task queue. Which types exactly is the clause list
  below — a second copy here would be one more thing to keep in step with it.

  ## HALF OF THIS SURVIVES A RESTART, AND IT IS NOT THE HALF YOU WOULD ASSUME

  "Audit-grade" describes the CONTENT of these lines, never their durability. The split is by
  Logger level, and `Fleet.DurableLog` writes `warning` and above:

    * ANOMALIES are durable — `pod.failed`, `work_item.failed`, `boot_partial`, `boot_failed`.
    * THE NOMINAL TIMELINE IS NOT — `work_item.enqueued` / `assigned` / `completed` / `cleared` and
      `fleet.boot_complete` are `:info`, so they live in the daemon's console and die with it.

  The consequence, stated because it bites exactly when it is needed: after a restart a durable
  `pod.failed` cannot be tied back to the `work_item.assigned` that produced it. Anomalies are
  reconstructible; the story that led to them is not.

  Raising these to `warning` is NOT the fix and must not be done as one: `info` is the level this
  codebase assigns to a lifecycle milestone, `warning` the level at which something DEGRADED, and
  moving them would both lie about severity and bury the durable trace under routine passes — the
  reason `DurableLog` names for excluding `info` in the first place.

  A durable nominal timeline, if the fleet ever needs one, belongs in a structured ledger and not in
  a level bump: widening it is a DECISION with a schema behind it, not a patch.

  NO RUNTIME SIDE EFFECT BEYOND THE LOG — forensics, plus whatever separate subscriber a dashboard
  runs. Nothing downstream may be made to depend on this consumer having seen an event.

  Test-seam: `start_link(opts)` accepts `:subscribe` (default true) → tests instantiate without the
  global subscribe.
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

  # ⚠ CANONICAL `%Fleet.Event{}` ONLY, no tuple-format clause: every Bus producer emits the struct,
  # and a tolerant clause here would let a producer ship a shape nothing else on the Bus accepts.
  @impl true
  def handle_info(%Event{source: :task_queue, type: type} = event, state) do
    log_task_queue_event(type, event)
    {:noreply, %{state | events_count: state.events_count + 1}}
  end

  # ⚠ PAS DE HANDLER SANS EMETTEUR ICI (6-016). Quand un producteur part — la veille de derive du
  # SDK est passee en CI, cf. BL-6-44 — sa clause de consommation reste et SE LIT COMME UN RAIL
  # D'AUDIT VIVANT : une clause qu'aucun evenement n'atteint ne se distingue pas d'une clause qui
  # marche.
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

  # (Pas de clause `:"state.corrupt"` : le broker n'a pas de rail de persistance (BL-6-113), rien
  # ne peut emettre ce type et le registre d'evenements ne l'autorise pas. UNE CLAUSE QUE RIEN
  # N'ATTEINT DECRIT UN FLUX.)
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
