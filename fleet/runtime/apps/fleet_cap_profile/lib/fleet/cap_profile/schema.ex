defmodule Fleet.CapProfile.Schema do
  @moduledoc """
  Validation JSON-schema d'un cap-profile / modop (conformité STRUCTURELLE).

  Cluster de validation extrait de `Fleet.CapProfile`. Distinct des invariants
  métier G24 (`Fleet.CapProfile.Invariants`, purs sur le struct composé) : ici
  on valide la **forme** d'une map brute (post-YAML, avant `to_struct`) contre
  les JSON-schemas pinnés dans `priv/schema/` —

    * `cap-profile-v2.5.json` — schema strict du profile composé.
    * `modop-profile.json` — schema strict du fragment modop (clés réservées
      interdites : `kind`, `metadata.containment`, `metadata.name` — un modop ne
      peut donc pas override le containment/name/kind du profile de base).

  Sens de dépendance UNIQUE (pas de cycle) : ce module est en AMONT du cœur — il
  n'appelle ni les accesseurs single-authority (`name/1`, `containment/1`…) ni le
  futur `Catalog`. Ses seules deps sont `Jason` / `ExJsonSchema` / `File` (déjà
  dans l'app). `Fleet.CapProfile.load/1` et `compose/2` appellent `validate/2` ;
  `read_modops/2` (côté cœur) appelle `validate_modop_keys/1` puis `validate/2`.

  I/O : lit les fichiers schema du FS. `schema_dir/0` lit la clé env
  `:fleet_cap_profile, :schema_dir` (les tests la surchargent via
  `Application.put_env/3`), défaut = `priv/schema` bundlé. Le read+decode+resolve
  est caché en `:persistent_term` (keyé par le path RÉSOLU → les overrides test
  ont leur propre entrée), lazy, erreurs non-cachées.
  """

  require Logger

  # Fast-path guard for top-level reserved keys. `metadata.containment`
  # and `metadata.name` are also reserved — enforced by the JSON schema
  # `priv/schema/modop-profile.json` (`not/anyOf` clause). `kind` reste
  # réservé (il différencie cap-profile vs modop côté merge) ; `apiVersion`
  # n'est PAS réservé (champ inexistant — versioning par le code).
  @reserved_modop_keys ~w(kind)

  @doc """
  Valide une map brute contre le JSON-schema du `kind` demandé.

  ## Exit codes
    * `:ok` — conforme au schema.
    * `{:error, :invalid_schema}` — `kind: :cap_profile` non-conforme.
    * `{:error, :invalid_modop}` — `kind: :modop` non-conforme.
    * `{:error, :schema_unavailable}` — fichier schema priv absent ou corrompu.

  Les atomes d'erreur (`:invalid_schema`/`:invalid_modop`/`:schema_unavailable`)
  sont le contrat de retour de `load/1` et `compose/2` (cf. leurs moduledocs) —
  figés, ne pas renommer.
  """
  @spec validate(map(), :cap_profile | :modop) ::
          :ok | {:error, :invalid_schema | :invalid_modop | :schema_unavailable}
  def validate(map, kind) when is_map(map) and kind in [:cap_profile, :modop] do
    case load_schema(kind) do
      {:ok, schema} ->
        case ExJsonSchema.Validator.validate(schema, map) do
          :ok ->
            :ok

          {:error, _errors} ->
            case kind do
              :cap_profile -> {:error, :invalid_schema}
              :modop -> {:error, :invalid_modop}
            end
        end

      {:error, :schema_unavailable} = err ->
        err
    end
  end

  @doc """
  Refuse un fragment modop qui porte une clé réservée top-level (`kind`).
  Garde fast-path AVANT la validation JSON-schema : un modop ne peut pas
  override le `kind` du profile de base.

  `:ok` si aucune clé réservée, sinon `{:error, :invalid_modop}`.
  """
  @spec validate_modop_keys(map()) :: :ok | {:error, :invalid_modop}
  def validate_modop_keys(map) when is_map(map) do
    case Enum.find(@reserved_modop_keys, &Map.has_key?(map, &1)) do
      nil -> :ok
      _key -> {:error, :invalid_modop}
    end
  end

  # ============================================================
  # Schema loading (privé — I/O + cache)
  # ============================================================

  defp load_schema(:cap_profile), do: load_schema_file("cap-profile-v2.5.json")
  defp load_schema(:modop), do: load_schema_file("modop-profile.json")

  # Schema priv IMMUABLE : read+decode+resolve une fois, caché en `:persistent_term`
  # keyé par le path RÉSOLU (les overrides test de `schema_dir/0` ont leur entrée). Lazy-init,
  # erreurs non-cachées.
  defp load_schema_file(name) do
    path = Path.join(schema_dir(), name)
    key = {__MODULE__, :schema, path}

    case :persistent_term.get(key, :miss) do
      :miss ->
        case read_schema_file(path) do
          {:ok, _schema} = ok ->
            :persistent_term.put(key, ok)
            ok

          err ->
            err
        end

      cached ->
        cached
    end
  end

  defp read_schema_file(path) do
    with {:ok, content} <- File.read(path),
         {:ok, decoded} <- Jason.decode(content),
         {:ok, schema} <- safe_resolve(decoded) do
      {:ok, schema}
    else
      {:error, reason} ->
        Logger.warning("schema unavailable: #{inspect(reason)} at #{path}")
        {:error, :schema_unavailable}
    end
  end

  defp safe_resolve(decoded) do
    {:ok, ExJsonSchema.Schema.resolve(decoded)}
  rescue
    e -> {:error, {:schema_resolve_error, Exception.message(e)}}
  end

  defp schema_dir do
    case Application.get_env(:fleet_cap_profile, :schema_dir) do
      nil -> Path.join(to_string(:code.priv_dir(:fleet_cap_profile)), "schema")
      dir -> dir
    end
  end
end
