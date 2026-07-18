defmodule Fleet.Coord.Emitter do
  @moduledoc """
  EMISSION pass of fleet_coord: translates a policy MATCH
  (`{action, escalation_path}` returned by the `Fleet.Coord.Policies` table)
  into a canonical `%Fleet.Event{source: :coord}` and broadcasts it on
  `fleet.events`.

  Split out of `Policies` (2026-07-05): the table lookup
  (load/validate/query the YAML) and the build+broadcast of a wire event are
  two distinct passes that share NO helper — the table knows nothing of the
  event schema, the emission never reads the table. `Policies` stays the
  public entry (`handle_decision`/`handle_escalation`) and calls
  `dispatch_action/4` with the match it found.

  ## Actions → events (payload = the original decision/escalation, normalized)

    * `"notify_dashboard"` → `coord.notification_routed` (target `"dashboard"`)
    * `"escalate_human"` → `coord.escalation_triggered` (target `"operator"`)
    * any other action string → `coord.action_dispatched` (action in the
      payload — extensible without recompile; the `coord.` prefix is
      mandatory: a bare type would be outside the registry → broadcast
      rejected → silent drop)

  ## Broadcast policy (fire-and-forget, never blocking)

  Via the protected core `Bus.safe_emit/4` (the substrate authority of this
  policy): `UnregisteredError` (registry not yet populated at boot order)
  tolerated in SILENCE so as not to break the boot — fire-and-forget; a
  MALFORMED event (build bug) is logged ERROR by safe_emit then neutralized —
  coord must not crash on an observability defect. A `{:error, _}` PubSub
  return passes THROUGH `safe_emit` (its passthrough contract) and is LOGGED
  warning here (`safe_canon_broadcast`): nothing re-derives the lost
  notification — the escalation's durable trace, when there is one, is the
  upstream starfleet audit log (`Cat5Escalator` writes it BEFORE dispatching
  here), not this event. The `correlation_id`
  (task.id UUID of the original work item, nil outside a work item) is
  propagated on every broadcast to tie the event back to its work item.

  **Last revised**: 2026-07-18
  """

  require Logger

  alias Fleet.EventRouter.Bus

  @doc """
  Emits the canonical event corresponding to `action` (cf. moduledoc
  § Actions). `path` = the policy's `escalation_path` (relayed as-is into the
  payload); `payload` = the decision (`%Fleet.Decision{}`/map) or the
  original escalation payload — normalized into a map, from which we extract
  `pod_id`/`verdict`/`reason` (atom OR string keys); `correlation_id`
  propagated on the broadcast.

  ALWAYS returns `:ok` (fire-and-forget broadcast — cf. moduledoc § Policy): the
  dispatch's success is the LOOKUP's success (returned by `Policies`), not the
  observability's.
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
    # Registry key = `coord.action_dispatched` (coord prefix, consistent with
    # coord.notification_routed/escalation_triggered). A bare `:action_dispatched`
    # would be outside the registry → broadcast rejected (UnregisteredError) → silent drop.
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

  # Strict canonical broadcast (source :coord) via the protected core `Bus.safe_emit/4` — the
  # protected-emission policy has ONE substrate authority). `:silent`: UnregisteredError tolerated without
  # noise (boot order); malformed event logged ERROR by safe_emit then neutralized (cf. moduledoc).
  # A PubSub `{:error, _}` passes THROUGH safe_emit unlogged (its passthrough contract) — logged
  # HERE: a lost coord event (escalation_triggered / notification_routed) has NO re-derive rail;
  # the only durable trace is the upstream Cat5 audit log, and only on the escalation path.
  defp safe_canon_broadcast(type, opts) do
    case Bus.safe_emit(:coord, type, opts,
           on_unregistered: :silent,
           context: "Coord.Emitter: action NOT broadcast"
         ) do
      :ok ->
        :ok

      {:error, reason} ->
        Logger.warning(
          "Emitter: coord event #{inspect(type)} NOT broadcast (#{inspect(reason)}) — " <>
            "notification lost, no re-derive rail (durable trace = Cat5 audit log, escalation path only)"
        )

        :ok
    end
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
