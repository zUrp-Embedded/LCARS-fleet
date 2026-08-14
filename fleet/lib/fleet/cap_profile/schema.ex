defmodule Fleet.CapProfile.Schema do
  @moduledoc """
  JSON-schema validation of a cap-profile / modop (STRUCTURAL conformance).

  Validation cluster of `Fleet.CapProfile`. Distinct from the G24 business
  invariants (`Fleet.CapProfile.Invariants`, pure over the composed struct):
  HERE the RAW map is validated against the JSON-schemas pinned in
  `priv/cap_profile/schema/` —

    * `cap-profile-v2.5.json` — strict schema of the composed profile.
    * `modop-profile.json` — strict schema of the modop fragment (reserved keys
      forbidden: `kind`, `metadata.containment`, `metadata.name` — so a modop
      cannot override the base profile's containment/name/kind).
    * `reserved-seat-v1.json` — strict schema of a `kind: ReservedSeat` catalogue entry
      (BL-6-45): a kept, non-spawnable seat — a seat carrying a `spec` is rejected.

  Single dependency direction (no cycle): this module is UPSTREAM of the core — it
  calls neither the single-authority accessors (`name/1`, `containment/1`…) nor
  `Catalog`. Its only deps are `Jason` / `ExJsonSchema` / `File` (already in the
  app). `Fleet.CapProfile.load/1` and `compose/2` call `validate/2`;
  `read_modops/2` (core side) calls `validate_modop_keys/1` then `validate/2`.

  I/O: reads the schema files from the FS (`:lcars_fleet, :cap_profile_schema_dir` override;
  default = the bundled `priv/cap_profile/schema`). The read+decode+resolve is cached in
  `:persistent_term` (keyed by the RESOLVED path → test overrides get their own entry),
  lazy, errors not cached.
  """

  require Logger

  # Fast-path guard for top-level reserved keys. `metadata.containment`/`metadata.name`
  # are enforced by the JSON schema `priv/cap_profile/schema/modop-profile.json`
  # (`not/anyOf` clause); `kind` stays reserved HERE (it distinguishes cap-profile vs
  # modop at merge time).
  @reserved_modop_keys ~w(kind)

  @doc """
  Validates a raw map against the JSON-schema of the requested `kind`.

  ## Exit codes
    * `:ok` — conformant to the schema.
    * `{:error, :invalid_schema}` — `kind: :cap_profile` or `:reserved_seat` nonconformant
      (one atom for both: the callers' contract branches on `:ok`/`{:error, reason}` only).
    * `{:error, :invalid_modop}` — `kind: :modop` nonconformant.
    * `{:error, :schema_unavailable}` — the priv schema file is absent or corrupt.

  The error atoms (`:invalid_schema`/`:invalid_modop`/`:schema_unavailable`)
  are the return contract of `load/1` and `compose/2` (see their moduledocs) —
  frozen, do not rename.
  """
  @spec validate(map(), :cap_profile | :modop | :reserved_seat) ::
          :ok | {:error, :invalid_schema | :invalid_modop | :schema_unavailable}
  def validate(map, kind) when is_map(map) and kind in [:cap_profile, :modop, :reserved_seat] do
    case load_schema(kind) do
      {:ok, schema} ->
        case ExJsonSchema.Validator.validate(schema, map) do
          :ok ->
            :ok

          {:error, errors} ->
            # LE VERDICT REMONTE, LE DIAGNOSTIC RESTAIT ICI. `ExJsonSchema` rend la liste des
            # violations avec leur pointeur JSON ; elle etait remplacee sur place par un atome
            # unique, et l'operateur apprenait que son profil est non conforme sans apprendre OU.
            # Sur un fichier de catalogue de plusieurs dizaines de cles, c'est la difference entre
            # une correction et une chasse.
            #
            # L'atome de retour NE CHANGE PAS : les trois sont le contrat gele de `load/1` et
            # `compose/2`, et les appelants branchent dessus. Ce qui manquait n'etait pas un type
            # plus riche, c'etait une TRACE — le detail va au rail operateur, la ou on le cherche.
            Logger.error("CapProfile.Schema: #{kind} REFUSED — #{describe_violations(errors)}")

            case kind do
              :cap_profile -> {:error, :invalid_schema}
              :reserved_seat -> {:error, :invalid_schema}
              :modop -> {:error, :invalid_modop}
            end
        end

      {:error, :schema_unavailable} = err ->
        err
    end
  end

  # BORNE, ET LA TRONCATURE SE DIT. Un fichier franchement faux produit des dizaines de violations,
  # et noyer la trace sous elles la rend aussi illisible que le silence qu'on repare. On en montre
  # dix et on annonce le reste — un « … » muet laisserait croire que la liste est complete.
  @violations_shown 10

  # ⚠ PAS DE CLAUSE DE REPLI, ET C'EST DIALYZER QUI L'A TRANCHE. J'en avais ecrit une « au cas ou
  # `ExJsonSchema` rendrait autre chose qu'une liste » : `pattern_match_cov`, elle ne peut jamais
  # matcher — le spec du validateur garantit `[error]` sur la branche d'erreur. Une garde defensive
  # contre une forme que le type interdit n'est pas une precaution, c'est du code que personne
  # n'atteindra jamais et qu'un lecteur croira necessaire. La garde `is_list/1` reste : elle DIT
  # l'attente, sans pretendre couvrir autre chose.
  defp describe_violations(errors) when is_list(errors) do
    total = length(errors)

    shown =
      errors
      |> Enum.take(@violations_shown)
      |> Enum.map_join(" | ", fn
        %{error: _, path: path, message: message} -> "#{path}: #{message}"
        {message, path} -> "#{path}: #{message}"
        other -> inspect(other)
      end)

    if total > @violations_shown,
      do: "#{total} violation(s), the first #{@violations_shown}: #{shown}",
      else: "#{total} violation(s): #{shown}"
  end

  @doc """
  Returns `{:error, :invalid_modop}` when a fragment carries a reserved key.
  """
  @spec validate_modop_keys(map()) :: :ok | {:error, :invalid_modop}
  def validate_modop_keys(map) when is_map(map) do
    case Enum.find(@reserved_modop_keys, &Map.has_key?(map, &1)) do
      nil -> :ok
      _key -> {:error, :invalid_modop}
    end
  end

  # ============================================================
  # Schema loading (private — I/O + cache)
  # ============================================================

  defp load_schema(:cap_profile), do: load_schema_file("cap-profile-v2.5.json")
  defp load_schema(:modop), do: load_schema_file("modop-profile.json")
  defp load_schema(:reserved_seat), do: load_schema_file("reserved-seat-v1.json")

  # IMMUTABLE priv schema: read+decode+resolve once, cached in `:persistent_term`
  # keyed by the RESOLVED path (the `schema_dir/0` test overrides get their entry). Lazy-init,
  # errors not cached.
  # DELIBERATE manual cache, NOT `Fleet.SchemaCache.cached/2` (even though that dep is
  # declared on the facade boundary): `cached/2` caches whatever the fun returns, so it
  # would freeze a soft `{:error, :schema_unavailable}` for the BEAM's lifetime — here
  # the error tuple must stay RETRYABLE. That is the RULE `cached/2` states in its own
  # `@doc` ("returned error tuples are ordinary values and are cached"), and this module
  # is the site that falls on the other side of it.
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
      announce_recovery(path)
      {:ok, schema}
    else
      {:error, reason} ->
        warn_once(path, reason)
        {:error, :schema_unavailable}
    end
  end

  # LE REESSAI EST L'ARBITRAGE, L'INONDATION EST L'ACCIDENT. Ne pas memoriser l'echec est
  # DELIBERE (cf. `load_schema_file/1` : un `{:error, _}` gele pour la vie du BEAM rendrait un
  # schema redevenu lisible inaccessible sans redemarrage, et c'est le meme choix que la relecture
  # du secret HMAC a chaque requete). Mais chaque validation refaisait alors `File.read` + `decode`
  # + `resolve` ET reecrivait la MEME ligne de warning : une indisponibilite durable devenait
  # proportionnelle au trafic, et la trace ou on l'aurait vue etait la premiere noyee.
  #
  # On journalise donc la TRANSITION, pas l'etat — exactement la discipline de la jauge de boite aux
  # lettres du poller : « un etat qui dure est UN fait ; le repeter noie la trace ». Un changement
  # de raison (absent -> illisible, illisible -> JSON casse) est une transition et parle a nouveau.
  #
  # ⚠ ET LE RETOUR SE DIT AUSSI. Sans l'annonce de reprise, un operateur ne peut pas distinguer
  # « repare » de « mort et silencieux » — la seule chose que le silence prouve, c'est qu'on ne
  # journalise plus.
  #
  # `persistent_term` porte le drapeau parce que le cache voisin y est deja, et les ecritures sont
  # bornees a une par TRANSITION (3 chemins de schema possibles) : jamais une par validation, ce
  # qui declencherait un balayage global a chaque appel.
  defp warn_once(path, reason) do
    key = {__MODULE__, :schema_error_logged, path}

    if :persistent_term.get(key, :none) != reason do
      :persistent_term.put(key, reason)

      Logger.warning(
        "Schema: schema unavailable: #{inspect(reason)} at #{path} — this line is emitted ONCE " <>
          "per distinct cause (the read IS retried at every validation, deliberately: a schema " <>
          "made readable again is picked up with no restart)"
      )
    end
  end

  defp announce_recovery(path) do
    key = {__MODULE__, :schema_error_logged, path}

    case :persistent_term.get(key, :none) do
      :none ->
        :ok

      previous ->
        :persistent_term.erase(key)
        Logger.info("Schema: #{path} is readable again (was: #{inspect(previous)})")
    end
  end

  defp safe_resolve(decoded) do
    {:ok, ExJsonSchema.Schema.resolve(decoded)}
  rescue
    e -> {:error, {:schema_resolve_error, Exception.message(e)}}
  end

  defp schema_dir do
    case Application.get_env(:lcars_fleet, :cap_profile_schema_dir) do
      nil -> Path.join(to_string(:code.priv_dir(:lcars_fleet)), "cap_profile/schema")
      dir -> dir
    end
  end
end
