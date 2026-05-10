defmodule Fleet.Starfleet.Gatekeeper do
  @moduledoc """
  Pure functions validation JSON décision pod gatekeeper / autre pod
  d'arbitrage.

  Pattern PoC-π3 PROVEN figé : sortie JSON
  `{decision, reason, details, chain?}`. Schema strict
  `priv/schema/decision-v1.json` `ex_json_schema` validation au load
  fail-fast.

  ## Cache schema

  Schema résolu **une fois** au boot via
  `Fleet.Starfleet.Application.start/2` et persisté dans
  `:persistent_term` (clé `{__MODULE__, :decision_schema}`).
  Pattern cohérent ch9 ETS read-only / ch11 schema cache.

  ## Public API

      iex> {:ok, %Fleet.Starfleet.Decision{decision: "halt"}} =
      ...>   Fleet.Starfleet.Gatekeeper.validate(
      ...>     ~s|{"decision":"halt","reason":"poc","details":{},"chain":["test"]}|
      ...>   )
  """

  alias Fleet.Starfleet.Decision

  @schema_key {__MODULE__, :decision_schema}

  @doc """
  Valide un JSON texte de décision.

  Returns :
    * `{:ok, %Decision{}}` — JSON parsé + schema valide
    * `{:error, reason}` — JSON malformé OU schema invalide

  Raises `ArgumentError` si le schema n'a pas été chargé via
  `init_schema!/0` (boot-time fail-fast).
  """
  @spec validate(String.t()) ::
          {:ok, Decision.t()} | {:error, String.t()}
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
        {:error, "decision invalid: #{inspect(reason)}"}
    end
  end

  @doc """
  Charge le schema JSON décision et le persiste dans `:persistent_term`.

  Appelée au boot par `Fleet.Starfleet.Application.start/2`. Fail-fast :
  raise si fichier schema absent ou JSON malformé.
  """
  @spec init_schema!() :: :ok
  def init_schema! do
    schema_path =
      Application.get_env(
        :fleet_starfleet,
        :decision_schema_path,
        default_schema_path()
      )

    schema =
      schema_path
      |> File.read!()
      |> Jason.decode!()
      |> ExJsonSchema.Schema.resolve()

    :persistent_term.put(@schema_key, schema)
    :ok
  end

  defp resolved_schema do
    case :persistent_term.get(@schema_key, nil) do
      nil ->
        raise ArgumentError,
              "Fleet.Starfleet.Gatekeeper: schema not loaded — appeler init_schema!/0 au boot"

      schema ->
        schema
    end
  end

  defp default_schema_path do
    :code.priv_dir(:fleet_starfleet)
    |> to_string()
    |> Path.join("schema/decision-v1.json")
  end
end
