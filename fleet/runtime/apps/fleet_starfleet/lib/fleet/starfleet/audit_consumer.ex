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
end
