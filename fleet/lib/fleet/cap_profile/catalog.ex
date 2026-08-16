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

  `root_dir/0` reads the env key `:lcars_fleet, :cap_profile_root_dir` (tests drive it via
  `Application.put_env/3`) — the FINE override, which keeps precedence. Default =
  `Fleet.Catalogue.cap_profiles_root/0`: the bundled canon unless `LCARS_CATALOGUE_ROOT` brings
  another catalogue, and `:code.priv_dir`-derived either way (resolves in a release as in dev,
  without env).
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
  def read_role(role), do: read_role(role, nil)

  @doc """
  Le meme role, lu dans l'image d'un catalogue NOMME — la porte per-catalogue.

  `nil` garde le comportement du jour : l'image du PREMIER catalogue actif. C'est ce que veut un
  appelant sans projet en main ; un appelant qui en a un passe la racine de SON catalogue, parce
  qu'un role n'existe que dans le catalogue qui le declare.
  """
  @spec read_role(String.t(), Path.t() | nil) :: {:ok, map()} | {:error, term()}
  def read_role(role, root) do
    # IMAGE-FIRST (proven-good image at boot): once `Fleet.CapProfile.Image.publish!/0` ran, the
    # image IS the catalogue — a closed world, one epoch for the whole deployment (a disk mutation
    # mid-life changes nothing until a restart republishes). A role absent from the image is
    # `:not_found`, whatever the disk now says. No image (tests' hermetic default, tooling) → the
    # live-disk path below, unchanged.
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

  # A ReservedSeat found by NAME answers its own refusal, never `:not_found` (the seat exists,
  # the box is closed — BL-6-45) and never `:invalid_schema` (validating a seat against the
  # PROFILE schema downstream would misname a declared state as corruption). Lives on BOTH
  # regimes (image branch above, disk branch below): the raw carries its kind in both.
  defp refuse_reserved(role, raw) do
    if spawnable?(raw), do: {:ok, raw}, else: {:error, {:role_reserved, role}}
  end

  # The disk regime reads the SAME SCOPE the image is built from, and the sentence below is the
  # contract this fix re-establishes ONE LEVEL UP from where it was written. It read one root until
  # the system catalogue existed (first divergence, fixed by reading the union); then the images
  # became per-catalogue (2026-08-16) and the union became the NEW divergence: `read_role/2` honored
  # `root` in the image branch and dropped it here, so a caller naming its catalogue got that
  # catalogue's answer with an image and EVERY catalogue's answer without one. Latent while the two
  # shipped catalogues declare disjoint role names; wrong the day two businesses both declare `dev`.
  # Two regimes answering "does this role exist" differently is the defect; that they agree is the
  # contract.
  #
  # `disk_scope/1` mirrors `published_for/1` exactly: a named root reads ITS tree_scope (own
  # cap-profiles + system, the same pair its image is published from), nil reads the FIRST installed
  # catalogue's — because `published_for(nil)` answers the first catalogue's image, and the disk
  # must not answer more than the image would.
  defp disk_scope(nil), do: disk_scope(List.first(Fleet.Catalogue.installed_roots()))
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
  Lists the NAMES (`metadata.name`) of the deployment's cap-profiles — the SYSTEM root and the
  business root unioned. `list/1` keeps a single explicit root, for tooling and tests.

  **SINGLE SOURCE**: every enumerator (`Fleet.Spawner.PermanentBoot`) AND `Fleet.CapProfile.load/1`
  resolve by THIS key — the `name` prop, **never** the filename (cosmetic). Sorted.
  A `name` collision between two files → `{:error, :name_collision}`; the same name held by BOTH
  catalogues → `{:error, {:root_collision, names}}` (fail-loud both ways: no silent resolution at
  the whim of the filesystem, and no catalogue quietly redefining a system role).
  """
  @spec list() :: {:ok, [String.t()]} | {:error, term()}
  def list do
    with {:ok, index} <- snapshot_roles(), do: {:ok, spawnable_names(index)}
  end

  @spec list(String.t()) :: {:ok, [String.t()]} | {:error, term()}
  def list(dir) do
    # Absent/unreadable dir = error (broken config) — distinct from an empty catalogue ({:ok, []}).
    # `Path.wildcard` conflates the two; `File.dir?` decides. (`load/1`/`compose/2` go through
    # `read_role`, which ALSO checks `File.dir?` first → an absent dir there gives `:catalogue_missing`
    # (same broken-config signal as here), NOT `:not_found`.)
    if File.dir?(dir) do
      with {:ok, index} <- name_index(dir), do: {:ok, spawnable_names(index)}
    else
      {:error, :enoent}
    end
  end

  # Filter on the ENTRIES ({name, raw}) BEFORE projecting the keys — the predicate reads the raw's
  # kind, `Map.keys/1` would hand it strings. An unfiltered list feeds a ReservedSeat to every
  # enumerator (CanonProof, PermanentBoot) → the seat has no SP draft → fleet.boot_failed. Filter
  # BEFORE enumerate (BL-6-45).
  defp spawnable_names(index) do
    index
    |> Enum.filter(fn {_name, raw} -> spawnable?(raw) end)
    |> Enum.map(&elem(&1, 0))
    |> Enum.sort()
  end

  @doc """
  Is this raw catalogue entry a SPAWNABLE profile? (`kind` ≠ `ReservedSeat` — BL-6-45.)
  The ONE predicate both enumeration projections apply (`list/1` here,
  `Fleet.CapProfile.list_from_published/0` on the image index): two projections, one rule.
  """
  @spec spawnable?(map()) :: boolean()
  def spawnable?(raw) when is_map(raw), do: Map.get(raw, "kind") != "ReservedSeat"

  @doc """
  Role names this catalogue declares a FORGE IDENTITY for — the account-and-token roster, sorted.

  ## Why this is NOT `list/1` filtered

  `list/1` drops ReservedSeats because a seat has no SP draft and would break every enumerator that
  spawns. **A seat still owns a forge account**: it is a name held so nobody else takes it, which is
  only true if the account exists. So this enumeration keeps them, and `spawnable?/1` has no
  business here. The two projections answer different questions — "who can be spawned" and "who owns
  an account" — and conflating them is what makes a roster silently short by exactly the seats.

  The inclusion is what `provisioning_locked` already measures ("seats included"); this function is
  where that rule becomes readable at runtime instead of living only in a repo-time check.

  `metadata.forge_identity: false` is the explicit opt-out — an orchestrator whose forge writes all
  go through the system account. Absent = `true`.
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
  The forge roster with the three facts a provisioning needs to place each role, sorted by name.

  `%{name, seat?, judge?}` — `seat?` is `kind == "ReservedSeat"`, `judge?` is a role that only
  judges: `brief_kind: judge` AND no structural capability. Everything else writes.

  Why these three and not the whole profile: they are exactly what distinguishes an account that
  holds a name (a seat), one that renders verdicts, and one that puts something in the repository.
  A provisioning that knew more would start deciding with it.
  """
  @spec forge_roster() ::
          {:ok, [%{name: String.t(), seat?: boolean(), judge?: boolean()}]} | {:error, term()}
  def forge_roster do
    # THE catalogue in hand plus the system half — never the union of every installed catalogue.
    # The zero-arity's one production caller is `CatalogueRoles.tfvars/1`, which names its target
    # through the big wheel (`:catalogue_root`) before calling: `disk_scope(nil)` resolves to that
    # root + system, which is exactly the split tfvars derives accounts from. On the UNION, a box
    # with a second catalogue installed would have folded B's roles into A's roster at install
    # time — and the login projection prefixes with the TARGET org, so the recipe would have minted
    # `A_<role-of-B>` accounts that belong to nobody. Found by pulling the audit's search/1 thread;
    # latent only because the install's first pass runs before the cache holds a neighbour.
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
  def read_modops(modop_set) when is_list(modop_set), do: read_modops(modop_set, nil)

  @doc """
  Les memes overlays, dans l'image du catalogue NOMME — `nil` = le premier actif.

  Un modop appartient au catalogue qui le livre : celui d'un role du second catalogue n'existe pas
  dans l'image du premier, et le chercher la rendait `:modop_not_found` sur un fichier bien present.
  """
  @spec read_modops([String.t()], Path.t() | nil) :: {:ok, [map()]} | {:error, term()}
  def read_modops(modop_set, root) when is_list(modop_set) do
    case published_for(root) do
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
        read_modops_from_disk(modop_set, root)
    end
  end

  defp read_modops_from_disk(modop_set, catalogue_root) do
    # Same scope as `read_role_from_disk/2`, same reason: a modop belongs to the catalogue that
    # ships it, and the mechanism ones live in the system half of the scope — which is why the
    # scope is a PAIR (own + system) and never one root alone: reading only the business root made
    # every hermetic test see a role whose default overlay had vanished. The name stays confined
    # under EACH root — trying a second one must not weaken what makes an untrusted name safe as a
    # path segment.
    scope = disk_scope(catalogue_root)

    result =
      Enum.reduce_while(modop_set, {:ok, []}, fn name, {:ok, acc} ->
        found =
          Enum.find_value(scope, fn root ->
            case Fleet.Slug.confined_join(Path.join(root, "modop"), name) do
              {:ok, dir} ->
                path = Path.join(dir, "profile.yaml")
                if File.exists?(path), do: path, else: nil

              {:error, _} ->
                nil
            end
          end)

        case found ||
               Fleet.Slug.confined_join(Path.join(List.first(scope, root_dir()), "modop"), name) do
          path when is_binary(path) ->
            with {:ok, raw} <- decode_yaml(path),
                 :ok <- Schema.validate_modop_keys(raw),
                 :ok <- Schema.validate(raw, :modop) do
              {:cont, {:ok, [raw | acc]}}
            else
              {:error, reason} -> {:halt, {:error, reason}}
            end

          {:ok, dir} ->
            Logger.warning(
              "Catalog: modop not found: #{inspect(name)} at #{Path.join(dir, "profile.yaml")}"
            )

            {:halt, {:error, :modop_not_found}}

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
  The raw role index of ONE root — used to judge a catalogue's own roles apart from what it
  inherits. Every other reader wants the union; the conformance check is the one caller that must
  see the business half alone, because "this catalogue declares a system capability" is only a
  question about what IT declares.
  """
  @spec index_of(String.t()) :: {:ok, %{optional(String.t()) => map()}} | {:error, term()}
  def index_of(dir) when is_binary(dir) do
    if File.dir?(dir), do: name_index(dir), else: {:error, :enoent}
  end

  @doc """
  Returns the live disk role index used to build an image.
  """
  @spec snapshot_roles() :: {:ok, %{optional(String.t()) => map()}} | {:error, term()}
  def snapshot_roles, do: snapshot_roles(root_dirs())

  @doc """
  The same index over an EXPLICIT search path — one catalogue's, rather than every active one merged.

  `snapshot_roles/0` answers "everything this deployment can see", which a global view wants. A
  PROJECT wants its own catalogue over the system and nothing from its neighbours, and that path is
  `Fleet.Catalogue.scopes(:cap_profiles)`.
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
    # Search path, precedence order, FIRST WINS — same rule as the roles and the SP fragments. A
    # business `rubber-duck` overlay replaces the system's; declaring nothing is the point.
    dirs
    |> Enum.flat_map(&Path.wildcard(Path.join([&1, "modop", "*/profile.yaml"])))
    |> Enum.reduce_while({:ok, %{}}, fn path, {:ok, acc} ->
      name = path |> Path.dirname() |> Path.basename()

      if Map.has_key?(acc, name) do
        {:cont, {:ok, acc}}
      else
        with {:ok, raw} <- decode_yaml(path),
             :ok <- Schema.validate_modop_keys(raw),
             :ok <- Schema.validate(raw, :modop) do
          {:cont, {:ok, Map.put(acc, name, raw)}}
        else
          {:error, reason} -> {:halt, {:error, {:invalid_overlay, name, reason}}}
        end
      end
    end)
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
  The cap-profile roots actually read: the SYSTEM one, then the business one.

  The fine override (`:lcars_fleet, :cap_profile_root_dir`) moves the BUSINESS root only. The system root
  has no knob on purpose — an operator brings their business, they do not choose the mechanism, and
  an override that could drop the machinery would make "this deployment is complete" unanswerable.

  Absent directories are dropped so a test root or a narrow catalogue does not have to exist twice.
  """
  @spec root_dirs() :: [String.t()]
  def root_dirs, do: Fleet.Catalogue.search(:cap_profiles)

  # Union of the search path's role indexes, in PRECEDENCE order — the first root that carries a
  # name wins, and the later one is not read.
  #
  # It REFUSED a name held on both sides until 2026-08-10. Refusing made overriding impossible,
  # which is the opposite of what a default catalogue is for: a business catalogue that ships its
  # own `architect.yaml` means to replace the system's, and it should not have to declare it — the
  # child-theme rule, and the reason a search path costs nothing to extend.
  #
  # A collision INSIDE one root stays a refusal (`name_index/1`): two files claiming one name in the
  # same catalogue is an ambiguity its author can only have made by accident.
  defp union_indexes(dirs) do
    Enum.reduce_while(dirs, {:ok, %{}}, fn dir, {:ok, acc} ->
      case name_index(dir) do
        {:ok, index} -> {:cont, {:ok, Map.merge(index, acc)}}
        {:error, reason} -> {:halt, {:error, reason}}
      end
    end)
  end
end
