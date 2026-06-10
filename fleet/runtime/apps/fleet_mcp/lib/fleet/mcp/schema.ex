defmodule Fleet.MCP.Schema do
  @moduledoc """
  Validation JSON Schema (draft-07) au broadcast et au boot config
  (DN ring4/fleet_mcp.md §"Contrat technique" — `Fleet.MCP.Schema`).

  Fonctions **pures** (Iron Law — aucun process : pas d'état mutable, pas
  de concurrence, pas de fault-isolation propre ; un GenServer cache serait
  un goulot injustifié). Pattern cohérent fleet_cap_profile/Lot 0bis
  (`ex_json_schema` + résolution draft-07).

  Usage :
  - boot config fail-fast : validation `mcp-channels.yaml` contre
    `priv/schema/mcp-channels-v1.json`. (Z7.3 — `Fleet.MCP.Bridge`/`mcp-bridge.yaml`
    retirés ; ce helper reste générique, validation pure réutilisable.)
  - broadcast : validation event contre le schema du channel avant push
    (fail-fast `{:error, :schema_invalid, errors}` côté `Channel.broadcast/2`).

  Le caller décide la politique fail-fast (raise/crash) ; ce module renvoie
  un tuple taggé, il ne raise pas pour un échec de validation.
  """

  @typedoc "Liste de messages d'erreur lisibles (chemin: message)."
  @type errors :: [String.t()]

  @doc """
  Valide `data` (map déjà parsée, ex. YAML→map) contre le schema JSON
  draft-07 situé à `schema_path`.

  Retour : `:ok` | `{:error, errors}`. Toute défaillance de chargement /
  parse / résolution du schema est remontée comme `{:error, [msg]}`
  (jamais d'exception propagée au caller).
  """
  @spec validate(term(), Path.t()) :: :ok | {:error, errors()}
  def validate(data, _schema_path) when not is_map(data) do
    # F5 reviewer Lot 1 #558 : un YAML mal formé peut parser en liste/scalaire.
    # Le contrat (@moduledoc) garantit "jamais d'exception propagée" — donc
    # erreur taggée, PAS FunctionClauseError.
    {:error, ["data invalide : map attendue, reçu #{inspect(data)}"]}
  end

  def validate(data, schema_path) when is_map(data) and is_binary(schema_path) do
    with {:ok, raw} <- File.read(schema_path),
         {:ok, schema_map} <- Jason.decode(raw),
         {:ok, root} <- resolve(schema_map) do
      case ExJsonSchema.Validator.validate(root, data) do
        :ok ->
          :ok

        {:error, list} ->
          {:error, Enum.map(list, fn {msg, path} -> "#{path}: #{msg}" end)}
      end
    else
      {:error, %Jason.DecodeError{} = e} ->
        {:error, ["schema JSON invalide (#{schema_path}): #{Exception.message(e)}"]}

      {:error, reason} ->
        {:error, ["schema indisponible (#{schema_path}): #{inspect(reason)}"]}
    end
  end

  @doc """
  Chemin absolu d'un schema embarqué (`priv/schema/<name>`) de l'app
  `fleet_mcp`. Résout via `Application.app_dir/2` (robuste build/release).
  """
  @spec priv_schema(String.t()) :: Path.t()
  def priv_schema(name) when is_binary(name) do
    Application.app_dir(:fleet_mcp, Path.join("priv/schema", name))
  end

  # ex_json_schema résout les $ref/draft à la résolution ; une structure de
  # schema invalide y lève — on l'encapsule en tuple (contrat sans exception).
  defp resolve(schema_map) do
    {:ok, ExJsonSchema.Schema.resolve(schema_map)}
  rescue
    e -> {:error, e}
  end
end
