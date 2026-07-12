defmodule Fleet.SchemaCache do
  # Z4 migration (2026-07-12) — frontière COMPILÉE du domaine : deps = graphe ex-umbrella
  # régularisé (successeur mécanique du verrou topologie, D-19), exports = la SURFACE
  # cross-domaine MESURÉE (Z4c : tout à [] puis violations constatées → liste). Le
  # compilateur refuse toute violation — plus de discipline. Rétrécir = geste Z6+.
  use Boundary, deps: [], exports: []
  @moduledoc """
  Single authority for the "load an artifact once, cache it in `:persistent_term`"
  pattern (resolved JSON schemas, boot-time configs).

  Dedup: the pipeline `File.read! |> Jason.decode! |> ExJsonSchema.Schema.resolve`
  + `:persistent_term` cache lived copied across `fleet_workflow` (Loader),
  `fleet_starfleet` (Gatekeeper) and `fleet_coord` (Policies — which re-read and
  re-resolved the schema file on EVERY validation, without a cache). A single
  implementation here, Ring 0: workflow/starfleet/coord already depend on the event_router domain, zero new dependency edge (deps are enforced by `use Boundary`).

  ## Why `:persistent_term` (and not ETS / a GenServer)

  These artifacts are read on EVERY validation (hot path) and written ONCE at boot
  or on first access: exactly the `:persistent_term` profile — read with no copy nor
  lock, from any process, with no carrier process (Iron Law: no process without a
  runtime reason). The trade-off is the write cost: each `put` triggers a heap scan
  of ALL processes (global GC). NEVER a per-tick / per-request `put` through this
  module — one artifact, one write.

  ## Key contract

  The `:persistent_term` key is the cache's IDENTITY: two different paths under the
  same key = the same entry (the first one loaded wins). If the path can vary within
  the BEAM's lifetime (test override via Application env), put the RESOLVED path IN
  the key (e.g. `{__MODULE__, :schema, path}`) — each variant has its own entry, no
  prod↔test pollution. A fixed key (e.g. `{Gatekeeper, :decision_schema}`) serves
  artifacts loaded once at boot and re-read by `fetch!/2` (which does not know the
  path).

  ## Ring 0 note (cap_profile)

  `fleet_cap_profile` (Ring 0 as well, WITHOUT a dep toward `fleet_event_router`)
  keeps two local copies of the `cached/2` skeleton
  (`CapProfile.Schema.load_schema_file/1`,
  `CapProfile.DisallowedTools.load_baseline_git_ops_denied!/0`): we do not add an
  intra-R0 edge for ten lines. If the edge appears one day for another reason,
  migrate these two sites.
  """

  # Namespaced miss sentinel: a bare `nil` or `:miss` would be legitimate cacheable
  # VALUES (the fun of `cached/2` can return anything).
  @miss {__MODULE__, :miss}

  @doc """
  Read + decode + resolve of a JSON schema, cached in `:persistent_term` under
  `persistent_key`. Idempotent: a hit does NOT re-read the file (priv schemas are
  immutable within the BEAM's lifetime). Fail-loud if the file is absent
  (`File.Error`), malformed (`Jason.DecodeError`) or non-resolvable (`ExJsonSchema`
  raises) — a broken schema is a broken deploy artifact, the boot must crash, never
  log-and-continue.
  """
  @spec resolve_json_schema!(term(), Path.t()) :: ExJsonSchema.Schema.Root.t()
  def resolve_json_schema!(persistent_key, path) do
    cached(persistent_key, fn ->
      path |> File.read!() |> Jason.decode!() |> ExJsonSchema.Schema.resolve()
    end)
  end

  @doc """
  Get-or-raise: reads the value cached under `persistent_key`, raises `ArgumentError`
  if nothing was loaded. `boot_loader` (optional) names the init function to call at
  boot (e.g. `"Fleet.Coord.Policies.init_policies!/0"`) for an actionable error
  message.
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
  Generic lazy cache: returns the value cached under `persistent_key`, otherwise
  runs `fun`, caches its result and returns it. If `fun` raises, NOTHING is cached
  — the next call retries (errors are not cached).

  Assumed gotcha: if `fun` returns an `{:error, _}` tuple (instead of raising), that
  tuple IS cached like any other value. For a load whose failure must stay
  retryable, raise (see `resolve_json_schema!/2`) or manage the cache by hand (see
  `Fleet.CapProfile.Schema`).
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
