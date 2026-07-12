defmodule Fleet.CapProfile.Catalog do
  @moduledoc """
  Resolution + reading of the cap-profile catalogue YAML files.

  Cluster extracted from `Fleet.CapProfile`. SINGLE concern: the FS FRONT of the
  domain (directory scan, YAML decode, resolving a role/modop into a raw map
  pre-`to_struct`). The `load`/`compose` core calls `read_role/1` and
  `read_modops/1`; it never touches the FS itself.

  ## Security invariant — resolution by `metadata.name`, never by filename

  A cap-profile is resolved by its INTERNAL `metadata.name` prop (via `name_index/1`),
  NOT by filename (cosmetic). The source of truth is the data, never the
  filesystem: `list/1`, `read_role/1` and the boot enumerator thus share the
  SAME key (the name) → enum and load never drift apart (a listed profile is
  always loadable). A modop name (an untrusted input used as a path segment) is
  confined under `<root>/modop/` via `Fleet.Slug.confined_join/2` (fail-closed:
  a `..`/`/` never reaches the FS).

  ## Public surface + out-of-app re-export

  `list/1` and `root_dir/0` are consumed OUT of the app (`Fleet.Spawner.PermanentBoot`
  enumerates + aligns its dir; `Fleet.Observation.Deck` lists the dashboard roles).
  `Fleet.CapProfile` re-exports them via `defdelegate` — the public API consumed
  out-of-app does NOT move. `read_role/1` and `read_modops/1` are public for the
  core (same app).

  ## Single dependency direction (no cycle)

  This module depends on `Fleet.CapProfile.Schema` (validating modop fragments in
  `read_modops/1`) and on `Fleet.Slug` (confinement) — both UPSTREAM, neither
  calls Catalog. The `Fleet.CapProfile.load`/`compose` core calls this module
  (runtime-dep). No cycle.

  ## Configuration

  `root_dir/0` reads the env key `:fleet_cap_profile, :root_dir` (tests drive it
  via `Application.put_env/3`), default = the BUNDLED canon resolved by
  `:code.priv_dir(:lcars_fleet)` under `cap_profile/` (resolves in a release as in dev, without env).
  """

  require Logger

  # JSON-schema validation of modop fragments (reserved keys + conformance). UPSTREAM:
  # Schema calls nothing here (no cycle). Two FQ calls under credo AliasUsage, aliased
  # for the cluster's readability.
  alias Fleet.CapProfile.Schema

  # ============================================================
  # Role resolution (by metadata.name)
  # ============================================================

  @doc """
  Resolves a cap-profile by its `metadata.name` prop (not by filename — that is cosmetic) and
  returns the raw map (pre-`to_struct`). Source of truth = the data, never the filesystem (see `list/1`).

  ## Exit codes
    * `{:ok, raw}` — the role exists in the catalogue.
    * `{:error, :not_found}` — no profile carries this `name`.
    * `{:error, :invalid_schema}` — corrupt catalogue (an undecodable YAML) →
      we CANNOT resolve by name. The `load`/`compose` contract classes "malformed
      YAML" as `:invalid_schema` (not `:not_found`, which would suggest the role is absent).
  """
  @spec read_role(String.t()) ::
          {:ok, map()} | {:error, :not_found | :invalid_schema | :catalogue_missing | :name_collision}
  def read_role(role) do
    # An ABSENT catalogue dir is a BROKEN CONFIG, not "this role is absent" → distinct
    # `:catalogue_missing` (name_index on a missing dir wildcards to `[]` → empty index → `:not_found`,
    # which masks the config error as a mere typo'd role name). `list/1` already distinguishes; so must
    # `read_role`, the path `load/1`/`compose/2` take for a single role.
    if File.dir?(root_dir()) do
      # EXHAUSTIVE on name_index's tagged returns: it also yields `{:error, :name_collision}`
      # (two catalogue files with the same metadata.name — broken deploy artifact). An uncaught
      # variant here crashed load/spawn with an opaque CaseClauseError instead of the fail-loud
      # tag (name_index already logged the colliding path). Propagated as-is, like `list/1`.
      case name_index(root_dir()) do
        {:ok, index} ->
          case Map.fetch(index, role) do
            {:ok, raw} -> {:ok, raw}
            :error -> {:error, :not_found}
          end

        {:error, {:invalid_yaml, _path}} ->
          {:error, :invalid_schema}

        {:error, :name_collision} = err ->
          err
      end
    else
      {:error, :catalogue_missing}
    end
  end

  @doc """
  Lists the NAMES (`metadata.name`) of the catalogue's cap-profiles (`dir`, default `root_dir/0`).

  **SINGLE SOURCE**: every enumerator (`Fleet.Spawner.PermanentBoot`) AND `Fleet.CapProfile.load/1`
  resolve by THIS key — the `name` prop, **never** the filename (cosmetic). Sorted.
  A `name` collision between two files → `{:error, :name_collision}` (fail-loud: no silent
  resolution at the whim of the filesystem).
  """
  @spec list(String.t()) :: {:ok, [String.t()]} | {:error, term()}
  def list(dir \\ root_dir()) do
    # Absent/unreadable dir = error (broken config) — distinct from an empty catalogue ({:ok, []}).
    # `Path.wildcard` conflates the two; `File.dir?` decides. (`load/1`/`compose/2` go through
    # `read_role`, which ALSO checks `File.dir?` first → an absent dir there gives `:catalogue_missing`
    # (same broken-config signal as here), NOT `:not_found`.)
    if File.dir?(dir) do
      with {:ok, index} <- name_index(dir) do
        {:ok, index |> Map.keys() |> Enum.sort()}
      end
    else
      {:error, :enoent}
    end
  end

  # Index `metadata.name => raw` by scanning `<dir>/*.yaml` + `<dir>/archivistes/*.yaml`.
  # NO `monks/` scan: the monks are FROZEN under `priv/cap_profile/canon/_frozen-monks/`
  # (deliberately out of the boot loop, F-C153) and a `monks/` dir does not exist — a wildcard
  # on it was speculative scaffolding (YAGNI); the re-home that thaws them adds their scan
  # (and their slot_scope) THEN. The `modop/` dir stays excluded: overlays have no role
  # identity. A fragment without `metadata.name` → ignored (baseline/overlay).
  # Collision `name` → fail-loud (`:name_collision`).
  #
  # A NON-DECODABLE YAML in the catalogue is NOT silently skipped (otherwise the role would be
  # INVISIBLE to the index → `load` would see it as `:not_found` (role absent) instead of
  # `:invalid_schema` (role corrupt), and `list/1` (enumerated by PermanentBoot) would amputate it
  # from boot silently → a "green" but incomplete deploy). A corrupt file = a broken deploy artifact →
  # we propagate `{:error, {:invalid_yaml, path}}` (fail-loud). Assumed consequence: a single
  # unreadable file poisons the whole index (corrupt catalogue = we load NONE of it) — consistent with
  # "we do not save a wounded thing".
  defp name_index(dir) do
    files =
      Path.wildcard(Path.join(dir, "*.yaml")) ++
        Path.wildcard(Path.join([dir, "archivistes", "*.yaml"]))

    Enum.reduce_while(files, {:ok, %{}}, fn path, {:ok, acc} ->
      case decode_yaml(path) do
        {:ok, raw} ->
          case get_in(raw, ["metadata", "name"]) do
            name when is_binary(name) and name != "" ->
              if Map.has_key?(acc, name) do
                Logger.error("Catalog: metadata.name collision #{inspect(name)} (#{path})")
                {:halt, {:error, :name_collision}}
              else
                {:cont, {:ok, Map.put(acc, name, raw)}}
              end

            _ ->
              base = Path.basename(path)

              # A no-name file is a DELIBERATE baseline/overlay fragment ONLY by the `_`-prefix convention
              # (`_baseline-*.yaml`, mirror of `_frozen-monks/`). A NON-prefixed file with no
              # `metadata.name` looks like a role whose name was lost → make the silent skip VISIBLE
              # (warning), otherwise that role vanishes from the index (load → `:not_found`) with no signal.
              unless String.starts_with?(base, "_") do
                Logger.warning(
                  "Catalog: #{base} has no metadata.name — skipped (a role needs a name; " <>
                    "`_`-prefix a file that is a deliberate non-role fragment)"
                )
              end

              {:cont, {:ok, acc}}
          end

        {:error, reason} ->
          Logger.error(
            "Catalog: unreadable YAML #{path} (#{inspect(reason)}) — corrupt catalogue"
          )

          {:halt, {:error, {:invalid_yaml, path}}}
      end
    end)
  end

  # ============================================================
  # Modop reading
  # ============================================================

  @doc """
  Reads and validates the named modop fragments (declared order preserved), returns the raw maps.

  Each name (an untrusted input, serving as a path COMPONENT `modop/<name>/profile.yaml`) is cast
  to a slug and confined under `<root>/modop/` BEFORE any `Path.join` — a malformed name
  (`..`/`/`) never reaches the FS (fail-closed → `:invalid_modop`). Each fragment is validated
  via `Fleet.CapProfile.Schema` (reserved keys + modop JSON-schema).

  ## Exit codes
    * `{:ok, [raw]}` — all modops read and conformant.
    * `{:error, :modop_not_found}` — a named modop is absent (logged).
    * `{:error, :invalid_modop}` — name not confined, reserved key, or nonconformant fragment.
    * `{:error, :invalid_schema}` / `{:error, :schema_unavailable}` — decode/schema (see Schema).
  """
  @spec read_modops([String.t()]) :: {:ok, [map()]} | {:error, term()}
  def read_modops(modop_set) when is_list(modop_set) do
    result =
      Enum.reduce_while(modop_set, {:ok, []}, fn name, {:ok, acc} ->
        # The modop name comes from the catalogue / a composer (untrusted input) and serves as a path
        # COMPONENT (`modop/<name>/profile.yaml`). A name with `..`/`/` would traverse outside the
        # modop_root (loading an arbitrary host YAML as a "modop"). We cast it to a slug BEFORE any
        # `Path.join` AND confine the leaf under `<root>/modop/`: a malformed name never reaches the
        # FS (fail-closed → `:invalid_modop`, like a reserved/nonconformant fragment).
        modop_root = Path.join(root_dir(), "modop")

        case Fleet.Slug.confined_join(modop_root, name) do
          {:ok, dir} ->
            path = Path.join(dir, "profile.yaml")

            if File.exists?(path) do
              with {:ok, raw} <- decode_yaml(path),
                   :ok <- Schema.validate_modop_keys(raw),
                   :ok <- Schema.validate(raw, :modop) do
                {:cont, {:ok, [raw | acc]}}
              else
                {:error, reason} -> {:halt, {:error, reason}}
              end
            else
              Logger.warning("Catalog: modop not found: #{inspect(name)} at #{path}")
              {:halt, {:error, :modop_not_found}}
            end

          {:error, _slug_or_escape} ->
            Logger.warning(
              "Catalog: modop name not confined (slug/traversal): #{inspect(name)} — refused"
            )

            {:halt, {:error, :invalid_modop}}
        end
      end)

    case result do
      {:ok, modops} -> {:ok, Enum.reverse(modops)}
      error -> error
    end
  end

  # ============================================================
  # YAML decode + catalogue root
  # ============================================================

  defp decode_yaml(path) do
    case YamlElixir.read_from_file(path) do
      {:ok, map} when is_map(map) -> {:ok, map}
      {:ok, _other} -> {:error, :invalid_schema}
      {:error, _reason} -> {:error, :invalid_schema}
    end
  end

  @doc """
  Root of the cap-profiles catalogue (`<root_dir>/<role>.yaml`). **SINGLE SOURCE**: every
  enumerator (e.g. `Fleet.Spawner.PermanentBoot`) MUST scan this dir, otherwise enum and load
  drift apart.
  """
  @spec root_dir() :: String.t()
  def root_dir do
    # A `:root_dir` explicitly set to nil (e.g. a cross-test env leak) must NEVER
    # reach Path.join → coalesce to the default (the nil state made harmless at the boundary).
    # Default = the BUNDLED priv (`:code.priv_dir`) → resolves in a RELEASE (lib/lcars_fleet-vsn/priv/…)
    # as in dev (_build/…/priv) WITHOUT any env. The old default `"cap-profiles"` (relative to the CWD) was
    # never correct without an explicit `LCARS_CAPPROFILES_ROOT` → `:enoent` in a release (hermeticity).
    Application.get_env(:fleet_cap_profile, :root_dir) ||
      Path.join(to_string(:code.priv_dir(:lcars_fleet)), "cap_profile/canon/cap-profiles")
  end
end
