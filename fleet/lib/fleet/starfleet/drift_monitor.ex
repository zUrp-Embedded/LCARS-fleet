defmodule Fleet.Starfleet.DriftMonitor do
  @moduledoc """
  Routes `fleet.events` through the declarative table loaded from `events.yaml`.

  The `{source, type}` key enforces source matching. Cat 5 routes pass through
  `Cat5Escalator`; decision routes are validated by `Gatekeeper` before reaching
  `CoordBackend`. Thresholds come from the table and counters from each payload;
  absent or non-integer counters count as zero.
  """

  use GenServer

  require Logger

  alias Fleet.EventRouter.Bus
  alias Fleet.Starfleet.{AuditLog, Cat5Escalator, CoordBackend, Gatekeeper}

  @spec start_link(keyword()) :: GenServer.on_start()
  def start_link(opts \\ []) do
    GenServer.start_link(__MODULE__, opts, name: Keyword.get(opts, :name, __MODULE__))
  end

  @impl GenServer
  def init(opts) do
    if Keyword.get(opts, :subscribe, true), do: :ok = Bus.subscribe()
    {:ok, nil}
  end

  @impl GenServer
  def handle_info(
        %Fleet.Event{source: source, type: type, payload: payload, correlation_id: cid},
        state
      ) do
    case Map.get(Fleet.EventRouter.Bus.event_routing(), {source, type}) do
      %{action: :cat5, cat5_source: tag, threshold: threshold} ->
        if meets_threshold?(payload, threshold), do: Cat5Escalator.escalate(tag, payload, cid)

      %{action: :coord_decision} ->
        dispatch_audit_verdict(payload, cid)

      _ ->
        :ok
    end

    {:noreply, state}
  end

  def handle_info(_msg, state), do: {:noreply, state}

  defp meets_threshold?(_payload, nil), do: true

  defp meets_threshold?(payload, %{counter: counter, min: min}),
    do: counter_value(payload, counter) >= min

  defp dispatch_audit_verdict(payload, correlation_id) do
    case Gatekeeper.validate(payload["decision_json"] || "") do
      {:ok, decision} ->
        case CoordBackend.resolved().handle_decision(decision, correlation_id) do
          :ok -> :ok
          {:error, why} -> Logger.warning("DriftMonitor: verdict NOT routed (#{inspect(why)})")
        end

      {:error, reason} ->
        # AuditLog values must remain JSON-encodable.
        _ =
          AuditLog.write(%{
            "source" => "invalid_decision",
            "reason" => inspect(reason),
            "raw" => payload,
            "correlation_id" => correlation_id
          })

        Logger.warning("DriftMonitor: invalid audit.verdict — #{inspect(reason)}")
    end
  end

  defp counter_value(payload, counter) do
    case Map.get(payload, counter) do
      n when is_integer(n) -> n
      _ -> 0
    end
  end
end
