defmodule Fleet.Coord.Emitter do
  @moduledoc """
  Converts coordination actions into canonical `%Fleet.Event{source: :coord}` events.

  `notify_dashboard` and `escalate_human` have dedicated event types; other
  action strings use `coord.action_dispatched`. Emission is lossy and always
  returns `:ok`; `Bus.safe_emit/4` logs malformed or undeliverable events.
  """

  require Logger

  alias Fleet.EventRouter.Bus

  @doc """
  Emits the event for an action, relaying its path, payload, and correlation ID.

  Returns `:ok` regardless of delivery because this channel is fire-and-forget.
  """
  @spec dispatch_action(String.t(), term(), term(), String.t() | nil) :: :ok
  def dispatch_action("notify_dashboard", path, payload, correlation_id) do
    _ = canon_event(:notification_routed, "dashboard", path, payload, correlation_id)
    :ok
  end

  def dispatch_action("escalate_human", path, payload, correlation_id) do
    _ = canon_event(:escalation_triggered, "operator", path, payload, correlation_id)
    :ok
  end

  def dispatch_action(action, path, payload, correlation_id) when is_binary(action) do
    _ = canon_action(action, path, payload, correlation_id)
    :ok
  end

  defp canon_event(type, target, path, payload, correlation_id) do
    safe_canon_broadcast(canon_type(type),
      pod_id: extract_pod_id(payload),
      correlation_id: correlation_id,
      payload: %{
        "target" => target,
        "path" => path,
        "message" => normalize_payload(payload)
      }
    )
  end

  defp canon_action(action, path, payload, correlation_id) do
    safe_canon_broadcast(:"coord.action_dispatched",
      pod_id: extract_pod_id(payload),
      correlation_id: correlation_id,
      payload: %{
        "action" => action,
        "path" => path,
        "verdict" => extract_verdict(payload),
        "reason" => extract_reason(payload),
        "message" => normalize_payload(payload)
      }
    )
  end

  defp canon_type(:notification_routed),
    do: :"coord.notification_routed"

  defp canon_type(:escalation_triggered),
    do: :"coord.escalation_triggered"

  # CI-09
  defp safe_canon_broadcast(type, opts) do
    _ =
      Bus.safe_emit(:coord, type, opts,
        on_unregistered: :silent,
        context:
          "Coord.Emitter: coord event NOT broadcast (notification lost, no re-derive rail; " <>
            "durable trace = Cat5 audit log, escalation path only)"
      )

    :ok
  end

  defp extract_pod_id(%{pod_id: pid}) when is_binary(pid), do: pid
  defp extract_pod_id(%{"pod_id" => pid}) when is_binary(pid), do: pid
  defp extract_pod_id(_), do: nil

  defp extract_verdict(%{decision: d}) when is_binary(d), do: d
  defp extract_verdict(%{"decision" => d}) when is_binary(d), do: d
  defp extract_verdict(_), do: nil

  defp extract_reason(%{reason: r}) when is_binary(r), do: r
  defp extract_reason(%{"reason" => r}) when is_binary(r), do: r
  defp extract_reason(_), do: nil

  defp normalize_payload(%_{} = struct), do: Map.from_struct(struct)
  defp normalize_payload(map) when is_map(map), do: map
  defp normalize_payload(other), do: %{"raw" => inspect(other)}
end
