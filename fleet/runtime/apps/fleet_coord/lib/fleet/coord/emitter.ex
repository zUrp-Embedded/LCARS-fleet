defmodule Fleet.Coord.Emitter do
  @moduledoc """
  Passe d'ÉMISSION de fleet_coord : traduit un MATCH de policy
  (`{action, escalation_path}` rendu par la table `Fleet.Coord.Policies`)
  en `%Fleet.Event{source: :coord}` canon et le broadcaste sur `fleet.events`.

  Extrait de `Policies` (éclatement C4 2026-07-05) : le lookup de table
  (charger/valider/interroger le YAML) et la construction+broadcast d'un event
  wire sont deux passes distinctes qui ne partagent AUCUN helper — la table ne
  sait rien du schema d'event, l'émission ne lit jamais la table. `Policies`
  reste l'entrée publique (`handle_decision`/`handle_escalation`) et appelle
  `dispatch_action/4` avec le match trouvé.

  ## Actions → events (payload = la décision/escalade d'origine, normalisée)

    * `"notify_dashboard"` → `coord.notification_routed` (target `"dashboard"`)
    * `"escalate_human"` → `coord.escalation_triggered` (target `"operator"`)
    * toute autre action string → `coord.action_dispatched` (action en
      payload — extensible sans recompile ; préfixe `coord.` obligatoire :
      un type nu serait hors registry → broadcast rejeté → drop silencieux)

  ## Politique de broadcast (best-effort, jamais bloquant)

  Via le cœur protégé `Bus.safe_emit/4` (l'autorité Ring 0 de cette politique) :
  `UnregisteredError` (registry pas encore peuplé au boot order) toléré en
  SILENCE pour ne pas casser le boot — fire-and-forget ; un event MALFORMÉ
  (bug de construction) est loggé ERROR par safe_emit puis neutralisé — coord
  ne doit pas crasher sur un défaut d'observabilité. Le `correlation_id`
  (task.id UUID du work item d'origine, nil hors work item) est propagé sur
  chaque broadcast pour relier l'event à son work item.
  """

  alias Fleet.EventRouter.Bus

  @doc """
  Émet l'event canon correspondant à `action` (cf. moduledoc § Actions).
  `path` = `escalation_path` de la policy (relayé tel quel en payload) ;
  `payload` = la décision (`%Fleet.Starfleet.Decision{}`/map) ou le payload
  d'escalade d'origine — normalisé en map, dont on extrait `pod_id`/`verdict`/
  `reason` (clés atom OU string) ; `correlation_id` propagé sur le broadcast.

  Rend TOUJOURS `:ok` (broadcast best-effort — cf. moduledoc § Politique) :
  le succès du dispatch est le succès du LOOKUP (rendu par `Policies`), pas
  celui de l'observabilité.
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
    # Clé registry = `coord.action_dispatched` (préfixe coord, cohérent avec
    # coord.notification_routed/escalation_triggered). Un `:action_dispatched` nu
    # serait hors registry → broadcast rejeté (UnregisteredError) → drop silencieux.
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

  # Broadcast canon strict (source :coord) via le cœur protégé `Bus.safe_emit/4` — la politique
  # best-effort a UNE autorité (Ring 0). `:silent` : UnregisteredError toléré sans bruit (boot
  # order) ; event malformé loggé ERROR par safe_emit puis neutralisé (cf. moduledoc).
  defp safe_canon_broadcast(type, opts) do
    Bus.safe_emit(:coord, type, opts,
      on_unregistered: :silent,
      context: "Coord.Emitter: action NON broadcastée"
    )
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
