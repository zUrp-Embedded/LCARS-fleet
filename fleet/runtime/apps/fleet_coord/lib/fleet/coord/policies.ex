defmodule Fleet.Coord.Policies do
  @moduledoc """
  Pure functions module table de routage déclarative
  `{verdict, reason} → {action, escalation_path}`.

  Lookup table chargée une fois au boot via `init_policies!/0`
  depuis `priv/config/coord-policies.yaml` (ou path config) et
  persistée dans `:persistent_term` (clé
  `{__MODULE__, :policies}`). Pattern cohérent ch9 ETS read-only,
  ch11 schema cache, ch13 schema cache.

  **Aucune logique de raisonnement LLM** dans ce module
  (méta-axiome architecture-cible §L441 — soft gate + hook
  délèguent LLM via spawn pod jetable cap-profile dédié).

  ## Format `coord-policies.yaml`

      mappings:
        "halt.gatekeeper.refuse":
          action: notify_dashboard
          escalation_path: [dashboard, ticket_comment]
        "escalate.pod_drift":
          action: escalate_human
          escalation_path: [dashboard, starfleet_alert]

  ## Actions broadcastées

    * `notify_dashboard` → `coord.notify.dashboard` event
    * `escalate_human` → `coord.escalate.human` event
    * autres → `coord.action.<action>` event (extensible PR sans
      recompile)
  """

  alias Fleet.EventRouter.Bus

  @policies_key {__MODULE__, :policies}

  @doc """
  Charge les policies YAML et persiste dans `:persistent_term`.
  Fail-fast au boot si fichier absent ou YAML malformé.
  """
  @spec init_policies!() :: :ok
  def init_policies! do
    path = Application.get_env(:fleet_coord, :policies_path, default_policies_path())

    policies = YamlElixir.read_from_file!(path)
    :persistent_term.put(@policies_key, policies)
    :ok
  end

  @doc """
  Dispatch d'une décision validée Gatekeeper — DN 9 C2.3 amendement.

  Arité étendue : `correlation_id` explicite (task.id UUID v4 du mandat
  ayant produit le verdict, peut être nil hors mandat).

  Lookup `{decision, reason}` → table policies → broadcast schema canon
  `%Fleet.Event{source: :coord, type, correlation_id, …}` (DN 9 C2.1+C2.2).
  Compat shim `handle_decision/1` retiré au chantier 9 (B) BL-021.

  Returns :
    * `:ok` — policy match + broadcast effectué
    * `{:error, reason}` — pas de policy match
  """
  @spec handle_decision(
          Fleet.Starfleet.Decision.t() | map(),
          correlation_id :: String.t() | nil
        ) :: :ok | {:error, String.t()}
  def handle_decision(%{decision: decision, reason: reason} = dec, correlation_id) do
    case lookup({decision, reason}) do
      {:ok, %{"action" => action, "escalation_path" => path}} ->
        dispatch_action(action, path, dec, correlation_id)

      :not_found ->
        {:error, "no policy match for {#{decision}, #{reason}}"}
    end
  end

  @doc """
  Dispatch d'une escalade Cat 5 — DN 9 C2.3 amendement.

  Arité étendue : `correlation_id` explicite (extrait de l'event upstream
  ayant déclenché l'escalade, peut être nil hors mandat). Compat shim
  `handle_escalation/2` retiré au chantier 9 (B) BL-021.
  """
  @spec handle_escalation(
          source :: atom() | String.t(),
          payload :: map(),
          correlation_id :: String.t() | nil
        ) :: :ok | {:error, String.t()}
  def handle_escalation(source, payload, correlation_id) do
    source_str = to_string(source)

    case lookup({:escalate, source_str}) do
      {:ok, %{"action" => action, "escalation_path" => path}} ->
        dispatch_action(action, path, payload, correlation_id)

      :not_found ->
        {:error, "no escalation policy for #{source_str}"}
    end
  end

  defp lookup({verdict, reason}) do
    policies = resolved_policies()
    key = "#{verdict}.#{reason}"

    case get_in(policies, ["mappings", key]) do
      nil -> :not_found
      match -> {:ok, match}
    end
  end

  defp resolved_policies do
    case :persistent_term.get(@policies_key, nil) do
      nil ->
        raise ArgumentError,
              "Fleet.Coord.Policies: policies not loaded — appeler init_policies!/0 au boot"

      policies ->
        policies
    end
  end

  # DN 9 C2.1+C2.2 — dispatch_action arité 4 (path, payload, correlation_id).
  # Émet schema canon strict %Fleet.Event{source: :coord, type, correlation_id, ...}
  # SUR le topic "fleet.events" (DN 11 broadcast/2) ET legacy compat shim
  # broadcast/3 (chantier 3 BL-021 retire le legacy).

  defp dispatch_action("notify_dashboard", path, payload, correlation_id) do
    canon_event(:notification_routed, "dashboard", path, payload, correlation_id)
    :ok
  end

  defp dispatch_action("escalate_human", path, payload, correlation_id) do
    canon_event(:escalation_triggered, "operator", path, payload, correlation_id)
    :ok
  end

  defp dispatch_action(action, path, payload, correlation_id) when is_binary(action) do
    canon_action(action, path, payload, correlation_id)
    :ok
  end

  defp canon_event(type, target, path, payload, correlation_id) do
    event = %Fleet.Event{
      source: :coord,
      type: canon_type(type),
      timestamp: DateTime.utc_now(),
      pod_id: extract_pod_id(payload),
      correlation_id: correlation_id,
      payload: %{
        "target" => target,
        "path" => path,
        "message" => normalize_payload(payload)
      }
    }

    safe_canon_broadcast(event)
  end

  defp canon_action(action, path, payload, correlation_id) do
    event = %Fleet.Event{
      source: :coord,
      type: :action_dispatched,
      timestamp: DateTime.utc_now(),
      pod_id: extract_pod_id(payload),
      correlation_id: correlation_id,
      payload: %{
        "action" => action,
        "path" => path,
        "verdict" => extract_verdict(payload),
        "reason" => extract_reason(payload),
        "message" => normalize_payload(payload)
      }
    }

    safe_canon_broadcast(event)
  end

  defp canon_type(:notification_routed),
    do: :"coord.notification_routed"

  defp canon_type(:escalation_triggered),
    do: :"coord.escalation_triggered"

  # Broadcast canon strict — silencieux si UnregisteredError (registry pas
  # peuplé) pour ne pas casser le boot. SchemaError en revanche raise (bug
  # d'implémentation, fail-loud).
  defp safe_canon_broadcast(%Fleet.Event{} = event) do
    Bus.broadcast("fleet.events", event)
  rescue
    _e in Fleet.Event.UnregisteredError -> :ok
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

  defp default_policies_path do
    :code.priv_dir(:fleet_coord)
    |> to_string()
    |> Path.join("config/coord-policies.yaml")
  end
end
