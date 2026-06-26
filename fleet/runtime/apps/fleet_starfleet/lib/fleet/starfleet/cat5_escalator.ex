defmodule Fleet.Starfleet.Cat5Escalator do
  @moduledoc """
  Pure functions module pour escalade Cat 5.

  Reçoit `{source, payload}` depuis `DriftMonitor` :
    1. log audit `/var/log/fleet-starfleet.jsonl` (via `AuditLog`)
    2. broadcast `audit.cat5.<source>` sur `fleet.events`
    3. dispatch `CoordBackend.handle_escalation/2` (ch14 deferred)

  Chain trace propagation : `chain` payload étendu avec
  `"starfleet.cat5.<source>"` puis transmis au broadcast + au coord.

  ## Sources Cat 5 supportées

  Les 3 sources sont câblées de bout en bout (DriftMonitor → Cat5Escalator →
  broadcast + coord) mais leurs events d'ENTRÉE n'ont aujourd'hui aucun producteur
  live — l'escalateur est prêt, dormant tant qu'un producteur n'émet pas :

    * `:pod_drift` — sur `pod.drift` (drift_count ≥ 3). Émetteur prévu (filtre IPC
      pod-side comptant les strikes) jamais implémenté → 0 producteur.
    * `:pipeline_failed` — sur `pipeline.failed`. Producteur historique = moteur RAM
      `Fleet.Pipeline.Executor`, SUPPRIMÉ ; le rail forge-driven ne le ré-émet pas.
    * `:oauth_refresh_failed` — sur `oauth.refresh.failed`. Pas de producteur câblé.

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
  Déclenche l'escalade Cat 5 pour un `source` donné — DN 13 C2.3-starfleet
  amendement chirurgical.

  Arité étendue : `correlation_id` explicite extrait de l'event upstream
  ayant déclenché l'escalade (peut être nil hors mandat).

  Étend le `chain` payload avec `"starfleet.cat5.<source>"` puis :

    1. log audit `/var/log/fleet-starfleet.jsonl` via `AuditLog.write/1`
    2. broadcast `%Fleet.Event{source: :starfleet, type: :"starfleet.audit_cat5_pod_drift",
       correlation_id, ...}` schema canon (DN 11 C3.1+C3.2) + legacy
       `audit.cat5.<source>` compat shim
    3. dispatch `CoordBackend.handle_escalation/3` (DN 9 amendement)

  Toujours `:ok` (audit-only fail-safe : un échec d'écriture log
  n'interrompt pas le pipeline).
  """
  @spec escalate(source :: atom(), payload :: map(), correlation_id :: String.t() | nil) :: :ok
  def escalate(source, payload, correlation_id)
      when is_atom(source) and is_map(payload) do
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

    # Broadcast schema canon strict %Fleet.Event{source: :starfleet, ...}
    _ = broadcast_canon(source, enriched, correlation_id)

    _ = coord_backend().handle_escalation(source, enriched, correlation_id)
    :ok
  end

  defp broadcast_canon(source, enriched, correlation_id) do
    # to_existing_atom (pas to_atom) — anti atom-leak ; les 3 atomes
    # `starfleet.audit_cat5_<src>` sont registrés (events.yaml + préregistre
    # Starfleet.Application). Une source de type inattendue → ArgumentError → rescue.
    event =
      Fleet.Event.new(:starfleet, String.to_existing_atom("starfleet.audit_cat5_#{source}"),
        pod_id: extract_pod_id(enriched),
        correlation_id: correlation_id,
        payload: enriched
      )

    Bus.broadcast("fleet.events", event)
  rescue
    # Boot order ou type pas inscrit registry — silent (DN 11 C3.2 fail-loud
    # est appliqué chantier 3 flip strict_canon).
    _e in Fleet.Event.UnregisteredError -> :ok
    _e in [ArgumentError, FunctionClauseError] -> :ok
  end

  defp extract_pod_id(%{"pod_id" => pid}) when is_binary(pid), do: pid
  defp extract_pod_id(_), do: nil

  defp coord_backend do
    Application.get_env(
      :fleet_starfleet,
      :coord_backend,
      Fleet.Starfleet.CoordBackend.NotWiredYet
    )
  end
end
