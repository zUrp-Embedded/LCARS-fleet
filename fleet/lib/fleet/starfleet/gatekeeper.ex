defmodule Fleet.Starfleet.Gatekeeper do
  @moduledoc """
  ⚠ **Named after a role, and not about it.** This is the DECISION VALIDATOR: it checks the JSON any
  arbitration pod returns, which today includes the gatekeeper and is not limited to it (see the
  first sentence below — it already said so). The role name here is inherited, like its parent
  domain's (BL-6-53).

  Pure functions validating a pod gatekeeper's (or other arbitration
  pod's) decision JSON.

  Frozen pattern: JSON output
  `{decision, reason, details, chain?}`. Strict schema
  `priv/starfleet/schema/decision-v1.json`, `ex_json_schema` validation at load,
  fail-fast.

  ## Schema cache

  Schema resolved **once** at boot via
  `Fleet.Starfleet.Application.init/1` → `init_schema!/0`, delegated to
  the foundation authority `Fleet.SchemaCache` (`:persistent_term` cache, key
  `{__MODULE__, :decision_schema}`) — the read+decode+resolve
  pipeline has ONE authority, never a local copy.

  ## Public API

      iex> {:ok, %Fleet.Decision{decision: "halt"}} =
      ...>   Fleet.Starfleet.Gatekeeper.validate(
      ...>     ~s|{"decision":"halt","reason":"poc","details":{},"chain":["test"]}|
      ...>   )
  """

  alias Fleet.Decision

  @schema_key {__MODULE__, :decision_schema}

  @doc """
  Parses and validates a decision.

  Returns `{:ok, %Decision{}}` or `{:error, {:decision_invalid, cause}}`.
  Raises if `init_schema!/0` has not loaded the schema.
  """
  @max_decision_bytes 262_144

  @spec validate(String.t()) ::
          {:ok, Decision.t()} | {:error, {:decision_invalid, term()}}
  def validate(json_text)
      when is_binary(json_text) and byte_size(json_text) > @max_decision_bytes do
    {:error, {:decision_invalid, {:too_large, byte_size(json_text)}}}
  end

  def validate(json_text) when is_binary(json_text) do
    schema = resolved_schema()

    with {:ok, parsed} <- Jason.decode(json_text),
         :ok <- ExJsonSchema.Validator.validate(schema, parsed) do
      {:ok,
       %Decision{
         decision: parsed["decision"],
         reason: parsed["reason"],
         details: parsed["details"],
         chain: parsed["chain"] || []
       }}
    else
      {:error, reason} ->
        {:error, {:decision_invalid, reason}}
    end
  end

  @doc """
  Loads and caches the decision schema. Raises if it is absent or malformed.
  """
  @spec init_schema!() :: :ok
  def init_schema! do
    schema_path =
      Application.get_env(
        :lcars_fleet,
        :starfleet_decision_schema_path,
        default_schema_path()
      )

    _ = Fleet.SchemaCache.resolve_json_schema!(@schema_key, schema_path)
    :ok
  end

  defp resolved_schema do
    Fleet.SchemaCache.fetch!(@schema_key, "Fleet.Starfleet.Gatekeeper.init_schema!/0")
  end

  defp default_schema_path do
    :code.priv_dir(:lcars_fleet)
    |> to_string()
    |> Path.join("starfleet/schema/decision-v1.json")
  end
end
