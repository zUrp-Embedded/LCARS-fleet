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
      `Fleet.Workflow.Executor`, SUPPRIMÉ ; le rail forge-driven ne le ré-émet pas.
    * `:oauth_refresh_failed` — sur `oauth.refresh.failed`. Pas de producteur câblé.

  ## Format payload broadcast

      %{
        "source" => "pod_drift" | "workflow_map_failed" | "oauth_refresh_failed",
        "chain" => [..., "starfleet.cat5.<source>"],
        ...payload original (pod_id, drift_count, reason, etc.)
      }
  """

  alias Fleet.EventRouter.Bus
  alias Fleet.Starfleet.{AuditLog, CoordBackend}

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

    _ = CoordBackend.resolved().handle_escalation(source, enriched, correlation_id)
    :ok
  end

  # Émission via le cœur protégé `Bus.safe_emit/4` (rescue local dupliqué retiré — la politique
  # best-effort a UNE autorité, Ring 0). Le nom du type est SYNTHÉTISÉ : on passe le BINAIRE
  # `starfleet.audit_cat5_<src>` tel quel, safe_emit le convertit via `to_existing_atom` (anti
  # atom-leak — les 3 atomes sont registrés : events.yaml + préregistre Starfleet.Application)
  # SOUS son rescue. Une source inattendue (atome jamais préregistré) y est classée bug de
  # CONSTRUCTION : Logger.error puis :ok — jamais avalé muet (une escalade Cat-5, sévérité max,
  # qui disparaît en silence est indiagnosticable), jamais propagé (ce broadcast tourne synchrone
  # dans le GenServer DriftMonitor : le laisser crasher tuerait le subscriber Cat-5 et le ferait
  # boucler sur un producteur malformé, alors que l'escalade est déjà au journal d'audit).
  # UnregisteredError = boot-order toléré → `:silent`, comme avant.
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
      context: "Cat5Escalator: escalade Cat-5 NON broadcastée"
    )
  end

  defp extract_pod_id(%{"pod_id" => pid}) when is_binary(pid), do: pid
  defp extract_pod_id(_), do: nil
end
