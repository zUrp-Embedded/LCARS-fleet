defmodule Fleet.Starfleet.Cat5Escalator do
  @moduledoc """
  Executes Cat 5 escalation for sources declared by the event routing table.

  Each escalation is written to `AuditLog`, broadcast as the canonical
  `starfleet.audit_cat5_<source>` event, and dispatched to `CoordBackend`.
  The payload chain is extended with `starfleet.cat5.<source>` for both sinks.
  Unknown sources are refused loudly without producing side effects.
  """

  require Logger

  alias Fleet.EventRouter.Bus
  alias Fleet.Starfleet.{AuditLog, CoordBackend}

  @doc """
  Escalates a routed source and always returns `:ok`.
  """
  @spec escalate(source :: atom(), payload :: map(), correlation_id :: String.t() | nil) :: :ok
  def escalate(source, payload, correlation_id) when is_atom(source) and is_map(payload) do
    if source in cat5_sources() do
      do_escalate(source, payload, correlation_id)
    else
      refuse_unknown(source)
    end
  end

  defp cat5_sources do
    for {_key, %{action: :cat5, cat5_source: tag}} <- Fleet.EventRouter.Bus.event_routing(),
        do: tag
  end

  defp do_escalate(source, payload, correlation_id) do
    chain = (Map.get(payload, "chain") || []) ++ ["starfleet.cat5.#{source}"]

    enriched =
      payload
      |> Map.put("chain", chain)
      |> Map.put("source", Atom.to_string(source))

    _ =
      AuditLog.write(%{
        "source" => Atom.to_string(source),
        "chain" => chain,
        "payload" => payload,
        "action" => "cat5_escalate",
        "correlation_id" => correlation_id
      })

    _ = broadcast_canon(source, enriched, correlation_id)

    case CoordBackend.resolved().handle_escalation(source, enriched, correlation_id) do
      :ok -> :ok
      {:error, why} -> Logger.warning("Cat5Escalator: escalation NOT routed (#{inspect(why)})")
    end

    :ok
  end

  defp refuse_unknown(source) do
    Logger.error(
      "Cat5Escalator: REFUSED unknown Cat 5 source #{inspect(source)} — not among the routing " <>
        "table's cat5 tags #{inspect(cat5_sources())} (producer drift; audit_cat5_<source> would " <>
        "be unregistered)"
    )

    :ok
  end

  defp broadcast_canon(source, enriched, correlation_id) do
    Bus.safe_emit(
      :starfleet,
      "starfleet.audit_cat5_#{source}",
      [
        pod_id: extract_pod_id(enriched),
        correlation_id: correlation_id,
        payload: enriched
      ],
      on_unregistered: :silent,
      context: "Cat5Escalator: Cat-5 escalation NOT broadcast"
    )
  end

  defp extract_pod_id(%{"pod_id" => pid}) when is_binary(pid), do: pid
  defp extract_pod_id(_), do: nil
end
