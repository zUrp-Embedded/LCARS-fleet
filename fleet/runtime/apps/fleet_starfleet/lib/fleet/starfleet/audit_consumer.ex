defmodule Fleet.Starfleet.AuditConsumer do
  @moduledoc """
  B10 / #583 Sprint 1 — consumer audit events lifecycle + sécurité.

  Subscribe `Fleet.EventRouter.Bus` topic `fleet.events`, log
  audit-grade pour events :
    * `:"pod.refuse_pattern_match"` — REFUSE_PATTERNS hit (ipc_filter)
    * `:"pod.drift"` — pod drift threshold reached
    * `:"fleet.boot_complete"` / `:"fleet.boot_partial"` / `:"fleet.boot_failed"`
      — BootOrchestrator lifecycle (Sprint 1).
    * `:"pod.completed"` / `:"pod.failed"` / `:"pod.terminated"`
      — Pod GenServer Port stream lifecycle (#593 D11).

  Pattern GenServer subscribe au boot (init/1), `handle_info({atom,
  event}, state)` dispatch par atome. Pas de side effect runtime
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
    if Keyword.get(opts, :subscribe, true), do: Bus.subscribe()
    {:ok, %{events_count: 0}}
  end

  @impl true
  def handle_info({event_atom, event}, state)
      when is_atom(event_atom) and is_map(event) do
    log_event(event_atom, event)
    {:noreply, %{state | events_count: state.events_count + 1}}
  end

  # BL-021 chantier 2d — schema canon strict %Fleet.Event{} (task_queue lifecycle).
  def handle_info(%Fleet.Event{source: :task_queue, type: type} = event, state) do
    log_task_queue_event(type, event)
    {:noreply, %{state | events_count: state.events_count + 1}}
  end

  # BL-021 chantier 8 — Extensions V2 (MCPWatcher + MCPMonitor).
  def handle_info(
        %Fleet.Event{source: :starfleet, type: :sdk_upstream_alert, payload: p},
        state
      ) do
    Logger.warning(
      "AUDIT starfleet.sdk_upstream_alert package=#{inspect(Map.get(p, "package"))} " <>
        "current=#{inspect(Map.get(p, "current"))} " <>
        "upstream=#{inspect(Map.get(p, "upstream"))}"
    )

    {:noreply, %{state | events_count: state.events_count + 1}}
  end

  def handle_info(
        %Fleet.Event{source: :starfleet, type: :mcp_server_crashed, payload: p},
        state
      ) do
    Logger.error(
      "AUDIT starfleet.mcp_server_crashed target=#{inspect(Map.get(p, "target"))} " <>
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
      when type in [:"pod.completed", :"pod.failed", :"pod.terminated"] do
    log_pod_lifecycle_event(type, payload)
    {:noreply, %{state | events_count: state.events_count + 1}}
  end

  # BL-021 chantier 9 (B) — pipeline git.published / git.publish_failed migrés au schema canon.
  def handle_info(
        %Fleet.Event{source: :pipeline, type: type, payload: payload},
        state
      )
      when type in [:"git.published", :"git.publish_failed"] do
    log_git_event(type, payload)
    {:noreply, %{state | events_count: state.events_count + 1}}
  end

  # Ignore les autres %Fleet.Event{} non handlés (cohabitation dual stack).
  def handle_info(%Fleet.Event{}, state), do: {:noreply, state}

  def handle_info(_other, state), do: {:noreply, state}

  defp log_event(:"pod.refuse_pattern_match", event) do
    payload = Map.get(event, "payload", %{})

    Logger.warning(
      "AUDIT pod.refuse_pattern_match pod=#{Map.get(event, "pod_id", "?")} " <>
        "ticket=#{Map.get(event, "ticket_id", "?")} " <>
        "pattern=#{inspect(Map.get(payload, "pattern", "?"))}"
    )
  end

  defp log_event(:"pod.drift", event) do
    payload = Map.get(event, "payload", %{})

    Logger.warning(
      "AUDIT pod.drift pod=#{Map.get(event, "pod_id", "?")} " <>
        "count=#{inspect(Map.get(payload, "drift_count", "?"))}"
    )
  end

  defp log_event(:"fleet.boot_complete", event) do
    payload = Map.get(event, "payload", %{})
    Logger.info("AUDIT fleet.boot_complete #{inspect(payload)}")
  end

  defp log_event(:"fleet.boot_partial", event) do
    payload = Map.get(event, "payload", %{})
    Logger.warning("AUDIT fleet.boot_partial #{inspect(payload)}")
  end

  defp log_event(:"fleet.boot_failed", event) do
    payload = Map.get(event, "payload", %{})
    Logger.error("AUDIT fleet.boot_failed #{inspect(payload)}")
  end

  # #593 D11 — Pod GenServer Port stream lifecycle (post-init).
  defp log_event(:"pod.completed", event) do
    payload = Map.get(event, "payload", %{})

    Logger.info(
      "AUDIT pod.completed pod=#{Map.get(payload, "pod_id", "?")} " <>
        "ticket=#{Map.get(payload, "ticket_id", "?")} " <>
        "duration_ms=#{get_in(payload, ["result", "duration_ms"]) || "?"}"
    )
  end

  defp log_event(:"pod.failed", event) do
    payload = Map.get(event, "payload", %{})

    Logger.warning(
      "AUDIT pod.failed pod=#{Map.get(payload, "pod_id", "?")} " <>
        "ticket=#{Map.get(payload, "ticket_id", "?")} " <>
        "result=#{inspect(Map.get(payload, "result"))}"
    )
  end

  defp log_event(:"pod.terminated", event) do
    payload = Map.get(event, "payload", %{})

    Logger.info(
      "AUDIT pod.terminated pod=#{Map.get(payload, "pod_id", "?")} " <>
        "exit_code=#{Map.get(payload, "exit_code", "?")} " <>
        "had_result=#{Map.get(payload, "had_result", "?")}"
    )
  end

  defp log_event(_other, _event), do: :ok

  # BL-021 chantier 2d — task_queue lifecycle (DN orchestration/task-queue §E)
  defp log_task_queue_event(:task_enqueued, %Fleet.Event{pod_id: pid, correlation_id: tid}) do
    Logger.info("AUDIT task_queue.task_enqueued pod=#{pid} task=#{tid}")
  end

  defp log_task_queue_event(:task_assigned, %Fleet.Event{pod_id: pid, correlation_id: tid}) do
    Logger.info("AUDIT task_queue.task_assigned pod=#{pid} task=#{tid}")
  end

  defp log_task_queue_event(:task_completed, %Fleet.Event{pod_id: pid, correlation_id: tid}) do
    Logger.info("AUDIT task_queue.task_completed pod=#{pid} task=#{tid}")
  end

  defp log_task_queue_event(:task_cleared, %Fleet.Event{pod_id: pid, correlation_id: tid}) do
    Logger.info("AUDIT task_queue.task_cleared pod=#{pid} task=#{tid}")
  end

  defp log_task_queue_event(:task_failed, %Fleet.Event{
         pod_id: pid,
         correlation_id: tid,
         payload: p
       }) do
    reason = Map.get(p, :reason) || Map.get(p, "reason") || "?"

    Logger.warning(
      "AUDIT task_queue.task_failed pod=#{pid} task=#{tid} reason=#{inspect(reason)}"
    )
  end

  defp log_task_queue_event(:state_corrupt, %Fleet.Event{payload: p}) do
    Logger.error("AUDIT task_queue.state_corrupt #{inspect(p)}")
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
        "ticket=#{Map.get(payload, "ticket_id", "?")} " <>
        "duration_ms=#{get_in(payload, ["result", "duration_ms"]) || "?"}"
    )
  end

  defp log_pod_lifecycle_event(:"pod.failed", payload) do
    Logger.warning(
      "AUDIT pod.failed pod=#{Map.get(payload, "pod_id", "?")} " <>
        "ticket=#{Map.get(payload, "ticket_id", "?")} " <>
        "reason=#{inspect(Map.get(payload, "reason"))}"
    )
  end

  defp log_pod_lifecycle_event(:"pod.terminated", payload) do
    Logger.info(
      "AUDIT pod.terminated pod=#{Map.get(payload, "pod_id", "?")} " <>
        "exit_code=#{Map.get(payload, "exit_code", "?")}"
    )
  end

  defp log_git_event(:"git.published", payload) do
    Logger.info(
      "AUDIT git.published pipeline=#{Map.get(payload, "pipeline_id", "?")} " <>
        "sha=#{Map.get(payload, "commit_sha", "?")}"
    )
  end

  defp log_git_event(:"git.publish_failed", payload) do
    Logger.warning(
      "AUDIT git.publish_failed pipeline=#{Map.get(payload, "pipeline_id", "?")} " <>
        "reason=#{inspect(Map.get(payload, "reason"))}"
    )
  end
end
