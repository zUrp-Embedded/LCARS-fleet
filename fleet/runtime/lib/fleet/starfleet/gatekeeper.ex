defmodule Fleet.Starfleet.Gatekeeper do
  @moduledoc """
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

  **Last revised**: 2026-07-18
  """

  alias Fleet.Decision

  @schema_key {__MODULE__, :decision_schema}

  @doc """
  Validates a decision's JSON text.

  Returns:
    * `{:ok, %Decision{}}` — JSON parsed + schema valid
    * `{:error, {:decision_invalid, cause}}` — malformed JSON (`cause` =
      `%Jason.DecodeError{}`) OR invalid schema (`cause` = ExJsonSchema errors).
      STRUCTURED pattern-matchable tuple (a bare string would not be); the human rendering (`inspect(cause)`) is done by consumers
      when logging/journaling, not here.

  Raises `ArgumentError` if the schema was not loaded via
  `init_schema!/0` (boot-time fail-fast).
  """
  # A gate decision is a structured VERDICT (decision + reason + details) — KB-scale. Bound the input
  # BEFORE `Jason.decode` (R2-12): a runaway/malicious pod could otherwise submit a giant JSON and force
  # an unbounded parse (memory DoS). 256 KiB is generous for a decision with rich `details`.
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
  Loads the decision JSON schema and persists it in `:persistent_term`
  via `Fleet.SchemaCache` (foundation authority for the load-and-cache pattern).

  Called at boot by `Fleet.Starfleet.Application.init/1`. Fail-fast:
  raises if the schema file is absent or the JSON is malformed. Idempotent
  by key: a second call does not re-read the file (the priv schema is
  immutable across the BEAM's lifetime).
  """
  @spec init_schema!() :: :ok
  def init_schema! do
    schema_path =
      Application.get_env(
        :fleet_starfleet,
        :decision_schema_path,
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
