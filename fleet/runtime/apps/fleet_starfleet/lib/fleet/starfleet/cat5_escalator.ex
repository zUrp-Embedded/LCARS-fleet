defmodule Fleet.Starfleet.Cat5Escalator do
  @moduledoc """
  Pure functions module pour escalade Cat 5.

  Reçoit `{source, payload}` depuis `DriftMonitor` :
    1. log audit `/var/log/fleet-starfleet.jsonl` (via `AuditLog`)
    2. broadcast `audit.cat5.<source>` sur `fleet.events`
    3. dispatch `CoordBackend.handle_escalation/2` (ch14 deferred)

  Chain trace propagation : `chain` payload étendu avec
  `"starfleet.cat5.<source>"` puis transmis au broadcast + au coord.

  ## Sources Cat 5 supportés

    * `:pod_drift` — chantier 9 PROMOTED `fleet_ipc_filter` 3 strikes
    * `:pipeline_failed` — chantier 12 PROMOTED `fleet_pipeline` gate fail
    * `:oauth_refresh_failed` — chantier 6 PROMOTED `fleet_spawner` PoC-10

  ## Format payload broadcast

      %{
        "source" => "pod_drift" | "pipeline_failed" | "oauth_refresh_failed",
        "chain" => [..., "starfleet.cat5.<source>"],
        ...payload original (pod_id, drift_count, reason, etc.)
      }
  """

  alias Fleet.EventRouter.Bus
  alias Fleet.Starfleet.AuditLog

  @doc """
  Déclenche l'escalade Cat 5 pour un `source` donné.

  Étend le `chain` payload avec `"starfleet.cat5.<source>"` puis :

    1. log audit `/var/log/fleet-starfleet.jsonl` via `AuditLog.write/1`
    2. broadcast `audit.cat5.<source>` sur `Fleet.EventRouter.Bus`
    3. dispatch `CoordBackend.handle_escalation/2` (ch14 deferred via seam)

  Toujours `:ok` (audit-only fail-safe : un échec d'écriture log
  n'interrompt pas le pipeline).
  """
  @spec escalate(source :: atom(), payload :: map()) :: :ok
  def escalate(source, payload) when is_atom(source) and is_map(payload) do
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
        "action" => "cat5_escalate"
      })

    _ =
      Bus.broadcast(
        "audit.cat5.#{source}",
        enriched,
        ticket_id: payload["ticket_id"]
      )

    _ = coord_backend().handle_escalation(source, enriched)
    :ok
  end

  defp coord_backend do
    Application.get_env(
      :fleet_starfleet,
      :coord_backend,
      Fleet.Starfleet.CoordBackend.NotWiredYet
    )
  end
end
