defmodule Fleet.CapProfile.Schema do
  @moduledoc """
  Validates raw maps structurally; composed G24 semantics belong to `Invariants`.
  Bundled schemas in `priv/cap_profile/schema/` cover profiles, modop fragments and
  reserved seats. Modops cannot override kind/containment/name; seats cannot carry spec.

  `:lcars_fleet, :cap_profile_schema_dir` overrides the schema directory. Successful
  read/decode/schema resolution is cached lazily in persistent_term by joined path
  (not canonical filesystem identity). Errors are retried; cached successes ignore disk edits.
  """

  require Logger

  # Fast-path kind guard; the modop schema separately protects metadata.containment/name.
  @reserved_modop_keys ~w(kind)

  @doc """
  Validates against the requested schema, returning :ok or a frozen caller-facing error:
  `:invalid_schema` for profiles/seats, `:invalid_modop` for fragments, or
  `:schema_unavailable` for schema read/decode/resolution failures. Do not rename these atoms.
  Validation failures log up to ten violations with locations, the total and a truncation notice.
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
            # Preserve locations in the log while keeping the callers' error-atom contract.
            Logger.error("CapProfile.Schema: #{kind} REFUSED — #{describe_violations(errors)}")

            refusal(kind)
        end

      {:error, :schema_unavailable} = err ->
        err
    end
  end

  defp refusal(:cap_profile), do: {:error, :invalid_schema}
  defp refusal(:reserved_seat), do: {:error, :invalid_schema}
  defp refusal(:modop), do: {:error, :invalid_modop}

  # Bound log volume without presenting a truncated list as complete.
  @violations_shown 10

  # ExJsonSchema's error contract is a list; no fallback for a type-impossible container.
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
  Rejects the reserved top-level string key `kind`. Other reserved fields require
  `validate/2` with the modop schema.
  """
  @spec validate_modop_keys(map()) :: :ok | {:error, :invalid_modop}
  def validate_modop_keys(map) when is_map(map) do
    case Enum.find(@reserved_modop_keys, &Map.has_key?(map, &1)) do
      nil -> :ok
      _key -> {:error, :invalid_modop}
    end
  end

  defp load_schema(:cap_profile), do: load_schema_file("cap-profile.json")
  defp load_schema(:modop), do: load_schema_file("modop-profile.json")
  defp load_schema(:reserved_seat), do: load_schema_file("reserved-seat.json")

  # SchemaCache.cached/2 would also cache error tuples, preventing recovery without restart.
  # Cache only success here. Concurrent cold reads are not serialized.
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

  # Log cause changes and recovery, not every failed retry. The non-atomic get/put can
  # duplicate announcements under concurrency; steady identical failures avoid repeated writes.
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
