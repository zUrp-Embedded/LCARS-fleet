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

  `root_dir/0` reads the env key `:fleet_cap_profile, :root_dir` (tests drive it via
  `Application.put_env/3`) — the FINE override, which keeps precedence. Default =
  `Fleet.Catalogue.cap_profiles_root/0`: the bundled canon unless `LCARS_CATALOGUE_ROOT` brings
  another catalogue, and `:code.priv_dir`-derived either way (resolves in a release as in dev,
  without env).

  **Last revised**: 2026-08-02
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
    * `{:error, {:role_reserved, name}}` — the entry exists as a `kind: ReservedSeat`
      (BL-6-45): the seat is kept, the box is closed — named, never conflated with absence.
    * `{:error, :invalid_schema}` — corrupt catalogue (an undecodable YAML) →
      we CANNOT resolve by name. The `load`/`compose` contract classes "malformed
      YAML" as `:invalid_schema` (not `:not_found`, which would suggest the role is absent).
  """
  @spec read_role(String.t()) ::
          {:ok, map()}
          | {:error,
             :not_found
             | :invalid_schema
             | :catalogue_missing
             | :name_collision
             | {:role_reserved, String.t()}}
  def read_role(role) do
    # IMAGE-FIRST (proven-good image at boot): once `Fleet.CapProfile.Image.publish!/0` ran, the
    # image IS the catalogue — a closed world, one epoch for the whole deployment (a disk mutation
    # mid-life changes nothing until a restart republishes). A role absent from the image is
    # `:not_found`, whatever the disk now says. No image (tests' hermetic default, tooling) → the
    # live-disk path below, unchanged.
    case Fleet.CapProfile.Image.published() do
      %{index: index} ->
        case Map.fetch(index, role) do
          {:ok, raw} -> refuse_reserved(role, raw)
          :error -> {:error, :not_found}
        end

      nil ->
        read_role_from_disk(role)
    end
  end

  # A ReservedSeat found by NAME answers its own refusal, never `:not_found` (the seat exists,
  # the box is closed — BL-6-45) and never `:invalid_schema` (validating a seat against the
  # PROFILE schema downstream would misname a declared state as corruption). Lives on BOTH
  # regimes (image branch above, disk branch below): the raw carries its kind in both.
  defp refuse_reserved(role, raw) do
    if spawnable?(raw), do: {:ok, raw}, else: {:error, {:role_reserved, role}}
  end

  defp read_role_from_disk(role) do
    if File.dir?(root_dir()) do
      case name_index(root_dir()) do
        {:ok, index} ->
          case Map.fetch(index, role) do
            {:ok, raw} -> refuse_reserved(role, raw)
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
        # Filter on the ENTRIES ({name, raw}) BEFORE projecting the keys — the predicate reads
        # the raw's kind, `Map.keys/1` would hand it strings. An unfiltered list here feeds a
        # ReservedSeat to every enumerator (CanonProof, PermanentBoot) → the seat has no SP
        # draft → fleet.boot_failed. Filter BEFORE enumerate (BL-6-45).
        {:ok,
         index
         |> Enum.filter(fn {_name, raw} -> spawnable?(raw) end)
         |> Enum.map(&elem(&1, 0))
         |> Enum.sort()}
      end
    else
      {:error, :enoent}
    end
  end

  @doc """
  Is this raw catalogue entry a SPAWNABLE profile? (`kind` ≠ `ReservedSeat` — BL-6-45.)
  The ONE predicate both enumeration projections apply (`list/1` here,
  `Fleet.CapProfile.list_from_published/0` on the image index): two projections, one rule.
  """
  @spec spawnable?(map()) :: boolean()
  def spawnable?(raw) when is_map(raw), do: Map.get(raw, "kind") != "ReservedSeat"

  # Index `metadata.name => raw` by scanning `<dir>/*.yaml` + `<dir>/archivistes/*.yaml`.
  # No `monks/` scan: the monks are FROZEN under `priv/catalogue/cap_profile/canon/_frozen-monks/`,
  # deliberately out of the boot loop (cf. `Fleet.SPBuilder.Monk`); the thaw that re-homes
  # them adds their scan then. The `modop/` dir stays excluded: overlays have no role
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

  @doc """
  Reads named modop fragments in order and validates their paths and schemas.
  """
  @spec read_modops([String.t()]) :: {:ok, [map()]} | {:error, term()}
  def read_modops(modop_set) when is_list(modop_set) do
    case Fleet.CapProfile.Image.published() do
      %{overlays: overlays} ->
        Enum.reduce_while(modop_set, {:ok, []}, fn name, {:ok, acc} ->
          case Map.fetch(overlays, name) do
            {:ok, raw} ->
              {:cont, {:ok, [raw | acc]}}

            :error ->
              Logger.warning("Catalog: modop not in the published image: #{inspect(name)}")
              {:halt, {:error, :modop_not_found}}
          end
        end)
        |> case do
          {:ok, modops} -> {:ok, Enum.reverse(modops)}
          error -> error
        end

      nil ->
        read_modops_from_disk(modop_set)
    end
  end

  defp read_modops_from_disk(modop_set) do
    result =
      Enum.reduce_while(modop_set, {:ok, []}, fn name, {:ok, acc} ->
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

  defp decode_yaml(path) do
    case YamlElixir.read_from_file(path) do
      {:ok, map} when is_map(map) -> {:ok, map}
      {:ok, _other} -> {:error, :invalid_schema}
      {:error, _reason} -> {:error, :invalid_schema}
    end
  end

  @doc """
  Returns the live disk role index used to build an image.
  """
  @spec snapshot_roles() :: {:ok, %{optional(String.t()) => map()}} | {:error, term()}
  def snapshot_roles do
    if File.dir?(root_dir()),
      do: name_index(root_dir()),
      else: {:error, {:catalogue_missing, root_dir()}}
  end

  @doc """
  Returns validated live-disk overlays keyed by modop directory name.
  """
  @spec snapshot_overlays() :: {:ok, %{optional(String.t()) => map()}} | {:error, term()}
  def snapshot_overlays do
    modop_root = Path.join(root_dir(), "modop")

    Path.wildcard(Path.join(modop_root, "*/profile.yaml"))
    |> Enum.reduce_while({:ok, %{}}, fn path, {:ok, acc} ->
      name = path |> Path.dirname() |> Path.basename()

      with {:ok, raw} <- decode_yaml(path),
           :ok <- Schema.validate_modop_keys(raw),
           :ok <- Schema.validate(raw, :modop) do
        {:cont, {:ok, Map.put(acc, name, raw)}}
      else
        {:error, reason} -> {:halt, {:error, {:invalid_overlay, name, reason}}}
      end
    end)
  end

  @doc """
  Returns the domain-specific catalogue root or the shared catalogue default.
  """
  @spec root_dir() :: String.t()
  def root_dir do
    Application.get_env(:fleet_cap_profile, :root_dir) || Fleet.Catalogue.cap_profiles_root()
  end
end
