defmodule Fleet.Starfleet.Cat5Escalator do
  @moduledoc """
  Pure-functions module for Cat 5 escalation.

  Receives `{source, payload, correlation_id}` from `DriftMonitor`:
    1. audit-log NDJSON via `AuditLog` (default `~/.lcars/log/fleet-starfleet.jsonl`,
       knob `:fleet_starfleet, :audit_log_path`)
    2. broadcast `starfleet.audit_cat5_<source>` on `fleet.events` (canonical schema,
       via `Bus.safe_emit/4`)
    3. dispatch `CoordBackend.handle_escalation/3` (backend resolved by config,
       default `NotWiredYet` — deferred)

  Chain-trace propagation: `chain` payload extended with
  `"starfleet.cat5.<source>"` then passed to the broadcast + the coord.

  ## Supported Cat 5 sources

  All 3 sources are wired end to end (DriftMonitor → Cat5Escalator → broadcast + coord).
  Producer status (Q2 draft wiring, cf. `DriftMonitor` moduledoc — the authority):

    * `:workflow_map_failed` — on `workflow_map.failed`. **LIVE via a Q2 DRAFT producer**:
      `Pilot.StepRunConsumer` emits it on a `:workflow_map_load_failed` in the forge-driven
      rail (`step_run_consumer.ex` `emit_workflow_map_failed_draft/3`) → routed here via
      DriftMonitor. Honest-but-partial (covers the main dispatch load-failure, not every rail).
    * `:pod_drift` — on `pod.drift` (drift_count ≥ 3). LIVE (F-C043) via `Fleet.Spawner.PermanentBoot`
      (source `:spawner`), emitted on a corrupt permanent-pod base seed. (The originally-intended
      pod-side IPC strike filter is still unbuilt — a distinct producer.)
    * `:oauth_refresh_failed` — on `oauth.refresh.failed`. DORMANT: no wired producer.

  ## Broadcast payload format

      %{
        "source" => "pod_drift" | "workflow_map_failed" | "oauth_refresh_failed",
        "chain" => [..., "starfleet.cat5.<source>"],
        ...original payload (pod_id, drift_count, reason, etc.)
      }
  """

  require Logger

  alias Fleet.EventRouter.Bus
  alias Fleet.Starfleet.{AuditLog, CoordBackend}

  @doc """
  Triggers the Cat 5 escalation for a given `source`.

  Extended arity: explicit `correlation_id` extracted from the upstream event
  that triggered the escalation (may be nil outside a work item).

  Extends the `chain` payload with `"starfleet.cat5.<source>"` then:

    1. audit log via `AuditLog.write/1` (path: knob `:fleet_starfleet, :audit_log_path`)
    2. SINGLE canonical broadcast `%Fleet.Event{source: :starfleet,
       type: :"starfleet.audit_cat5_pod_drift", correlation_id, ...}` (same for the
       other two sources — type = `starfleet.audit_cat5_` + source, 3 keys registered in
       events.yaml) — the old legacy event `audit.cat5.<source>` is NO LONGER emitted
       (compat shim removed)
    3. dispatch `CoordBackend.handle_escalation/3`

  Always `:ok` (audit-only fail-safe: a log-write failure does not interrupt
  the workflow).
  """
  # Closed enum of Cat 5 sources — the ONLY 3 wired (DriftMonitor emitters + the `starfleet.audit_cat5_*`
  # keys in events.yaml). An out-of-enum source would synthesize an UNREGISTERED `audit_cat5_<source>`
  # event (broken broadcast) → escalation `escalate` must bound the source, not accept any atom.
  @cat5_sources [:pod_drift, :workflow_map_failed, :oauth_refresh_failed]

  @spec escalate(source :: atom(), payload :: map(), correlation_id :: String.t() | nil) :: :ok
  def escalate(source, payload, correlation_id)
      when source in @cat5_sources and is_map(payload) do
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

    # Broadcast strict canonical schema %Fleet.Event{source: :starfleet, ...}
    _ = broadcast_canon(source, enriched, correlation_id)

    # Same finding as DriftMonitor (DrDree 2026-07-05): an escalation-policy miss was being swallowed.
    case CoordBackend.resolved().handle_escalation(source, enriched, correlation_id) do
      :ok -> :ok
      {:error, why} -> Logger.warning("Cat5Escalator: escalation NOT routed (#{inspect(why)})")
    end

    :ok
  end

  # Out-of-enum source = a producer drift (only DriftMonitor emits, with the 3 wired sources). We do NOT
  # synthesize a broken `audit_cat5_<source>` broadcast — REFUSE loud, return `:ok` (the `@spec`; a
  # Cat 5 escalator must never itself crash a caller).
  def escalate(source, _payload, _correlation_id) when is_atom(source) do
    Logger.error(
      "Cat5Escalator: REFUSED unknown Cat 5 source #{inspect(source)} — not in " <>
        "#{inspect(@cat5_sources)} (producer drift; audit_cat5_<source> would be unregistered)"
    )

    :ok
  end

  # Emission via the protected core `Bus.safe_emit/4` (duplicated local rescue removed — the
  # protected-emission policy has ONE substrate authority). The type name is SYNTHESIZED: we pass the BINARY
  # `starfleet.audit_cat5_<src>` as-is, safe_emit converts it via `to_existing_atom` (anti
  # atom-leak — the 3 atoms are registered: events.yaml + Starfleet.Application pre-register)
  # UNDER its rescue. An unexpected source (atom never pre-registered) is classed there as a
  # CONSTRUCTION bug: Logger.error then :ok — never silently swallowed (a Cat-5 escalation, max
  # severity, vanishing in silence is undiagnosable), never propagated (this broadcast runs
  # synchronously in the DriftMonitor GenServer: letting it crash would kill the Cat-5 subscriber
  # and make it loop over a malformed producer, while the escalation is already in the audit log).
  # UnregisteredError = boot-order tolerated → `:silent`, as before.
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
