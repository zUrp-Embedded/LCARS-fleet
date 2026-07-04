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
  `Fleet.Starfleet.Application.start/2` → `init_schema!/0`, délégué à
  l'autorité Ring 0 `Fleet.SchemaCache` (cache `:persistent_term`, clé
  `{__MODULE__, :decision_schema}`) — dédup B-R2, le pipeline
  read+decode+resolve vivait copié ici.

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
  Charge le schema JSON décision et le persiste dans `:persistent_term`
  via `Fleet.SchemaCache` (autorité Ring 0 du pattern chargé-caché).

  Appelée au boot par `Fleet.Starfleet.Application.start/2`. Fail-fast :
  raise si fichier schema absent ou JSON malformé. Idempotente par clé :
  un deuxième appel ne relit pas le fichier (schema priv immuable dans
  la vie du BEAM).
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
    :code.priv_dir(:fleet_starfleet)
    |> to_string()
    |> Path.join("schema/decision-v1.json")
  end
end
