defmodule Fleet.SchemaCache do
  use Boundary, deps: [], exports: []

  @moduledoc """
  Shared load-once cache for resolved schemas and boot-time artifacts.

  Values live in `:persistent_term`: reads are frequent and writes must remain
  boot-time or first-access operations. The key is the cache identity, so callers
  include a variable resolved path in the key when variants can coexist.
  """

  @miss {__MODULE__, :miss}

  @doc """
  Reads, decodes, resolves and caches a JSON schema under `persistent_key`.

  Cache hits do not read the file. Artifact and schema errors raise.
  """
  @spec resolve_json_schema!(term(), Path.t()) :: ExJsonSchema.Schema.Root.t()
  def resolve_json_schema!(persistent_key, path) do
    cached(persistent_key, fn ->
      path |> File.read!() |> Jason.decode!() |> ExJsonSchema.Schema.resolve()
    end)
  end

  @doc """
  Fetches a cached value or raises. `boot_loader` is included in the miss
  message when supplied.
  """
  @spec fetch!(term(), String.t() | nil) :: term()
  def fetch!(persistent_key, boot_loader \\ nil) do
    case :persistent_term.get(persistent_key, @miss) do
      @miss ->
        hint = boot_loader || "the owning app's boot-time init function"

        raise ArgumentError,
              "Fleet.SchemaCache: key #{inspect(persistent_key)} not loaded — " <>
                "call #{hint} at boot"

      value ->
        value
    end
  end

  @doc """
  Returns a cached value or computes and stores it with `fun`.

  Raised failures are not cached; returned error tuples are ordinary values and
  are cached.
  """
  @spec cached(term(), (-> term())) :: term()
  def cached(persistent_key, fun) when is_function(fun, 0) do
    case :persistent_term.get(persistent_key, @miss) do
      @miss ->
        value = fun.()
        :persistent_term.put(persistent_key, value)
        value

      value ->
        value
    end
  end
end
