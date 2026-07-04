defmodule Fleet.Starfleet.AuditConsumer do
  @moduledoc """
  B10 / #583 Sprint 1 — consumer audit events lifecycle + sécurité.

  Subscribe `Fleet.EventRouter.Bus` topic `fleet.events`, log
  audit-grade pour events :
    * `:"pod.completed"` / `:"pod.failed"` — Pod GenServer Port stream lifecycle
      (producteurs réels : `Fleet.Spawner.Pod`).
    * `:"fleet.boot_complete"` / `:"fleet.boot_partial"` / `:"fleet.boot_failed"`
      — BootOrchestrator lifecycle.
    * task-queue : `:"work_item.enqueued"` / `:"work_item.assigned"` / `:"work_item.completed"` /
      `:"work_item.cleared"` / `:"work_item.failed"` / `:"state.corrupt"` (producteur `Fleet.TaskQueue`).

  Handler DORMANT unique : `:"pod.drift"` (clause canon type-only — producteur pas encore né,
  cf. events.yaml ; consommé aussi par DriftMonitor). `pod.refuse_pattern_match` est PARTI avec la
  pile legacy (retiré du registry, 0 producteur/0 consumer).

  Pattern GenServer subscribe au boot (init/1), dispatch par clauses `%Fleet.Event{}` canon
  (la pile legacy tuple `{atom, map}` est RASÉE — 0 producteur). Pas de side effect runtime
  au-delà du log (forensics + dashboard subscriber séparé).

  Test-seam : `start_link(opts)` accepte `:subscribe` (default true)
  → tests instancient sans subscribe global.
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

  # Pile legacy tuple {atom, map} RASÉE (conformité 2026-07-04) : plus AUCUN producteur du format
  # tuple sur le Bus (vérifié : zéro Bus.broadcast hors %Fleet.Event{}), les clauses dormaient en
  # dupliquant le logging des clauses canon ci-dessous (boot_*, pod.completed/failed).

  # BL-021 chantier 2d — schema canon strict %Fleet.Event{} (task_queue lifecycle).
  @impl true
  def handle_info(%Fleet.Event{source: :task_queue, type: type} = event, state) do
    log_task_queue_event(type, event)
    {:noreply, %{state | events_count: state.events_count + 1}}
  end

  # BL-021 chantier 8 — Extensions V2 (MCPWatcher + MCPMonitor).
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

  # BL-021 chantier 9 (B) — boot_orchestrator events migrés au schema canon.
  def handle_info(
        %Fleet.Event{source: :starfleet, type: type, payload: payload},
        state
      )
      when type in [:"fleet.boot_complete", :"fleet.boot_partial", :"fleet.boot_failed"] do
    log_boot_event(type, payload)
    {:noreply, %{state | events_count: state.events_count + 1}}
  end

  # BL-021 chantier 9 (B) — Pod GenServer Port stream lifecycle migré au schema canon.
  def handle_info(
        %Fleet.Event{source: :spawner, type: type, payload: payload},
        state
      )
      when type in [:"pod.completed", :"pod.failed"] do
    log_pod_lifecycle_event(type, payload)
    {:noreply, %{state | events_count: state.events_count + 1}}
  end

  # Clause git.published/git.publish_failed RASÉE (conformité 2026-07-04) : 0 producteur (events.yaml
  # les documente « à ré-émettre par le rail forge-driven si la publication git redevient observable ») ;
  # elle matchait en plus l'ancien source :pipeline (renommé :workflow au rename fleet_workflow).

  # pod.drift : migré de la pile legacy (conformité 2026-07-04). Producteur pas encore né (events.yaml :
  # « producteur manquant ») mais consommé par DriftMonitor — match type-only ALIGNÉ sur DriftMonitor
  # (le source du futur producteur n'est pas encore fixé ; on ne l'invente pas ici).
  def handle_info(%Fleet.Event{type: :"pod.drift", payload: payload} = event, state) do
    Logger.warning(
      "AUDIT pod.drift pod=#{event.pod_id || Map.get(payload, "pod_id", "?")} " <>
        "count=#{inspect(Map.get(payload, "drift_count", "?"))}"
    )

    {:noreply, %{state | events_count: state.events_count + 1}}
  end

  # Ignore les autres %Fleet.Event{} non handlés (l'audit trail est sélectif, pas exhaustif).
  def handle_info(%Fleet.Event{}, state), do: {:noreply, state}

  def handle_info(_other, state), do: {:noreply, state}

  # BL-021 chantier 2d — task_queue lifecycle (DN orchestration/task-queue §E)
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
    reason = Map.get(p, :reason) || Map.get(p, "reason") || "?"

    Logger.warning(
      "AUDIT task_queue.work_item.failed pod=#{pid} work_item=#{tid} reason=#{inspect(reason)}"
    )
  end

  defp log_task_queue_event(:"state.corrupt", %Fleet.Event{payload: p}) do
    Logger.error("AUDIT task_queue.state.corrupt #{inspect(p)}")
  end

  defp log_task_queue_event(_other, _event), do: :ok

  # BL-021 chantier 9 (B) — boot_orchestrator schema canon dispatcher.
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
        "duration_ms=#{get_in(payload, ["result", "duration_ms"]) || "?"}"
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
