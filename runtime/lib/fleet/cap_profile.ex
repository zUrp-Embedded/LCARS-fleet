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
  Capability Profile composer/loader/validator (LCARS cap-profile schema).

  Pure data transformer: YAML on disk → composed `%Fleet.CapProfile{}`
  struct. No process, no state.

  **Construction boundary**: the struct is ONLY built via `to_struct/1` (private), reached
  exclusively after schema validation — three entry paths: `load/1` (disk catalogue by name),
  `compose/2` (base + modops), `from_map/1` (in-memory map, same validation). Hand-building a
  `%CapProfile{spec: …}` short-circuits the schema (the invalid state becomes representable
  again): production code goes through those three, fixtures through `from_map!/1`.

  Two roles in one module:

    * the `Fleet.CapProfile.Loader` behaviour (`load/1`, `compose/2`,
      `validate/1`) plus the in-memory validated constructor `from_map/1`; and
    * the single-authority accessor surface for a composed profile's properties — each accessor is
      the SOLE reader of its field, so a cross-domain caller never re-derives one.

  The schema is pinned by the code and by the bundled schema file's path —
  never by a field embedded in the YAML. Every profile is matched at load time against
  `priv/cap_profile/schema/cap-profile.json`; modops against
  `priv/cap_profile/schema/modop-profile.json`, which is STRICT — reserved keys are forbidden, so a
  modop cannot override the base profile's containment/name/kind.

  Composition is deterministic: deep-merge last-wins in declared order;
  the canonical JSON encoding (recursive key sort) and the `:crypto` sha256
  live in `Fleet.CapProfile.CanonicalJson` (`sha256/1` here delegates). The
  pure G24 semantic invariants live in `Fleet.CapProfile.Invariants`
  (`validate/1` delegates).
  """

  @behaviour Fleet.CapProfile.Loader

  require Logger

  # The four clusters below are all UPSTREAM of this core and none calls back into it: Schema
  # (structural conformance), Catalog (resolution by `metadata.name`, YAML scan, Slug confinement),
  # DisallowedTools (baseline git-denied union profile) and CanonicalJson (a pure leaf).
  alias Fleet.CapProfile.CanonicalJson
  alias Fleet.CapProfile.Catalog
  alias Fleet.CapProfile.DisallowedTools
  alias Fleet.CapProfile.Schema
  alias Fleet.Catalogue

  # No `api_version` field: the schema versioning is carried by the CODE, not by a field embedded
  # in the YAML — a file that declares its own version can disagree with the validator that reads
  # it.
  # @enforce_keys: a cap-profile does not exist without its three faces (kind/metadata/spec).
  # The single construction boundary `to_struct/1` always populates them → additive, does not
  # break normal construction; what it forbids = a partial `%CapProfile{}` hand-built outside load.
  @enforce_keys [:kind, :metadata, :spec]
  # `active_modops` is NOT part of the cap-profile DATA — it is what `resolve/3` DECIDED for this
  # composition (role defaults ++ the step's optional modops). It lives on the struct and not in `spec`
  # on purpose: `spec` is schema-validated (`modop_set` and the root are both
  # `additionalProperties: false`), and the decision is not a catalogue field — two steps resolving the
  # same role legitimately differ. `nil` = never went through `resolve/3` (hand-built struct, fixture,
  # direct `compose/2`); readers must use `active_modops/1`, which falls back to the role's defaults.
  # `catalogue_root` : LE CATALOGUE D'OU CE PROFIL VIENT, porte par le profil lui-meme.
  #
  # Les lecteurs en aval prennent deja un `%CapProfile{}`. Leur passer une racine en ARGUMENT serait
  # transporter a cote du profil un fait qui EST du profil : son SP, son draft et ses modops
  # viennent tous du catalogue qui le declare.
  #
  # `nil` = charge sans catalogue nomme, donc le premier installe. C'est le comportement du jour, et il
  # reste juste tant qu'un appelant n'a pas de projet en main.
  defstruct [:kind, :metadata, :spec, :active_modops, :catalogue_root]

  @type t :: %__MODULE__{
          kind: String.t(),
          metadata: map(),
          spec: map(),
          active_modops: [String.t()] | nil,
          catalogue_root: Path.t() | nil
        }

  @default_containment "bwrap"
  # FAIL-CLOSED: a profile that says nothing reaches its vendor and nothing else.
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

  # WHICH CATALOGUE declares the role. Calling `load/1` here resolves the name in the DEFAULT
  # catalogue, so a card of catalogue B naming ITS producer gets `:not_found` while the role exists
  # — a right card, and a lookup in the wrong library. `nil` keeps the default root, and a loader
  # exporting only `load/1` is a test stub answering for the single catalogue it fabricates.
  defp load_in(loader, role, root) do
    if root && Fleet.Opts.exported?(loader, :load, 2),
      do: loader.load(role, root),
      else: loader.load(role)
  end

  @doc """
  Le meme role, charge depuis le catalogue NOMME — et le profil rendu PORTE cette racine.

  `nil` resout dans le premier catalogue installe. La racine voyage ensuite SUR le profil, ce qui
  evite de la threader dans chaque lecteur qui prend deja ce profil.
  """
  @spec load(String.t(), Path.t() | nil) :: {:ok, t()} | {:error, term()}
  def load(role, root) when is_binary(role) do
    with {:ok, raw} <- Catalog.read_role(role, root),
         :ok <- Schema.validate(raw, :cap_profile) do
      {:ok, to_struct(raw, root)}
    end
  end

  @doc """
  Deep-merges an ordered modop set into a base profile and validates the result.

  The struct form preserves the already-loaded catalogue epoch. The role-name form loads
  its base first and is intended for callers that have not already pinned one.
  """
  @impl Fleet.CapProfile.Loader
  @spec compose(t() | String.t(), [String.t()]) :: {:ok, t()} | {:error, term()}
  def compose(role_or_base, modop_set)

  def compose(%__MODULE__{} = base, modop_set) when is_list(modop_set) do
    raw = %{"kind" => base.kind, "metadata" => base.metadata, "spec" => base.spec}

    with {:ok, modops} <- Catalog.read_modops(modop_set, base.catalogue_root),
         merged <- Enum.reduce(modops, raw, &deep_merge_last_wins(&2, &1)),
         :ok <- Schema.validate(merged, :cap_profile) do
      # La racine SURVIT a la composition : superposer des modops ne change pas de quel catalogue le
      # role vient. Sans ce report, composer efface l'appartenance et les lecteurs d'aval retombent
      # sur le premier catalogue installe — le defaut meme que ce champ existe pour fermer.
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
  Returns the sorted **spawnable** catalogue roles that explicitly declare `cap`.

  Uses the published image when available and otherwise reads the catalogue — **les deux branches
  rendent la meme chose**, sieges reserves exclus des deux cotes (BL-6-45). Profiles that fail to
  load are omitted; uniqueness, when required, belongs to the caller.
  """
  @spec roles_with_capability(atom() | String.t()) :: {:ok, [String.t()]} | {:error, term()}
  def roles_with_capability(cap) do
    case Fleet.CapProfile.Image.published() do
      %{index: index} ->
        # LES DEUX BRANCHES DOIVENT RENDRE LA MEME CHOSE. La branche sans image passe par
        # `Catalog.list/1`, qui filtre les `ReservedSeat` (`spawnable?/1`, BL-6-45) ; sans le filtre
        # ci-dessous, celle-ci les laisserait passer, et un meme catalogue rendrait deux reponses
        # selon qu'une image est publiee ou non.
        #
        # ⚠ ET LA DIVERGENCE EST INATTEIGNABLE AUJOURD'HUI — ce filtre ne repare pas un bug
        # observable, il rend l'accord LOCAL au lieu de l'emprunter. Mesure : le schema
        # `reserved-seat.json` est `additionalProperties: false` et ne declare AUCUN `spec`,
        # donc un siege ne peut pas porter de capability ; un fichier qui essaierait ne validerait
        # pas, et `Image.publish!/0` LEVE sur un profil invalide. Ce qui ferme la divergence vit
        # donc dans un schema voisin, pas ici.
        #
        # On la ferme quand meme, et le cout est un predicat : les appelants sont TOUS des
        # resolveurs structurels qui exigent EXACTEMENT un role et LEVENT sur 0 ou plusieurs, donc
        # le jour ou ce schema gagne un `spec`, la divergence deviendrait « N roles declare … —
        # fix the catalogue » au boot, sur un catalogue sain, avec un message qui accuse
        # l'operateur. Un siege est un nom qu'on garde, pas un role qu'on convoque.
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
        # A profile that does not LOAD cannot declare anything, so `false` is the only honest
        # answer — but SILENTLY it is indistinguishable from "loads fine, does not carry this
        # capability". The caller is usually a structural resolver, which then raises "no role
        # declares X — fix the catalogue": true, and pointing at the wrong thing.
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
  Resolves a spawn-ready profile from its base, default modops and optional step modops.

  Extra modops must be declared optional; when present, the complete active set must contain
  no incompatible pair. The result records that set for `SPBuilder.compose/3`. A loader without
  `compose/2` returns its fixed base with the active set stamped, which supports test stubs.
  """
  @spec resolve(module(), String.t(), [String.t()], Path.t() | nil) ::
          {:ok, t()} | {:error, term()}
  def resolve(loader, role, extra_modops \\ [], root \\ nil)
      when is_atom(loader) and is_binary(role) and is_list(extra_modops) do
    with {:ok, base} <- load_in(loader, role, root),
         :ok <- validate_extra_modops(base, extra_modops) do
      active = default_modops(base) ++ extra_modops

      if Fleet.Opts.exported?(loader, :compose, 2) do
        with {:ok, composed} <- loader.compose(base, active),
             do: {:ok, %{composed | active_modops: active}}
      else
        {:ok, %{base | active_modops: active}}
      end
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

  # `spec.project` CARRIES TWO POPULATIONS IN ONE SLOT, and the schema only ever described the
  # first. A catalogue author declares `repo_path`, `base_branch`, `branch_isolation`,
  # `reference_repo_path` -- validated, `additionalProperties: false`. The pilot then INJECTS the
  # keys below at dispatch, through `with_project/2`, which does not re-validate.
  #
  # They are NOT added to the schema on purpose: a catalogue card that set `base_sha` would
  # validate, then be overwritten at every dispatch -- a knob that reads as configuration and does
  # nothing, which is the failure this list exists to prevent rather than create. The schema stays
  # the CATALOGUE contract; this is the RUNTIME widening, and both are named at both ends.
  @runtime_project_keys ~w(repo base_sha gate_base_sha pr_base_branch)

  @doc """
  The `spec.project` keys injected at runtime, absent from the catalogue schema BY DESIGN.

  Single source: `mix lcars.contracts.check` refuses a project key that is in neither this list nor
  the schema, so the day the pilot adds a fifth one it is declared here or the gate says so.
  """
  @spec runtime_project_keys() :: [String.t()]
  def runtime_project_keys, do: @runtime_project_keys

  @doc """
  Replaces `spec.project` with an effective project whose keys are recursively stringified.

  This is the boundary where the catalogue-validated project becomes the runtime one: the map
  passed in carries `runtime_project_keys/0` on top of what the schema allows, and nothing
  re-validates after this call.
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
  What the pod may REACH — `"vendor-only"` (default), `"egress"` or `"open"`.

  Absent means vendor-only, and the default is the fail-closed one on purpose: a role whose profile
  forgets to say anything reaches its model and nothing else. The opposite default would make every
  new role silently open until someone remembered to close it.

  DECLARED, never derived. Deriving it from `lifetime_scope` or `slot_scope` would couple two
  unrelated things: the day a producer legitimately needs to browse, one would have to change how
  long it lives to give it a network. Which floor a pod sits on and what it may reach are different
  questions about the same pod.

  Note what this does NOT choose: whether the pod has a network namespace. It never does — every
  pod is sealed and leaves through its own CONNECT proxy. The declaration picks the ALLOWLIST that
  proxy serves, so `"egress"` is not "opened", it is "the vendor's hosts plus the ones this role
  declares".

  `"open"` is the one value that drops the host wall — for a role whose work is answering a human
  about the open web, where an allowlist is a list nobody can finish. It changes the ALLOWLIST and
  nothing else: same seal, same proxy, same absence of a resolver in the pod. It is declared, never
  inherited, and `Fleet.Spawner.Pod.Egress` carries what it costs.
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
  Returns whether terminal send-keys fallback is allowed. Defaults to `true`, including
  for absent or non-profile input; `false` protects interactive human-facing terminals.
  """
  @spec wake_send_keys?(term()) :: boolean()
  def wake_send_keys?(%__MODULE__{spec: spec}) when is_map(spec),
    do: get_in(spec, ["invocation", "wake_send_keys"]) != false

  def wake_send_keys?(_), do: true

  @doc """
  Is this pod VISIBLE in Claude Desktop? (`spec.invocation.remote_control`.) `false` = the launcher
  omits `--remote-control` (pod functional but invisible — churny judges). Read spawner-side to
  decide whether to arm the Desktop-slot capture (a no-RC pod never registers a slot → nothing to
  capture/preserve). Tolerates `nil`/non-profile input (`true`).

  **The DECLARATION wins; absent, the answer is DERIVED from `slot_scope/1`** — a Desktop slot is a
  handle on an IDENTITY, so the granularity of the identity is what decides whether there is
  anything durable to hold:

    * `"project"` → visible. One stable pod per (repo, role): a handle worth having.
    * `"instance"` → invisible. One pod per ticket, gone with it. A handle on something that will
      not be there tomorrow is not a handle, it is a leak — and it scales with the fan-out, which
      is what turns a flat `true` default from tenable into Desktop pollution.

  Not a total derivation: a declaration overrides it in BOTH directions, and `g24_16` requires one
  from every project-keyed role — the derivation's `"project"` branch is therefore unreachable for
  a loaded profile, and exists so the function stays total for an unvalidated one.

  A non-boolean value falls to the derivation rather than being read as truthy: the schema types
  this field `boolean`, so a string is an invalid profile, and the derivation is the NARROWER
  answer — an invalid field never opens a door by accident.

  `Fleet.Spawner.Pod.LaunchSpec.remote_control?/1` is the EFFECTIVE authority (this, plus the
  fleet's debug widening); this one answers what the profile itself says.
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
  Does this role COMPRESS its Bash output before it enters the agent's context?
  (`spec.invocation.output_compression`, absent = `true`.)

  Absent means yes, and that asymmetry is deliberate: compression is the nominal posture — a role
  that saturates its context on a build log helps nobody — and the exception is the role for which
  the FULL output IS the work. A judge reading a diff, a debug run: there, a summary is not a
  cheaper answer, it is a different one.

  This is the FLOOR, not the effective value. `Fleet.Spawner.Pod.LaunchSpec.output_compression?/1`
  is the authority, and it composes this with the fleet knob by an **AND** — the mirror of the `or`
  that governs `remote_control?/1`, and the mirror is forced by the risk: visibility ADDS a window,
  compression REMOVES information. So the fleet-wide knob may only CUT compression, never impose it
  on a role that declared `false` and would lose exactly what it was spawned to read.
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
  Does this role hold a FORGE IDENTITY — its own account and role token? (`metadata.forge_identity`,
  absent = `true`.)

  `false` is the explicit declaration of an asymmetry: an orchestrator whose forge writes all go
  through the system account. Without a RUNTIME reader of this field, "this role declares no
  identity" is indistinguishable from "this role's token is MISSING", and both get the same
  treatment — an attempt, a failure, and a warning sending the operator to check a provisioning
  that works as declared. `forge_identity: false` would then be unusable for any role the dispatch
  reaches: choosing it would mean a permanent "provisioning defect" warning on every spawn.
  """
  @spec forge_identity?(t()) :: boolean()
  def forge_identity?(%__MODULE__{metadata: meta}) when is_map(meta),
    do: Map.get(meta, "forge_identity", true) != false

  def forge_identity?(_), do: true

  @doc """
  Is the profile in sandboxed bwrap containment (the default)? `false` = host-native (`"none"`, the
  pod runs on the host *as* the human). The single predicate for host-native guards (e.g. API admission).
  """
  @spec bwrap?(t()) :: boolean()
  def bwrap?(%__MODULE__{} = cap), do: containment(cap) == @default_containment

  @doc """
  The profile's `name` (`metadata["name"]`) — the role/pod identity carried by the cap-profile.

  **SINGLE SOURCE** of this read. Reads the STRING key `"name"` (the `stringify_keys` invariant of the
  `to_struct/1` boundary guarantees deeply string keys).

  **No fabricated default**: a cap-profile without a name is a state the domain forbids. If `name` is
  absent or empty (`nil`/`""`/missing key), we **raise** (fail-loud) — we NEVER fabricate an
  `"unknown"`/`"worker"` that would mask the gap. In normal use the schema's `minLength: 1` already
  guarantees it at `load`; this accessor is the net for a struct built outside `load`.
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
  The role's identity/slot granularity — **DERIVED from `lifetime_scope`**, never a declared
  property: "unique vs multi" is not data, it is a CONSEQUENCE of "context-long vs one-shot"
  (context-long ⟹ one instance that keeps context ⟹ serialize; one-shot ⟹ cold, independent ⟹
  fan-out). A "project one-shot" would be a contradiction — why serialize a cold pod that shares
  nothing? SINGLE SOURCE = `lifetime_scope`.

    * `"instance"` (one-shot): pod_id per (repo, number, role) → fan-out per issue/PR (ephemeral judges).
    * `"project"` (context-long): pod_id per (repo, role) → ONE identity per project → ONE stable Desktop
      slot (cwd + session-id pinned), dispatch serialized per (repo, role) (engineer, arch, fleet-level
      singletons).

  **SINGLE SOURCE** of the routing: `Fleet.Pilot.StepDispatcher` chooses `PodId.for_repo` vs
  `for_issue`/`for_pr` off this. `lifetime_scope` is schema-REQUIRED (`invocation.required`) + enum-gated
  (`g24_4`) → always present+valid for a loaded profile; the `"one-shot"` default is the safe fail (a role
  without a lifetime = ephemeral = fans out, never a shared serialized slot claimed by mistake).

  **DECLARABLE** — `invocation.slot_scope` (optional, enum-gated by the schema) OVERRIDES the
  derivation, because the derivation is a total function and ONE combination cannot be written
  through it: context-long AND one pod per ticket. That combination is what a producer needs — it
  must survive its rework rounds (keep the context of what it just built) WITHOUT outliving its
  ticket. Derived alone, a producer is project-keyed, so the next ticket re-briefs the SAME pod
  through a workspace reset + `/clear`: the process survives and the context dies, which is neither
  fan-out nor memory. Absent field = the derivation, to the letter.
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
  The pod's KILL/HARVEST class — the `<X>` nibble of the deterministic session_id
  (`Fleet.Spawner.SessionId.encode`), DERIVED from existing metadata (no new field). It sorts pods by
  **MISSION**, and the four tiers are named by what they are:

    * `0` — **l'accueil**, toujours la : `role_index == 0`, hors de la gestion ordinaire des pods.
      Epargne par tout motif ancre sur la classe.
    * `1` — **l'architecte**, qui vit tant que le projet est ouvert : `slot_scope: "project"`, une
      identite par projet.
    * `2` — **les producteurs**.
    * `3` — **les juges** : `brief_kind: "judge"`.

  ## Pourquoi ce n'est pas le cycle de vie qui trie

  Trier la classe 3 sur `lifetime_scope == "one-shot"` est faux sur DEUX points a la fois. **Un juge
  n'est pas one-shot** : il meurt quand son livrable est traite, exactement comme un producteur —
  esperance de vie plus courte, nature identique. Et « jetable » **ne distingue rien** : un
  producteur est jetable aussi, simplement plus cher.

  `brief_kind` porte le critere et il ne s'invente pas pour l'occasion : REQUIS au schema,
  fail-closed, et declare propriete de SECURITE (« judge-ness is a SECURITY property, NEVER
  inferred »).

  ## Ce que le nombre dit d'autre

  **Le gradient de cout** — `1` coute une conversation humaine, `2` le travail d'un ticket, `3` une
  passe de verdict. Le nombre se lit donc de deux facons, toutes deux vraies : mission ET cout.

  Effet acquis en prime : l'UUID est un **temoin visible de la judge-ness**. Editer le `brief_kind`
  d'un profil change l'identite de ses pods, donc se voit.

  NO ROLE IS NAMED HERE, deliberately: a comment that inventories another artefact lies the day that
  artefact moves, in silence. The criterion is stated; roles sort themselves into it.

  Reaping, and ALWAYS anchor on `claude.*`: a bare pattern reaps any concurrent `grep` carrying it in
  its argv (cf. `SessionId` moduledoc).
  """
  @spec kill_class(t()) :: 0..3
  def kill_class(%__MODULE__{} = profile) do
    cond do
      role_index(profile) == 0 ->
        0

      # AVANT le test de judge-ness, et l'ordre porte l'invariant : un role qui vit tant que le
      # projet est ouvert parle a un humain. Le classer par sa mission de jugement le mettrait dans
      # le seau des jetables, et un balayage de routine couperait une conversation en cours.
      slot_scope(profile) == "project" ->
        1

      brief_kind(profile) == "judge" ->
        3

      # ⚠ UN PROFIL SANS `brief_kind` NE PRODUIT PAS, IL EST CASSE. La cle est REQUISE au schema,
      # donc ce cas n'existe pas en production ; il existe pour un profil forge a la main, et le
      # laisser tomber dans le `true ->` ci-dessous le classerait PRODUCTEUR sans un mot — un juge
      # de fixture range parmi les jetables (B1). On le nomme, on le classe au plus cher
      # (l'architecte), et on le dit.
      is_nil(brief_kind(profile)) ->
        Logger.warning(
          "CapProfile: #{inspect(name(profile))} has NO `brief_kind` — the schema requires it, so " <>
            "this profile was not loaded through the catalogue. Filed under class 1 (the most " <>
            "expensive) rather than guessed: judge-ness is never inferred."
        )

        1

      # `true` ET PAS `slot_scope == "instance"`, et la difference est une AFFIRMATION plutot qu'un
      # reste : tout ce qui n'est ni l'accueil, ni lie au projet, ni un juge, PRODUIT.
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
  The forge LOGIN a role writes under — `<tier>_<role>`, or `{:error, _}`.

  THE RULE MUST BE READABLE FROM BOTH SIDES. Held private on the provisioning side, accounts get
  CREATED under their login while the runtime keeps addressing them by ROLE: `request_review`
  answers `404 User 'qualifier' not exist` and the PR sits with no judge, the review leg never
  starting. The read half fails the same way and more quietly: verdicts come back under LOGINS, get
  compared to the card's ROLES, and every real judge is classified `foreign` by F-C061.

  The prefix follows the TIER, never the file that wins the overlay: a business catalogue may ship
  its own `architect.yaml` to widen its tools, and the account stays `system_architect`, because
  `architect` is a system authority — the SAME one in every org. So membership of the SYSTEM roster
  decides, and a role declared only by the business catalogue takes that catalogue's name.

  Memoized per catalogue root: the poller resolves a jury on every tick and this reads YAML off
  disk. The key carries the root, so a test or `Fleet.Roster` borrowing the catalogue gets its
  own entry rather than a stale answer from the previous one.
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
  The role behind a forge `login`, or `{:error, {:login_not_a_role, login}}`.

  The inverse of `forge_login/1`, and the reason it returns an ERROR rather than the login itself:
  a name that is not a fleet role is a HUMAN (or a stranger), and the two must stay
  distinguishable. F-C061 shows the cost of blurring them — a foreign reviewer that silently reads
  as a role would join the jury and could skew or block a verdict.
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

  # Gitea caps a username at 40 chars (measured) and resolves logins case-insensitively — hence the
  # downcased inverse key. `_` separates the two halves, so a role carrying one would make the split
  # ambiguous; the composition refuses it here rather than minting a login nobody can take apart.
  @login_max 40
  @role_rx ~r/\A[a-z0-9][a-z0-9-]*\z/

  defp login_maps do
    # Keyed on THE ACTIVE SET, because that is what the map is derived from. Keyed on the default
    # root alone it leaks across fixtures that swap the active declaration while the default root
    # stays put, and the projection is silently for someone else's catalogues. A memo whose key is
    # narrower than its input is a wrong answer with a fast path.
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

  # ONE PASS PER INSTALLED CATALOGUE, and it has to be. The rule is "the prefix follows the TIER",
  # and the tier of a business role is THE CATALOGUE THAT DECLARES IT — not "the default one". This
  # runs globally, so `Fleet.Catalogue.name()` names only the DEFAULT catalogue: asking it projects
  # a role declared by `biz` to `fleet_biz-dev` while its account is `biz_biz-dev`. A projection
  # that is right for one catalogue and silently wrong for every other is worse than none — it is
  # the 404 this whole rail was built to stop, relocated.
  #
  # `installed_roots/0` ORDER decides (`put_new`), which is the same rule stated for the overlay: a business
  # catalogue may ship its own `architect.yaml` and the account stays `system_architect`, because
  # the system roster is consulted first for every name.
  defp build_login_maps do
    system_dir = Path.join(Catalogue.system_root(), Catalogue.rel(:cap_profiles))

    with {:ok, system_roster} <- forge_roster(system_dir) do
      system_names = MapSet.new(system_roster, & &1.name)

      to_login =
        Catalogue.installed_catalogues()
        |> Enum.reduce(%{}, fn %{name: cat, root: root}, acc ->
          dir = Path.join(root, Catalogue.rel(:cap_profiles))

          case forge_roster(dir) do
            {:ok, roster} -> Enum.reduce(roster, acc, &put_login(&2, &1.name, system_names, cat))
            {:error, _} -> acc
          end
        end)
        # The system roles themselves, for a deployment whose business catalogues declare none.
        |> then(fn acc ->
          Enum.reduce(system_roster, acc, &put_login(&2, &1.name, system_names, "system"))
        end)

      {:ok,
       %{to_login: to_login, to_role: Map.new(to_login, fn {r, l} -> {String.downcase(l), r} end)}}
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
  La meme liste, pour l'image d'un catalogue NOMME — `nil` = le premier installe.

  Passe par la facade parce que `Fleet.CapProfile.Image` n'est pas exporte par cette boundary : un
  appelant d'un autre domaine (la preuve de canon) demande « les roles de CE catalogue » sans
  atteindre le sous-module.
  """
  @spec list_from_published(Path.t() | nil) :: {:ok, [String.t()]} | {:error, :not_published}
  def list_from_published(root) do
    case published_image(root) do
      %{index: index} ->
        # Same rule as `Catalog.list/1`, same trap (BL-6-45): filter the ENTRIES on the shared
        # predicate BEFORE projecting the keys — an unfiltered image index hands a ReservedSeat
        # to PermanentBoot.load_all, whose fail-loud turns the seat into fleet.boot_failed.
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

  ## ⚠ CE CHAMP NE DIT PAS COMBIEN DE TEMPS UN POD VIT (B3)

  Son nom le promet, quatre valeurs le suggèrent (`one-shot`, `pipe`, `run`, `forever`), et c'est
  faux. Un juge déclaré `one-shot` vit jusqu'à ce que son verdict soit ingéré
  (`StepRunCompleter`) ; un producteur `pipe` vit jusqu'au sceau de sa brique
  (`MergeAndPromote.reap_ticket_producer/3`). Dans les deux cas la durée est décidée par un
  ÉVÉNEMENT DU RAIL, jamais par cette énumération.

  **Ce qu'elle décide réellement, et c'est tout :**

    1. **le rangement** — `slot_scope/1` en dérive quand le profil n'en déclare pas
       (`one-shot ⟹ instance`, sinon `project`), donc combien d'identités de pod existent ;
    2. **l'admission au spawn** — `Spawn.project_scope_decision/4` lit l'axe racine
       « context-long vs one-shot » pour choisir entre un processus RÉSIDENT re-briefé et un pod
       froid.

  **Ce qu'elle NE décide PAS** : la classe de fauche. `kill_class/1` trie par MISSION (`brief_kind`,
  `slot_scope`) — un juge n'est pas plus jetable qu'un producteur, et « jetable » ne distingue rien.

  On ne renomme pas le champ : il est écrit dans les profils, dans le schéma et dans les invariants
  `g24_15`/`G24-11`. Un renommage sans lecteur qui le réclame échangerait un nom imprécis contre une
  migration — et le nom n'a jamais été le mécanisme, seulement sa description.
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

  ⚠ **`nil` EST POSSIBLE, ET C'EST UN PROFIL HORS SCHEMA.** La cle est REQUISE — un profil charge
  par le catalogue est valide avant d'entrer dans le runtime, donc la production n'y arrive pas.
  Un profil construit a la main (fixture, injection ad hoc) le peut, et comme `kill_class/1` trie
  sur la judge-ness (B1), un `nil` y classerait un juge en PRODUCTEUR, silencieusement.

  On ne met PAS de defaut a `"worker"` ici, et le refus est le meme que celui du schema : la
  judge-ness est une propriete de SECURITE qui ne s'infere jamais. Un defaut ferait exactement
  l'inference qu'on interdit — il rendrait « ce profil ne dit rien » indiscernable de « ce profil
  declare produire ». `nil` reste `nil`, et `kill_class/1` le traite explicitement.
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

  defp published_image(nil), do: Fleet.CapProfile.Image.published()
  defp published_image(root) when is_binary(root), do: Fleet.CapProfile.Image.published(root)

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
