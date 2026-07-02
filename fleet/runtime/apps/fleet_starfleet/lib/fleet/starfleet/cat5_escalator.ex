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
    * `:workflow_map_failed` — sur `workflow_map.failed`. Producteur historique = moteur RAM
      `Fleet.Pipeline.Executor`, SUPPRIMÉ ; le rail forge-driven ne le ré-émet pas.
    * `:oauth_refresh_failed` — sur `oauth.refresh.failed`. Pas de producteur câblé.

  ## Format payload broadcast

      %{
        "source" => "pod_drift" | "workflow_map_failed" | "oauth_refresh_failed",
        "chain" => [..., "starfleet.cat5.<source>"],
        ...payload original (pod_id, drift_count, reason, etc.)
      }
  """

  require Logger

  alias Fleet.EventRouter.Bus
  alias Fleet.Starfleet.AuditLog

  @doc """
  Déclenche l'escalade Cat 5 pour un `source` donné — DN 13 C2.3-starfleet
  amendement chirurgical.

  Arité étendue : `correlation_id` explicite extrait de l'event upstream
  ayant déclenché l'escalade (peut être nil hors work item).

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
    Bus.emit(:starfleet, String.to_existing_atom("starfleet.audit_cat5_#{source}"),
      pod_id: extract_pod_id(enriched),
      correlation_id: correlation_id,
      payload: enriched
    )
  rescue
    # UnregisteredError = boot-order toléré : le registry n'est pas encore peuplé,
    # le broadcast est rejeté, on n'en fait pas une alarme — silencieux.
    _e in Fleet.Event.UnregisteredError ->
      :ok

    # ArgumentError/FunctionClauseError = bug de CONSTRUCTION de l'event (source hors
    # enum, ou atome `starfleet.audit_cat5_<src>` jamais préregistré donc refusé par
    # to_existing_atom), PAS du boot. Ne JAMAIS l'avaler en :ok muet : ça ferait
    # disparaître en silence une escalade Cat-5 (sévérité max). On le rend VISIBLE puis
    # on neutralise — l'escalade est déjà au journal d'audit, et ce broadcast tourne
    # synchrone dans le GenServer DriftMonitor : le laisser crasher tuerait le subscriber
    # Cat-5 et le ferait boucler sur un producteur malformé.
    e in [ArgumentError, FunctionClauseError] ->
      Logger.error(
        "Cat5Escalator: escalade Cat-5 NON broadcastée — event malformé (bug de construction) : #{inspect(e)}"
      )

      :ok
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
