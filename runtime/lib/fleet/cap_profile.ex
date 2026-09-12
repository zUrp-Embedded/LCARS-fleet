defmodule Fleet.CapProfile do
  use Boundary,
    deps: [
      Fleet.Opts,
      Fleet.Slug,
      Fleet.EnvParse,
      Fleet.GitRef,
      Fleet.Layout,
      Fleet.Catalogue,
      Fleet.Event,
      Fleet.SchemaCache
    ],
    exports: []

  @moduledoc """
  Loads and composes capability profiles and exposes their policy accessors.

  `load/1,2`, `compose/2` and `from_map/1` validate structure against the bundled
  `priv/cap_profile/schema/cap-profile.json`; semantic checks remain a separate
  `validate/1` call. Use these constructors (or `from_map!/1` in fixtures): direct
  struct construction bypasses validation, as do runtime updates such as `with_project/2`.

  Schema versions belong to the code, not YAML declarations. Modops use the strict
  `modop-profile.json` schema, which forbids overriding base containment/name/kind.
  Composition deep-merges in declared order, last value winning. Canonical encoding
  and hashing live in `CanonicalJson`; semantic invariants live in `Invariants`.

  Catalogue resolution can read disk or a published image; forge login maps are cached
  in persistent_term. Callers should use the accessors rather than duplicate field policy.
  """

  @behaviour Fleet.CapProfile.Loader

  require Logger

  alias Fleet.CapProfile.CanonicalJson
  alias Fleet.CapProfile.Catalog
  alias Fleet.CapProfile.DisallowedTools
  alias Fleet.CapProfile.Image
  alias Fleet.CapProfile.Schema
  alias Fleet.Catalogue

  @enforce_keys [:kind, :metadata, :spec]
  # Runtime provenance stays outside schema data: active_modops varies by step, and nil
  # means unresolved (active_modops/1 falls back to defaults). catalogue_root pins the
  # source of modops/SP/draft; nil selects the first installed catalogue.
  defstruct [:kind, :metadata, :spec, :active_modops, :catalogue_root]

  @type t :: %__MODULE__{
          kind: String.t(),
          metadata: map(),
          spec: map(),
          active_modops: [String.t()] | nil,
          catalogue_root: Path.t() | nil
        }

  @default_containment "bwrap"
  # Missing network policy must not request unrestricted egress.
  @default_network "vendor-only"

  @doc "Publishes the validated catalogue image, raising on an invalid artifact."
  @spec publish_image!() :: :ok
  defdelegate publish_image!(), to: Fleet.CapProfile.Image, as: :publish!

  @doc """
  Loads a profile by `metadata.name` and validates its structure against the schema.
  Semantic invariants are checked separately by `validate/1` at the spawn boundary.
  """
  @impl Fleet.CapProfile.Loader
  @spec load(String.t()) :: {:ok, t()} | {:error, atom() | String.t()}
  def load(role) when is_binary(role), do: load(role, nil)

  # Preserve the requested catalogue when supported; load/1-only stubs retain their fallback.
  defp load_in(loader, role, root) do
    if root && Fleet.Opts.exported?(loader, :load, 2),
      do: loader.load(role, root),
      else: loader.load(role)
  end

  @doc """
  Loads and structurally validates a role from the given catalogue, retaining that root
  on the profile. `nil` selects the first installed catalogue.
  """
  @spec load(String.t(), Path.t() | nil) :: {:ok, t()} | {:error, term()}
  def load(role, root) when is_binary(role) do
    with {:ok, raw} <- Catalog.read_role(role, root),
         :ok <- Schema.validate(raw, :cap_profile) do
      {:ok, to_struct(raw, root)}
    end
  end

  @doc """
  Deep-merges modops in order (last wins), then validates the result's structure.
  A struct preserves the loaded base and its catalogue root; modops are read from that
  catalogue. A role name first loads its base from the default catalogue.
  """
  @impl Fleet.CapProfile.Loader
  @spec compose(t() | String.t(), [String.t()]) :: {:ok, t()} | {:error, term()}
  def compose(role_or_base, modop_set)

  def compose(%__MODULE__{} = base, modop_set) when is_list(modop_set) do
    raw = %{"kind" => base.kind, "metadata" => base.metadata, "spec" => base.spec}

    with {:ok, modops} <- Catalog.read_modops(modop_set, base.catalogue_root),
         merged <- Enum.reduce(modops, raw, &deep_merge_last_wins(&2, &1)),
         :ok <- Schema.validate(merged, :cap_profile) do
      # Dropping provenance would redirect downstream readers to the default catalogue.
      {:ok, to_struct(merged, base.catalogue_root)}
    end
  end

  def compose(role, modop_set) when is_binary(role) and is_list(modop_set) do
    with {:ok, base} <- load(role), do: compose(base, modop_set)
  end

  @doc "Returns `spec.modop_set.default`, or `[]` when absent or malformed."
  @spec default_modops(t()) :: [String.t()]
  def default_modops(%__MODULE__{spec: spec}) do
    case spec do
      %{"modop_set" => %{"default" => defaults}} when is_list(defaults) -> defaults
      _ -> []
    end
  end

  @doc """
  Returns whether the profile explicitly declares `cap` in `spec.capabilities`.
  Missing or malformed capability data returns `false`.
  """
  @spec has_capability?(t(), atom() | String.t()) :: boolean()
  def has_capability?(%__MODULE__{spec: spec}, cap) do
    want = to_string(cap)

    case spec do
      %{"capabilities" => caps} when is_list(caps) -> want in caps
      _ -> false
    end
  end

  @doc """
  Returns sorted spawnable roles declaring `cap`, excluding reserved seats.
  Uses the published image when available, otherwise reads the catalogue and warns
  about profiles omitted because loading failed. Callers enforce uniqueness if needed.
  """
  @spec roles_with_capability(atom() | String.t()) :: {:ok, [String.t()]} | {:error, term()}
  def roles_with_capability(cap) do
    case Image.published() do
      %{index: index} ->
        # Match Catalog.list's seat exclusion locally, even if the seat schema evolves.
        {:ok,
         index
         |> Enum.filter(fn {_role, raw} ->
           Catalog.spawnable?(raw) and raw_has_capability?(raw, cap)
         end)
         |> Enum.map(&elem(&1, 0))
         |> Enum.sort()}

      nil ->
        with {:ok, roles} <- list() do
          {:ok, Enum.filter(roles, &role_declares?(&1, cap))}
        end
    end
  end

  defp role_declares?(role, cap) do
    case load(role) do
      {:ok, profile} ->
        has_capability?(profile, cap)

      {:error, reason} ->
        # Preserve the load failure behind a caller's later "no role declares X" error.
        Logger.warning(
          "CapProfile: role #{inspect(role)} does NOT load (#{inspect(reason)}) while resolving " <>
            "capability #{inspect(cap)} — it counts as not declaring it; a structural resolver " <>
            "will fail loud naming the capability, the real cause is this profile"
        )

        false
    end
  end

  defp raw_has_capability?(raw, cap) do
    want = to_string(cap)

    case raw do
      %{"spec" => %{"capabilities" => caps}} when is_list(caps) -> want in caps
      _ -> false
    end
  end

  @doc """
  Resolves a profile from its base, default modops and optional step modops.

  Extra modops must be declared optional; when present, the complete active set must contain
  no incompatible pair. The result records that set for `SPBuilder.compose/3`. A loader without
  `compose/2` returns its fixed base with the active set stamped, which supports test stubs.
  Semantic validation remains separate; without extras, compatibility is not checked here.
  """
  @spec resolve(module(), String.t(), [String.t()], Path.t() | nil) ::
          {:ok, t()} | {:error, term()}
  def resolve(loader, role, extra_modops \\ [], root \\ nil)
      when is_atom(loader) and is_binary(role) and is_list(extra_modops) do
    with {:ok, base} <- load_in(loader, role, root),
         :ok <- validate_extra_modops(base, extra_modops) do
      compose_or_stamp(loader, base, default_modops(base) ++ extra_modops)
    end
  end

  # Stamp even a stub's base so SPBuilder can recover the chosen active set.
  defp compose_or_stamp(loader, base, active) do
    if Fleet.Opts.exported?(loader, :compose, 2) do
      with {:ok, composed} <- loader.compose(base, active),
           do: {:ok, %{composed | active_modops: active}}
    else
      {:ok, %{base | active_modops: active}}
    end
  end

  @doc "Returns the resolved active modops, falling back to declared defaults when unresolved."
  @spec active_modops(t()) :: [String.t()]
  def active_modops(%__MODULE__{active_modops: mods}) when is_list(mods), do: mods
  def active_modops(%__MODULE__{} = profile), do: default_modops(profile)

  defp validate_extra_modops(_base, []), do: :ok

  defp validate_extra_modops(%__MODULE__{} = base, extra) do
    optional = optional_modops(base)

    case Enum.reject(extra, &(&1 in optional)) do
      [] -> check_incompatible(base, default_modops(base) ++ extra)
      out -> {:error, {:modops_not_in_optional, out}}
    end
  end

  defp optional_modops(%__MODULE__{spec: spec}) do
    case spec do
      %{"modop_set" => %{"optional" => opt}} when is_list(opt) -> opt
      _ -> []
    end
  end

  defp check_incompatible(%__MODULE__{spec: spec}, active) do
    pairs =
      case spec do
        %{"modop_set" => %{"incompatible" => p}} when is_list(p) -> p
        _ -> []
      end

    active_set = MapSet.new(active)

    Enum.find_value(pairs, :ok, fn
      [a, b] ->
        if a in active_set and b in active_set,
          do: {:error, {:modops_incompatible, [a, b]}},
          else: nil

      _ ->
        nil
    end)
  end

  @doc """
  Validates the pure semantic invariants defined by `Fleet.CapProfile.Invariants`.
  Returns `:ok` or `{:error, violations}`.
  """
  @impl Fleet.CapProfile.Loader
  @spec validate(t()) :: :ok | {:error, [atom()]}
  def validate(%__MODULE__{} = profile) do
    case Fleet.CapProfile.Invariants.violations(profile) do
      [] -> :ok
      violations -> {:error, violations}
    end
  end

  @doc """
  Validates an in-memory map against the same schema as `load/1` and constructs a profile.
  """
  @spec from_map(map()) :: {:ok, t()} | {:error, atom() | String.t()}
  def from_map(raw) when is_map(raw) do
    with :ok <- Schema.validate(raw, :cap_profile) do
      {:ok, to_struct(raw)}
    end
  end

  @doc """
  Returns a validated profile or raises `ArgumentError` for a nonconformant map.
  """
  @spec from_map!(map()) :: t()
  def from_map!(raw) do
    case from_map(raw) do
      {:ok, profile} ->
        profile

      {:error, reason} ->
        raise ArgumentError,
              "CapProfile.from_map!/1: map not schema-conformant (#{inspect(reason)}) — " <>
                "a nominal fixture must be a complete profile (cf. Fleet.Support.CapProfileFixture)"
    end
  end

  @doc "Translates `spec.scope.git_ops_denied` into Claude disallowed-tool patterns."
  @spec git_ops_denied_patterns(t()) :: [String.t()]
  defdelegate git_ops_denied_patterns(profile), to: DisallowedTools

  @doc """
  Resolves `spec.scope.disallowedTools` from existing entries, the universal baseline
  and profile-specific git restrictions. The merge is ordered, unique and idempotent.
  """
  @spec with_resolved_disallowed_tools(t()) :: t()
  defdelegate with_resolved_disallowed_tools(profile), to: DisallowedTools, as: :with_resolved

  @doc "Returns the universal git-denial patterns, raising if the baseline is invalid."
  @spec baseline_git_ops_denied_patterns() :: [String.t()]
  defdelegate baseline_git_ops_denied_patterns(), to: DisallowedTools, as: :baseline_patterns

  # Dispatch supplies these keys after schema validation. Keeping them out of the
  # catalogue schema avoids authoring values that dispatch would silently overwrite.
  @runtime_project_keys ~w(repo base_sha gate_base_sha pr_base_branch)

  @doc """
  Lists runtime project keys excluded from the catalogue schema. The contracts check
  checks project keys against this list and the schema; `with_project/2` does not enforce it.
  """
  @spec runtime_project_keys() :: [String.t()]
  def runtime_project_keys, do: @runtime_project_keys

  @doc """
  Replaces `spec.project` with an effective project whose keys are recursively stringified.

  Intended for catalogue fields plus `runtime_project_keys/0`; accepts any map without
  checking keys or revalidating the schema.
  """
  @spec with_project(t(), map()) :: t()
  def with_project(%__MODULE__{spec: spec} = cap, project) when is_map(project),
    do: %{cap | spec: Map.put(spec, "project", stringify_keys(project))}

  @doc """
  Returns `metadata.containment`, defaulting to sandboxed `"bwrap"` when absent.
  """
  @spec containment(t()) :: String.t()
  def containment(%__MODULE__{metadata: meta}) when is_map(meta),
    do: Map.get(meta, "containment") || @default_containment

  def containment(%__MODULE__{}), do: @default_containment

  @doc """
  Returns the declared network policy, defaulting to `"vendor-only"`.
  It is independent of lifetime and slot scope: network needs must not change pod identity.

  For bwrap pods, `Fleet.Spawner.Pod.Egress` applies this policy at the CONNECT proxy:
  `"egress"` adds declared hosts to vendor hosts; `"open"` removes the host allowlist,
  retaining the proxy and network namespace isolation. Host-native containment does not
  provide that isolation. This accessor requests policy; it does not enforce networking.
  """
  @spec network(t()) :: String.t()
  def network(%__MODULE__{metadata: meta}) when is_map(meta),
    do: Map.get(meta, "network") || @default_network

  def network(%__MODULE__{}), do: @default_network

  @doc "Returns the default network policy, `\"vendor-only\"` (fail-closed)."
  @spec default_network() :: String.t()
  def default_network, do: @default_network

  @doc "Returns the default containment mode, `\"bwrap\"`."
  @spec default_containment() :: String.t()
  def default_containment, do: @default_containment

  @doc """
  Returns whether terminal send-keys wake/engage is allowed. Defaults to `true`, including
  for absent or non-profile input; `false` protects interactive human-facing terminals.
  """
  @spec wake_send_keys?(term()) :: boolean()
  def wake_send_keys?(%__MODULE__{spec: spec}) when is_map(spec),
    do: get_in(spec, ["invocation", "wake_send_keys"]) != false

  def wake_send_keys?(_), do: true

  @doc """
  Returns the profile's Desktop remote-control preference. An explicit boolean wins;
  absent or invalid values default to true for project slots and false for instance slots,
  avoiding a Desktop slot for every ticket. Non-profile input returns true.

  Semantic invariant `g24_16` requires a declaration for project slots; structural loading
  alone does not run that check. `Fleet.Spawner.Pod.LaunchSpec.remote_control?/1` adds the
  fleet debug override to determine effective launch and slot-capture policy.
  """
  @spec remote_control?(term()) :: boolean()
  def remote_control?(%__MODULE__{spec: spec} = profile) when is_map(spec) do
    case get_in(spec, ["invocation", "remote_control"]) do
      declared when is_boolean(declared) -> declared
      _absent_or_invalid -> slot_scope(profile) == "project"
    end
  end

  def remote_control?(_), do: true

  @doc """
  Returns the output-compression preference; absent/invalid values and non-profiles return true.
  Roles needing full output can opt out. `LaunchSpec.output_compression?/1` combines this
  with the fleet switch using AND, so the fleet cannot impose information loss on an opted-out
  role. These policy helpers do not themselves install a compression hook.
  """
  @spec output_compression?(term()) :: boolean()
  def output_compression?(%__MODULE__{spec: spec}) when is_map(spec) do
    case get_in(spec, ["invocation", "output_compression"]) do
      declared when is_boolean(declared) -> declared
      _absent_or_invalid -> true
    end
  end

  def output_compression?(_), do: true

  @doc """
  Returns whether the role declares its own forge identity; only explicit false opts out.
  Such roles write through the system account: absence of a role token is intentional,
  not a provisioning failure. This reads policy, not actual account/token availability.
  """
  @spec forge_identity?(t()) :: boolean()
  def forge_identity?(%__MODULE__{metadata: meta}) when is_map(meta),
    do: Map.get(meta, "forge_identity", true) != false

  def forge_identity?(_), do: true

  @doc """
  Returns whether containment is `"bwrap"` (the default). For schema-valid profiles,
  false means `"none"`, running on the host as the human; unknown values also return false.
  """
  @spec bwrap?(t()) :: boolean()
  def bwrap?(%__MODULE__{} = cap), do: containment(cap) == @default_containment

  @doc """
  Returns non-empty `metadata["name"]`, raising otherwise. Constructors stringify keys;
  this guard also catches malformed hand-built profiles rather than inventing an identity.
  """
  @spec name(t()) :: String.t()
  def name(%__MODULE__{metadata: %{"name" => name}}) when is_binary(name) and byte_size(name) > 0,
    do: name

  def name(%__MODULE__{}), do: raise(ArgumentError, "CapProfile without a name — forbidden state")

  @doc """
  Extracts a requested profile name from a string-keyed DTO. `cap_profile_name` takes
  precedence over `role`; blank and non-string values are ignored.
  """
  @spec name_from_request(map()) :: String.t() | nil
  def name_from_request(dto) when is_map(dto) do
    blank_to_nil(Map.get(dto, "cap_profile_name")) || blank_to_nil(Map.get(dto, "role"))
  end

  defp blank_to_nil(v) when is_binary(v) and v != "", do: v
  defp blank_to_nil(_), do: nil

  @doc """
  Returns `metadata.role_index` in `0..15`, raising when absent or invalid.
  Use `catalogued?/1` when absence is an expected branch.
  """
  @spec role_index(t()) :: 0..15
  def role_index(%__MODULE__{metadata: %{"role_index" => r}}) when is_integer(r) and r in 0..15,
    do: r

  def role_index(%__MODULE__{}),
    do:
      raise(
        ArgumentError,
        "CapProfile without a valid role_index (integer 0..15) — not a catalogued role"
      )

  @doc """
  Returns declared `invocation.slot_scope` when `"instance"` or `"project"`.
  Otherwise derives it from lifetime: `"one-shot"` (including the missing-field default)
  gives `"instance"`; every other value gives `"project"`.

  StepDispatcher uses this to choose per-ticket or per-project PodId keying. An explicit
  instance scope lets a context-long producer retain context across rework rounds while
  keeping tickets separate; lifetime alone would give those tickets the same project identity.
  """
  @spec slot_scope(t()) :: String.t()
  def slot_scope(%__MODULE__{spec: spec} = profile) do
    case get_in(spec, ["invocation", "slot_scope"]) do
      scope when scope in ["instance", "project"] ->
        scope

      _ ->
        case lifetime_scope(profile) do
          "one-shot" -> "instance"
          _context_long -> "project"
        end
    end
  end

  @doc """
  Returns the kill/harvest class encoded in the session ID's first nibble, in priority order:
  role index zero → 0; project slot → 1; judge brief → 3; missing brief → 1 with a warning;
  otherwise → 2. A valid role index is required (`role_index/1` raises otherwise).

  Project conversations take precedence over judge classification. Mission comes from
  `brief_kind`, not lifetime: both producers and judges can be disposable. The classes
  prioritize preserving human context, then ticket work, then a verdict pass.
  Process kill patterns must anchor on `claude.*` to avoid matching other commands' argv
  (see `Fleet.Spawner.SessionId`).
  """
  @spec kill_class(t()) :: 0..3
  def kill_class(%__MODULE__{} = profile) do
    cond do
      role_index(profile) == 0 ->
        0

      # Project slots must survive routine judge harvesting, even for a judge profile.
      slot_scope(profile) == "project" ->
        1

      brief_kind(profile) == "judge" ->
        3

      # Missing schema-required mission must not silently classify a malformed judge as producer.
      is_nil(brief_kind(profile)) ->
        Logger.warning(
          "CapProfile: #{inspect(name(profile))} has NO `brief_kind` — the schema requires it, so " <>
            "this profile was not loaded through the catalogue. Filed under class 1 (the most " <>
            "expensive) rather than guessed: judge-ness is never inferred."
        )

        1

      true ->
        2
    end
  end

  @doc "Returns whether the profile has a valid catalogued `role_index` in `0..15`."
  @spec catalogued?(t()) :: boolean()
  def catalogued?(%__MODULE__{metadata: meta}) when is_map(meta) do
    r = Map.get(meta, "role_index")
    is_integer(r) and r in 0..15
  end

  def catalogued?(%__MODULE__{}), do: false

  @doc "Returns the lowercase SHA-256 of the recursively key-sorted canonical JSON."
  @spec sha256(t() | map()) :: String.t()
  def sha256(%__MODULE__{} = profile), do: profile |> struct_to_map() |> sha256()
  def sha256(map) when is_map(map), do: CanonicalJson.sha256(map)

  @doc "Lists catalogue profile names, optionally below `dir`."
  @spec list(String.t()) :: {:ok, [String.t()]} | {:error, term()}
  @spec list() :: {:ok, [String.t()]} | {:error, term()}
  defdelegate list(), to: Catalog
  defdelegate list(dir), to: Catalog

  @doc """
  Role names this catalogue declares a forge identity for — the roster to provision, seats INCLUDED.

  Distinct from `list/1`, which drops ReservedSeats: a seat cannot be spawned but still owns its
  account. See `Catalog.forge_identity_roles/1`.
  """
  @spec forge_identity_roles(String.t()) :: {:ok, [String.t()]} | {:error, term()}
  @spec forge_identity_roles() :: {:ok, [String.t()]} | {:error, term()}
  defdelegate forge_identity_roles(), to: Catalog
  defdelegate forge_identity_roles(dir), to: Catalog

  @doc """
  Resolves a role to `<tier>_<role>` for both provisioning and runtime forge requests.
  System-roster membership fixes the system prefix even when a business catalogue overlays
  that role; other roles use the first declaring installed catalogue's name.

  Returns an error for an unknown role or a failed system-roster read. Unreadable business
  rosters contribute no names. Invalid role syntax or logins over 40 bytes raise.
  Successful maps are cached by installed roots and system root, not file contents.
  """
  @spec forge_login(String.t()) :: {:ok, String.t()} | {:error, term()}
  def forge_login(role) when is_binary(role) do
    with {:ok, %{to_login: to_login}} <- login_maps() do
      case Map.fetch(to_login, role) do
        {:ok, login} -> {:ok, login}
        :error -> {:error, {:role_not_in_roster, role}}
      end
    end
  end

  @doc """
  Resolves a forge login case-insensitively using the same map as `forge_login/1`.
  Unknown logins return `{:error, {:login_not_a_role, login}}`; map-building failures propagate.
  Never return an unknown login as a role: that would admit foreign reviewers to the jury.
  """
  @spec role_of_forge_login(String.t()) :: {:ok, String.t()} | {:error, term()}
  def role_of_forge_login(login) when is_binary(login) do
    with {:ok, %{to_role: to_role}} <- login_maps() do
      case Map.fetch(to_role, String.downcase(login)) do
        {:ok, role} -> {:ok, role}
        :error -> {:error, {:login_not_a_role, login}}
      end
    end
  end

  # Provisioning's measured username limit; roles exclude '_' to preserve the tier separator.
  @login_max 40
  @role_rx ~r/\A[a-z0-9][a-z0-9-]*\z/

  defp login_maps do
    # The default root alone misses changes to the installed set (including test fixtures).
    key =
      {__MODULE__, :forge_logins, Catalogue.installed_roots(), Catalogue.system_root()}

    case :persistent_term.get(key, :unset) do
      %{} = maps ->
        {:ok, maps}

      :unset ->
        with {:ok, maps} <- build_login_maps() do
          :persistent_term.put(key, maps)
          {:ok, maps}
        end
    end
  end

  # Resolve each declaring catalogue's tier; system membership overrides business overlays.
  defp build_login_maps do
    system_dir = Path.join(Catalogue.system_root(), Catalogue.rel(:cap_profiles))

    with {:ok, system_roster} <- forge_roster(system_dir) do
      system_names = MapSet.new(system_roster, & &1.name)

      to_login =
        Catalogue.installed_catalogues()
        |> Enum.reduce(%{}, &catalogue_logins(&1, &2, system_names))
        # The system roles themselves, for a deployment whose business catalogues declare none.
        |> then(fn acc ->
          Enum.reduce(system_roster, acc, &put_login(&2, &1.name, system_names, "system"))
        end)

      {:ok,
       %{to_login: to_login, to_role: Map.new(to_login, fn {r, l} -> {String.downcase(l), r} end)}}
    end
  end

  defp catalogue_logins(%{name: cat, root: root}, acc, system_names) do
    dir = Path.join(root, Catalogue.rel(:cap_profiles))

    case forge_roster(dir) do
      {:ok, roster} -> Enum.reduce(roster, acc, &put_login(&2, &1.name, system_names, cat))
      {:error, _} -> acc
    end
  end

  defp put_login(acc, role, system_names, catalogue) do
    prefix = if MapSet.member?(system_names, role), do: "system", else: catalogue
    Map.put_new(acc, role, compose_login(prefix, role))
  end

  defp compose_login(prefix, role) do
    unless Regex.match?(@role_rx, role) do
      raise ArgumentError,
            "CapProfile.forge_login: role #{inspect(role)} is not kebab-case — it becomes half of " <>
              "a forge login (#{prefix}_#{role}) and `_` separates the two halves."
    end

    login = "#{prefix}_#{role}"

    if byte_size(login) > @login_max do
      raise ArgumentError,
            "CapProfile.forge_login: login #{inspect(login)} is #{byte_size(login)} chars — Gitea " <>
              "caps a username at #{@login_max} (measured)."
    end

    login
  end

  @doc """
  The raw role index of ONE root — the business half judged apart from what it inherits.
  See `Catalog.index_of/1`.
  """
  @spec index_of(String.t()) :: {:ok, %{optional(String.t()) => map()}} | {:error, term()}
  defdelegate index_of(dir), to: Catalog

  @doc """
  The forge roster with the facts a provisioning needs to place each role — `%{name, seat?,
  judge?}`. See `Catalog.forge_roster/1`.
  """
  @spec forge_roster(String.t()) ::
          {:ok, [%{name: String.t(), seat?: boolean(), judge?: boolean()}]} | {:error, term()}
  @spec forge_roster() ::
          {:ok, [%{name: String.t(), seat?: boolean(), judge?: boolean()}]} | {:error, term()}
  defdelegate forge_roster(), to: Catalog
  defdelegate forge_roster(dir), to: Catalog

  @doc """
  Returns sorted role names from the published image, or `{:error, :not_published}`.
  """
  @spec list_from_published() :: {:ok, [String.t()]} | {:error, :not_published}
  def list_from_published, do: list_from_published(nil)

  @doc """
  Returns sorted spawnable roles from the given catalogue's published image;
  `nil` selects the first installed catalogue. Returns `{:error, :not_published}` if absent.
  This facade keeps callers outside the unexported `Image` module.
  """
  @spec list_from_published(Path.t() | nil) :: {:ok, [String.t()]} | {:error, :not_published}
  def list_from_published(root) do
    case published_image(root) do
      %{index: index} ->
        # Exclude seats before projecting names so boot never attempts to spawn them.
        {:ok,
         index
         |> Enum.filter(fn {_name, raw} -> Catalog.spawnable?(raw) end)
         |> Enum.map(&elem(&1, 0))
         |> Enum.sort()}

      nil ->
        {:error, :not_published}
    end
  end

  @doc "Returns the cap-profile catalogue root."
  @spec root_dir() :: String.t()
  defdelegate root_dir(), to: Catalog

  defp deep_merge_last_wins(left, right) when is_map(left) and is_map(right) do
    Map.merge(left, right, fn _key, lv, rv ->
      if is_map(lv) and is_map(rv), do: deep_merge_last_wins(lv, rv), else: rv
    end)
  end

  defp deep_merge_last_wins(_left, right), do: right

  @doc """
  Returns `spec.invocation.lifetime_scope`, using `"one-shot"` or the supplied default
  when absent.

  This field is not an expiration duration: workflow events reap judges after verdict
  ingestion and producers after ticket completion. It influences default slot keying,
  resident-versus-cold spawn admission and monitoring policy. Harvest class instead uses
  mission and slot scope (`kill_class/1`).
  """
  @spec lifetime_scope(t(), String.t() | nil) :: String.t() | nil
  def lifetime_scope(%__MODULE__{spec: spec}, default \\ "one-shot") do
    get_in(spec, ["invocation", "lifetime_scope"]) || default
  end

  @doc """
  Fetches a non-empty `lifetime_scope` without a default. The spawn boundary uses this
  strict form before downstream lifecycle derivations.
  """
  @spec fetch_lifetime_scope(t()) :: {:ok, String.t()} | {:error, :no_lifetime_scope}
  def fetch_lifetime_scope(%__MODULE__{spec: spec}) do
    case get_in(spec, ["invocation", "lifetime_scope"]) do
      s when is_binary(s) and s != "" -> {:ok, s}
      _ -> {:error, :no_lifetime_scope}
    end
  end

  @doc """
  Returns `spec.deliverable_mode`, using `"payload"` or the supplied default when absent.
  """
  @spec deliverable_mode(t(), String.t() | nil) :: String.t() | nil
  def deliverable_mode(%__MODULE__{spec: spec}, default \\ "payload") do
    get_in(spec, ["deliverable_mode"]) || default
  end

  @doc """
  Returns the required `spec.brief_kind`. `"worker"` receives executable work;
  `"judge"` receives a defused verdict brief.

  Missing data returns nil, possible in profiles built or modified outside schema validation.
  Do not default to worker: mission controls brief safety and harvest classification;
  `kill_class/1` handles nil explicitly rather than guessing that a malformed judge produces.
  """
  @spec brief_kind(t()) :: String.t() | nil
  def brief_kind(%__MODULE__{spec: spec}) do
    get_in(spec, ["brief_kind"])
  end

  @doc """
  Returns the required `spec.interlocutor`: `"fleet"`, `"both"` or `"human"`.
  The value selects the machine, combined or human conversation protocol.
  """
  @spec interlocutor(t()) :: String.t() | nil
  def interlocutor(%__MODULE__{spec: spec}) do
    get_in(spec, ["interlocutor"])
  end

  @doc """
  Fetches a non-empty `interlocutor` without a default. The spawn boundary uses this
  strict form before selecting a pod protocol.
  """
  @spec fetch_interlocutor(t()) :: {:ok, String.t()} | {:error, :no_interlocutor}
  def fetch_interlocutor(%__MODULE__{spec: spec}) do
    case get_in(spec, ["interlocutor"]) do
      s when is_binary(s) and s != "" -> {:ok, s}
      _ -> {:error, :no_interlocutor}
    end
  end

  @doc """
  Returns role-gated fleet MCP tool names derived from `spec.scope.allowedTools`.
  Universal worker tools are added separately by the MCP authority.
  """
  @spec mcp_fleet_tools(t()) :: [String.t()]
  def mcp_fleet_tools(%__MODULE__{spec: spec}) do
    (get_in(spec, ["scope", "allowedTools"]) || [])
    |> Enum.filter(&(is_binary(&1) and String.starts_with?(&1, "mcp__fleet__")))
    |> Enum.map(&String.replace_prefix(&1, "mcp__fleet__", ""))
    |> Enum.uniq()
  end

  defp published_image(nil), do: Image.published()
  defp published_image(root) when is_binary(root), do: Image.published(root)

  defp to_struct(raw), do: to_struct(raw, nil)

  defp to_struct(raw, root) when is_map(raw) do
    %__MODULE__{
      kind: Map.get(raw, "kind"),
      metadata: stringify_keys(Map.get(raw, "metadata", %{})),
      spec: stringify_keys(Map.get(raw, "spec", %{})),
      catalogue_root: root
    }
  end

  defp stringify_keys(map) when is_map(map) and not is_struct(map),
    do: Map.new(map, fn {k, v} -> {to_string(k), stringify_keys(v)} end)

  defp stringify_keys(list) when is_list(list), do: Enum.map(list, &stringify_keys/1)
  defp stringify_keys(other), do: other

  defp struct_to_map(%__MODULE__{} = p) do
    %{
      "kind" => p.kind,
      "metadata" => p.metadata,
      "spec" => p.spec
    }
  end
end
