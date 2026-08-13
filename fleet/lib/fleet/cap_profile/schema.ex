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

          {:error, _errors} ->
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
      {:ok, schema}
    else
      {:error, reason} ->
        Logger.warning("Schema: schema unavailable: #{inspect(reason)} at #{path}")
        {:error, :schema_unavailable}
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
