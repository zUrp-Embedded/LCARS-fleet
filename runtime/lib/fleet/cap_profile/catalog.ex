defmodule Fleet.CapProfile.Catalog do
  @moduledoc """
  Resolves raw profiles by `metadata.name` and modops by directory name.

  Role/modop reads use the named catalogue's published image, falling back to its disk
  scope (own tree then system) only when no image exists. `list/0` instead scans the global
  disk search path. Listing checks names and excludes seats; it does not guarantee schema
  validity or loadability in a different scope/image.

  Disk modop names pass `Fleet.Slug.confined_join/2` before path lookup. This is lexical
  confinement, not a symlink check. Role filenames are cosmetic within the scanned paths.
  Public cross-domain access goes through `Fleet.CapProfile`.

  `:lcars_fleet, :cap_profile_root_dir` overrides the business tree; otherwise roots come
  from `Fleet.Catalogue`, whose default is release-relative unless configured explicitly.
  """

  require Logger

  alias Fleet.CapProfile.Schema

  @doc """
  Reads a raw profile by `metadata.name` from the default catalogue.
  Returns `:not_found` for absence and `{:role_reserved, name}` for an existing seat.
  Disk scan failures propagate; unreadable/invalid YAML maps to `:invalid_schema`,
  not absence. Structural profile validation belongs to the caller.
  """
  @spec read_role(String.t()) ::
          {:ok, map()}
          | {:error,
             :not_found
             | :invalid_schema
             | :catalogue_missing
             | :name_collision
             | {:role_reserved, String.t()}}
  def read_role(role), do: read_role(role, nil)

  @doc """
  Reads from the named catalogue's image or disk scope; nil uses `Fleet.Catalogue.root/0`.
  An image miss does not fall back to disk. Pass the project's root to avoid resolving a
  same-named role from the default catalogue.
  """
  @spec read_role(String.t(), Path.t() | nil) :: {:ok, map()} | {:error, term()}
  def read_role(role, root) do
    case published_for(root) do
      %{index: index} ->
        case Map.fetch(index, role) do
          {:ok, raw} -> refuse_reserved(role, raw)
          :error -> {:error, :not_found}
        end

      nil ->
        read_role_from_disk(role, root)
    end
  end

  defp published_for(nil), do: Fleet.CapProfile.Image.published()
  defp published_for(root) when is_binary(root), do: Fleet.CapProfile.Image.published(root)

  # A seat is present but not spawnable; validating it as a profile would misreport corruption.
  defp refuse_reserved(role, raw) do
    if spawnable?(raw), do: {:ok, raw}, else: {:error, {:role_reserved, role}}
  end

  # Mirror image scope on disk; flattening installed catalogues leaks neighbours' roles.
  defp disk_scope(nil), do: disk_scope(Fleet.Catalogue.root())
  defp disk_scope(root), do: Fleet.Catalogue.tree_scope(root, :cap_profiles)

  defp read_role_from_disk(role, root) do
    case snapshot_roles(disk_scope(root)) do
      {:ok, index} ->
        case Map.fetch(index, role) do
          {:ok, raw} -> refuse_reserved(role, raw)
          :error -> {:error, :not_found}
        end

      {:error, {:catalogue_missing, _dir}} ->
        {:error, :catalogue_missing}

      {:error, {:invalid_yaml, _path}} ->
        {:error, :invalid_schema}

      {:error, reason} ->
        {:error, reason}
    end
  end

  @doc """
  Lists sorted spawnable names from the global disk search path. The first root wins
  across roots; duplicate names within one root return `:name_collision`.
  `list/1` scans just the supplied directory and returns `:enoent` when it is not a directory.
  """
  @spec list() :: {:ok, [String.t()]} | {:error, term()}
  def list do
    with {:ok, index} <- snapshot_roles(), do: {:ok, spawnable_names(index)}
  end

  @spec list(String.t()) :: {:ok, [String.t()]} | {:error, term()}
  def list(dir) do
    # Distinguish a missing directory from an empty glob; this is not a readability probe.
    if File.dir?(dir) do
      with {:ok, index} <- name_index(dir), do: {:ok, spawnable_names(index)}
    else
      {:error, :enoent}
    end
  end

  # Seats lack spawn assets: exclude raw entries before projecting their names for boot.
  defp spawnable_names(index) do
    index
    |> Enum.filter(fn {_name, raw} -> spawnable?(raw) end)
    |> Enum.map(&elem(&1, 0))
    |> Enum.sort()
  end

  @doc """
  Excludes `kind: ReservedSeat` for both disk and image enumeration. Other kinds, including
  missing or unknown values, return true; this predicate is not schema validation.
  """
  @spec spawnable?(map()) :: boolean()
  def spawnable?(raw) when is_map(raw), do: Map.get(raw, "kind") != "ReservedSeat"

  @doc """
  Returns sorted forge-identity names from `forge_roster/0`, seats included: reserving a
  name requires provisioning its account even though it cannot spawn. Only explicit
  `metadata.forge_identity: false` opts out (writes then use the system account).
  """
  @spec forge_identity_roles() :: {:ok, [String.t()]} | {:error, term()}
  def forge_identity_roles do
    with {:ok, roster} <- forge_roster(), do: {:ok, Enum.map(roster, & &1.name)}
  end

  @doc "Same names, for ONE explicit root — tooling and tests."
  @spec forge_identity_roles(String.t()) :: {:ok, [String.t()]} | {:error, term()}
  def forge_identity_roles(dir) do
    with {:ok, roster} <- forge_roster(dir), do: {:ok, Enum.map(roster, & &1.name)}
  end

  @doc """
  Returns sorted `%{name, seat?, judge?}` records from the default catalogue plus system.
  Explicit forge-identity opt-outs are excluded. `seat?` identifies ReservedSeat;
  `judge?` requires a judge brief and an empty/absent capabilities list, separating
  verdict-only roles from those needing structural write capabilities.
  """
  @spec forge_roster() ::
          {:ok, [%{name: String.t(), seat?: boolean(), judge?: boolean()}]} | {:error, term()}
  def forge_roster do
    # Roster provisioning selects its target via catalogue_root. A global union would mint
    # neighbour roles under the target organisation's prefix.
    with {:ok, index} <- snapshot_roles(disk_scope(nil)), do: {:ok, roster_of(index)}
  end

  @doc "Same roster, for ONE explicit root — tooling and tests."
  @spec forge_roster(String.t()) ::
          {:ok, [%{name: String.t(), seat?: boolean(), judge?: boolean()}]} | {:error, term()}
  def forge_roster(dir) do
    if File.dir?(dir) do
      with {:ok, index} <- name_index(dir), do: {:ok, roster_of(index)}
    else
      {:error, :enoent}
    end
  end

  defp roster_of(index) do
    index
    |> Enum.filter(fn {_name, raw} -> get_in(raw, ["metadata", "forge_identity"]) != false end)
    |> Enum.map(fn {name, raw} ->
      %{
        name: name,
        seat?: not spawnable?(raw),
        judge?:
          get_in(raw, ["spec", "brief_kind"]) == "judge" and
            (get_in(raw, ["spec", "capabilities"]) || []) == []
      }
    end)
    |> Enum.sort_by(& &1.name)
  end

  # Scan only *.yaml and archivistes/*.yaml: frozen monks stay outside boot, modops are overlays.
  # A bad YAML or same-root name collision aborts the index, avoiding silent partial boot.
  # Nameless maps are skipped; '_' suppresses the warning for deliberate fragments.
  defp index_named(acc, path, name, raw) when is_binary(name) and name != "" do
    if Map.has_key?(acc, name) do
      Logger.error("Catalog: metadata.name collision #{inspect(name)} (#{path})")
      {:halt, {:error, :name_collision}}
    else
      {:cont, {:ok, Map.put(acc, name, raw)}}
    end
  end

  defp index_named(acc, path, _sans_nom, _raw) do
    base = Path.basename(path)

    unless String.starts_with?(base, "_") do
      Logger.warning(
        "Catalog: #{base} has no metadata.name — skipped (a role needs a name; " <>
          "`_`-prefix a file that is a deliberate non-role fragment)"
      )
    end

    {:cont, {:ok, acc}}
  end

  defp name_index(dir) do
    files =
      Path.wildcard(Path.join(dir, "*.yaml")) ++
        Path.wildcard(Path.join([dir, "archivistes", "*.yaml"]))

    Enum.reduce_while(files, {:ok, %{}}, fn path, {:ok, acc} ->
      case decode_yaml(path) do
        {:ok, raw} ->
          index_named(acc, path, get_in(raw, ["metadata", "name"]), raw)

        {:error, reason} ->
          Logger.error(
            "Catalog: unreadable YAML #{path} (#{inspect(reason)}) — corrupt catalogue"
          )

          {:halt, {:error, {:invalid_yaml, path}}}
      end
    end)
  end

  @doc """
  Reads ordered modop fragments from the default catalogue's image or disk scope.
  Disk reads check lexical confinement, reserved keys and fragment schema; image reads
  use the already-validated snapshot.
  """
  @spec read_modops([String.t()]) :: {:ok, [map()]} | {:error, term()}
  def read_modops(modop_set) when is_list(modop_set), do: read_modops(modop_set, nil)

  @doc """
  Reads ordered overlays in the named catalogue's scope; nil uses `Fleet.Catalogue.root/0`.
  Missing image entries return `:modop_not_found` without disk fallback or partial composition.
  """
  @spec read_modops([String.t()], Path.t() | nil) :: {:ok, [map()]} | {:error, term()}
  def read_modops(modop_set, root) when is_list(modop_set) do
    case published_for(root) do
      %{overlays: overlays} ->
        Enum.reduce_while(modop_set, {:ok, []}, &overlay_step(&1, &2, overlays))
        |> case do
          {:ok, modops} -> {:ok, Enum.reverse(modops)}
          error -> error
        end

      nil ->
        read_modops_from_disk(modop_set, root)
    end
  end

  # Keep missing files distinct from refused names; the fallback supplies the expected log path.
  defp disk_modop_step(name, {:ok, acc}, scope) do
    found = Enum.find_value(scope, &modop_profile_path(&1, name))
    fallback = Fleet.Slug.confined_join(Path.join(List.first(scope, root_dir()), "modop"), name)

    disk_modop_read(found || fallback, name, acc)
  end

  defp disk_modop_read(path, _name, acc) when is_binary(path) do
    case read_modop_yaml(path) do
      {:ok, raw} -> {:cont, {:ok, [raw | acc]}}
      {:error, reason} -> {:halt, {:error, reason}}
    end
  end

  defp disk_modop_read({:ok, dir}, name, _acc) do
    Logger.warning(
      "Catalog: modop not found: #{inspect(name)} at #{Path.join(dir, "profile.yaml")}"
    )

    {:halt, {:error, :modop_not_found}}
  end

  defp disk_modop_read({:error, _slug_or_escape}, name, _acc) do
    Logger.warning(
      "Catalog: modop name not confined (slug/traversal): #{inspect(name)} — refused"
    )

    {:halt, {:error, :invalid_modop}}
  end

  defp modop_profile_path(root, name) do
    with {:ok, dir} <- Fleet.Slug.confined_join(Path.join(root, "modop"), name),
         path = Path.join(dir, "profile.yaml"),
         true <- File.exists?(path) do
      path
    else
      _ -> nil
    end
  end

  defp read_modops_from_disk(modop_set, catalogue_root) do
    # Include system overlays without admitting neighbouring catalogues; confine at each root.
    scope = disk_scope(catalogue_root)

    result = Enum.reduce_while(modop_set, {:ok, []}, &disk_modop_step(&1, &2, scope))

    case result do
      {:ok, modops} -> {:ok, Enum.reverse(modops)}
      error -> error
    end
  end

  defp overlay_step(name, {:ok, acc}, overlays) do
    case Map.fetch(overlays, name) do
      {:ok, raw} ->
        {:cont, {:ok, [raw | acc]}}

      :error ->
        Logger.warning("Catalog: modop not in the published image: #{inspect(name)}")
        {:halt, {:error, :modop_not_found}}
    end
  end

  # Keep decoding and both validations together for all disk overlay readers.
  defp read_modop_yaml(path) do
    with {:ok, raw} <- decode_yaml(path),
         :ok <- Schema.validate_modop_keys(raw),
         :ok <- Schema.validate(raw, :modop) do
      {:ok, raw}
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
  Returns one directory's raw role index without inherited entries, or `:enoent` if absent.
  Conformance checks use this to distinguish a business declaration from a system fallback.
  """
  @spec index_of(String.t()) :: {:ok, %{optional(String.t()) => map()}} | {:error, term()}
  def index_of(dir) when is_binary(dir) do
    if File.dir?(dir), do: name_index(dir), else: {:error, :enoent}
  end

  @doc """
  Returns the merged live-disk role index over `root_dirs/0` (all installed catalogues).
  """
  @spec snapshot_roles() :: {:ok, %{optional(String.t()) => map()}} | {:error, term()}
  def snapshot_roles, do: snapshot_roles(root_dirs())

  @doc """
  Returns the raw index over an explicit precedence-ordered search path, first root wins.
  Image publication passes one catalogue plus system. An empty path returns
  `{:catalogue_missing, root_dir()}`; missing individual directories merely scan empty.
  """
  @spec snapshot_roles([String.t()]) :: {:ok, %{optional(String.t()) => map()}} | {:error, term()}
  def snapshot_roles([]), do: {:error, {:catalogue_missing, root_dir()}}
  def snapshot_roles(dirs) when is_list(dirs), do: union_indexes(dirs)

  @doc """
  Returns validated live-disk overlays keyed by modop directory name.
  """
  @spec snapshot_overlays() :: {:ok, %{optional(String.t()) => map()}} | {:error, term()}
  def snapshot_overlays, do: snapshot_overlays(root_dirs())

  @doc "The same overlays over an EXPLICIT search path — cf. `snapshot_roles/1`."
  @spec snapshot_overlays([String.t()]) ::
          {:ok, %{optional(String.t()) => map()}} | {:error, term()}
  def snapshot_overlays(dirs) when is_list(dirs) do
    # First root wins; a business overlay can replace its system default.
    dirs
    |> Enum.flat_map(&Path.wildcard(Path.join([&1, "modop", "*/profile.yaml"])))
    |> Enum.reduce_while({:ok, %{}}, &snapshot_step/2)
  end

  # Skip shadowed overlays before reading them, so a broken loser cannot invalidate the winner.
  defp snapshot_step(path, {:ok, acc}) do
    name = path |> Path.dirname() |> Path.basename()

    if Map.has_key?(acc, name) do
      {:cont, {:ok, acc}}
    else
      case read_modop_yaml(path) do
        {:ok, raw} -> {:cont, {:ok, Map.put(acc, name, raw)}}
        {:error, reason} -> {:halt, {:error, {:invalid_overlay, name, reason}}}
      end
    end
  end

  @doc """
  Returns the domain-specific catalogue root or the shared catalogue default.
  """
  @spec root_dir() :: String.t()
  def root_dir do
    Application.get_env(:lcars_fleet, :cap_profile_root_dir) ||
      Fleet.Catalogue.cap_profiles_root()
  end

  @doc """
  Returns existing global search roots: installed business trees, then system.
  The cap_profile_root_dir override replaces the business portion, retaining system fallback.
  """
  @spec root_dirs() :: [String.t()]
  def root_dirs, do: Fleet.Catalogue.search(:cap_profiles)

  # First root wins across roots, but every root is read: a shadowed role's corrupt YAML
  # or a same-root duplicate still fails the scan (unlike shadowed overlay handling).
  defp union_indexes(dirs) do
    Enum.reduce_while(dirs, {:ok, %{}}, fn dir, {:ok, acc} ->
      case name_index(dir) do
        {:ok, index} -> {:cont, {:ok, Map.merge(index, acc)}}
        {:error, reason} -> {:halt, {:error, reason}}
      end
    end)
  end
end
