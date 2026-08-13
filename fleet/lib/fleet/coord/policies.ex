defmodule Fleet.Coord.Policies do
  @moduledoc """
  Declarative routing table `{verdict, reason} → {action, escalation_path}`.

  `init_policies!/0` validates the configured YAML and publishes it to
  `:persistent_term`. The schema validates structure while leaving action and path
  vocabularies open for generic dispatch.

      mappings:
        "halt.gatekeeper.refuse":
          action: notify_dashboard
          escalation_path: [dashboard, issue_comment]

  Matching entries are emitted through `Fleet.Coord.Emitter`; this module performs
  no inference.
  """

  alias Fleet.Coord.Emitter
  alias Fleet.Decision

  @policies_key {__MODULE__, :policies}

  require Logger

  @doc """
  Reloads and validates the configured YAML, then replaces the boot-time table.

  Missing, unreadable, malformed, or schema-invalid input raises before the
  existing table is replaced.
  """
  @spec init_policies!() :: :ok
  def init_policies! do
    path = Application.get_env(:lcars_fleet, :coord_policies_path, default_policies_path())

    policies =
      case YamlElixir.read_from_file(path) do
        {:ok, %{} = data} ->
          validate_against_schema!(data, path)
          data

        {:ok, other} ->
          raise "fleet_coord: policies #{path} malformed (not a map: #{inspect(other)}) — " <>
                  "broken deploy, fail-loud at boot (check LCARS_COORD_POLICIES_PATH)"

        {:error, reason} ->
          raise "fleet_coord: policies #{path} missing/unreadable (#{inspect(reason)}) — " <>
                  "broken deploy, fail-loud at boot (check LCARS_COORD_POLICIES_PATH)"
      end

    :persistent_term.put(@policies_key, policies)
    :ok
  end

  defp validate_against_schema!(data, path) do
    schema_path =
      :code.priv_dir(:lcars_fleet)
      |> to_string()
      |> Path.join("coord/schema/coord-policies-v1.json")

    schema =
      Fleet.SchemaCache.resolve_json_schema!({__MODULE__, :schema, schema_path}, schema_path)

    case ExJsonSchema.Validator.validate(schema, data) do
      :ok ->
        :ok

      {:error, errors} ->
        raise "fleet_coord: policies #{path} INVALID vs coord-policies-v1.json (#{inspect(errors)}) — " <>
                "broken deploy, fail-loud at boot (check LCARS_COORD_POLICIES_PATH)"
    end
  end

  @doc """
  Dispatches a validated decision through the matching policy.

  `:ok` means a policy matched; emission is lossy. Raw maps are rejected with
  `:invalid_decision`, and missing entries return `:no_policy_match`.
  """
  @spec handle_decision(
          Fleet.Decision.t(),
          correlation_id :: String.t() | nil
        ) ::
          :ok | {:error, {:no_policy_match, {term(), term()}} | {:invalid_decision, term()}}
  def handle_decision(%Decision{decision: decision, reason: reason} = dec, correlation_id) do
    case lookup({decision, reason}) do
      {:ok, %{"action" => action, "escalation_path" => path}} ->
        Emitter.dispatch_action(action, path, dec, correlation_id)

      :not_found ->
        {:error, {:no_policy_match, {decision, reason}}}
    end
  end

  def handle_decision(other, _correlation_id), do: {:error, {:invalid_decision, other}}

  @doc """
  Dispatches a Cat-5 escalation through the policy for its string-normalized source.

  `:ok` means a policy matched; emission is lossy.
  """
  @spec handle_escalation(
          source :: atom() | String.t(),
          payload :: map(),
          correlation_id :: String.t() | nil
        ) :: :ok | {:error, {:no_escalation_policy, String.t()}}
  def handle_escalation(source, payload, correlation_id) do
    source_str = to_string(source)

    case lookup({:escalate, source_str}) do
      {:ok, %{"action" => action, "escalation_path" => path}} ->
        Emitter.dispatch_action(action, path, payload, correlation_id)

      :not_found ->
        {:error, {:no_escalation_policy, source_str}}
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
    Fleet.SchemaCache.fetch!(@policies_key, "Fleet.Coord.Policies.init_policies!/0")
  end

  defp default_policies_path, do: Fleet.Catalogue.coord_policies_path()
end
