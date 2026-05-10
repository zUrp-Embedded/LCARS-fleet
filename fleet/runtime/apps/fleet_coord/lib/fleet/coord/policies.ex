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
  Dispatch d'une décision validée Gatekeeper (ch13).

  Lookup `{decision, reason}` → table policies → broadcast
  `coord.action.<action>` event sur `Fleet.EventRouter.Bus`.

  Returns :
    * `:ok` — policy match + broadcast effectué
    * `{:error, reason}` — pas de policy match
  """
  @spec handle_decision(Fleet.Starfleet.Decision.t() | map()) ::
          :ok | {:error, String.t()}
  def handle_decision(%{decision: decision, reason: reason} = dec) do
    case lookup({decision, reason}) do
      {:ok, %{"action" => action, "escalation_path" => path}} ->
        dispatch_action(action, path, dec)

      :not_found ->
        {:error, "no policy match for {#{decision}, #{reason}}"}
    end
  end

  @doc """
  Dispatch d'une escalade Cat 5 (ch13 Cat5Escalator).

  Lookup `{:escalate, source}` → table policies → broadcast
  `coord.action.<action>` event.

  Returns `:ok` ou `{:error, reason}` (idem `handle_decision/1`).
  """
  @spec handle_escalation(source :: atom() | String.t(), payload :: map()) ::
          :ok | {:error, String.t()}
  def handle_escalation(source, payload) do
    source_str = to_string(source)

    case lookup({:escalate, source_str}) do
      {:ok, %{"action" => action, "escalation_path" => path}} ->
        dispatch_action(action, path, payload)

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

  defp dispatch_action("notify_dashboard", path, payload) do
    Bus.broadcast(
      "coord.notify.dashboard",
      %{"path" => path, "payload" => normalize_payload(payload)},
      []
    )

    :ok
  end

  defp dispatch_action("escalate_human", path, payload) do
    Bus.broadcast(
      "coord.escalate.human",
      %{"path" => path, "payload" => normalize_payload(payload)},
      []
    )

    :ok
  end

  defp dispatch_action(action, path, payload) when is_binary(action) do
    Bus.broadcast(
      "coord.action.#{action}",
      %{"path" => path, "payload" => normalize_payload(payload)},
      []
    )

    :ok
  end

  defp normalize_payload(%_{} = struct), do: Map.from_struct(struct)
  defp normalize_payload(map) when is_map(map), do: map
  defp normalize_payload(other), do: %{"raw" => inspect(other)}

  defp default_policies_path do
    :code.priv_dir(:fleet_coord)
    |> to_string()
    |> Path.join("config/coord-policies.yaml")
  end
end
