defmodule Fleet.CapProfile do
  use Boundary,
    deps: [
      Fleet.Slug,
      Fleet.EnvParse,
      Fleet.GitRef,
      Fleet.Layout,
      Fleet.Event,
      Fleet.SchemaCache
    ],
    exports: []

  @moduledoc """
  Capability Profile composer/loader/validator (LCARS schema v2.5).

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
    * the single-authority accessor surface for a composed profile's
      properties (`name/1`, `role_index/1`, `containment/1`, `slot_scope/1`,
      `lifetime_scope/2`, `deliverable_mode/2`, `brief_kind/2`, …) — each the
      sole reader of its field, so cross-app callers never re-derive it.

  The schema version (LCARS v2.5) is pinned by the code / the bundled schema file path —
  never by a field embedded in the YAML. Every profile is matched against
  `priv/schema/cap-profile-v2.5.json` at load time. Modops are
  matched against `priv/schema/modop-profile.json` (strict — reserved
  keys forbidden, so a modop cannot override the base profile's
  containment/name/kind).

  Composition is deterministic: deep-merge last-wins in declared order;
  the canonical JSON encoding (recursive key sort) and the `:crypto` sha256
  live in `Fleet.CapProfile.CanonicalJson` (`sha256/1` here delegates). The
  pure G24 semantic invariants live in `Fleet.CapProfile.Invariants`
  (`validate/1` delegates).

  **Last revised**: 2026-07-21
  """

  @behaviour Fleet.CapProfile.Loader

  # JSON-schema validation cluster (structural conformance), UPSTREAM of the core.
  # `load`/`compose` delegate to it (and via `Catalog.read_modops` too); no cycle
  # (Schema calls nothing here).
  alias Fleet.CapProfile.Schema

  # Catalogue FS cluster (resolution by metadata.name, YAML scan, Slug confinement).
  # `load`/`compose` call `Catalog.read_role`/`Catalog.read_modops`; `list/1` and
  # `root_dir/0` (consumed out-of-app) delegate to it. No cycle: Catalog is UPSTREAM
  # (it depends on Schema, not on the core).
  alias Fleet.CapProfile.Catalog

  # Write-time resolution cluster for `spec.scope.disallowedTools` (baseline
  # git-denied ∪ profile). The three public helpers below delegate to it; no
  # cycle (DisallowedTools depends on the struct, not on the core API).
  alias Fleet.CapProfile.DisallowedTools

  # Canonical encoding + hash cluster (composition determinism) — a concern
  # orthogonal to the loader and the accessors, extracted. `sha256/1` (consumed
  # by tests + determinism assertions) delegates to it; no cycle (CanonicalJson
  # is a pure leaf, zero dependency onto the core).
  alias Fleet.CapProfile.CanonicalJson

  # No `api_version` field: the schema versioning is carried by the code
  # (release v2), not by a field embedded in the YAML.
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
  defstruct [:kind, :metadata, :spec, :active_modops]

  @type t :: %__MODULE__{
          kind: String.t(),
          metadata: map(),
          spec: map(),
          active_modops: [String.t()] | nil
        }

  # Default containment mode = SANDBOXED pod. SINGLE SOURCE of the literal: a config gap
  # (missing `metadata.containment` key) ALWAYS assumes the confined mode, never the host. Read by
  # `containment/1` (default) and `bwrap?/1` (predicate), and referenced cross-app by API admission.
  @default_containment "bwrap"

  # ============================================================
  # Loader behaviour
  # ============================================================

  @doc """
  Loads the cap-profile for the given role and validates its STRUCTURE against
  `priv/schema/cap-profile-v2.5.json`.

  Two-stage validation (deliberate): `load`/`compose` check only the STRUCTURAL schema here. The G24
  SEMANTIC invariants (`validate/1`) are enforced at the SPAWN boundary (`Fleet.Spawner.Pod` do_allocate,
  asserted by `mix lcars.contracts.check`) — the "validated world" is established at use, not at read: a
  profile can be loaded for listing/inspection without being spawn-ready.

  Resolution is by `metadata.name` (the profile's internal property), NOT by
  filename — see `Fleet.CapProfile.Catalog`; the filename is cosmetic.

  ## Exit codes
    * `{:ok, %Fleet.CapProfile{}}` — load + STRUCTURAL validation OK (G24 invariants checked at spawn)
    * `{:error, :not_found}` — no profile carries this name
    * `{:error, :catalogue_missing}` — the catalogue root directory is absent (broken config,
      distinct from a role that is simply not found — propagated from `Catalog.read_role/1`)
    * `{:error, :name_collision}` — two catalogue files carry the same `metadata.name`
      (broken deploy artifact — propagated from `Catalog.read_role/1`, fail-loud)
    * `{:error, :invalid_schema}` — malformed YAML OR schema-nonconformant
    * `{:error, :schema_unavailable}` — the priv schema file is absent or corrupt
  """
  @impl Fleet.CapProfile.Loader
  @spec load(String.t()) :: {:ok, t()} | {:error, atom() | String.t()}
  def load(role) when is_binary(role) do
    with {:ok, raw} <- Catalog.read_role(role),
         :ok <- Schema.validate(raw, :cap_profile) do
      {:ok, to_struct(raw)}
    end
  end

  @doc """
  Composes a cap-profile from a base role and an ordered list of modops.
  Deep-merge last-wins, declared order = precedence.

  The result is re-validated against the cap-profile schema post-merge.

  ## Exit codes
    * `{:ok, %Fleet.CapProfile{}}` — composition OK
    * `{:error, :not_found}` — base role absent
    * `{:error, :catalogue_missing}` — the catalogue root directory is absent (broken config,
      distinct from a role that is simply not found — propagated from `Catalog.read_role/1`)
    * `{:error, :name_collision}` — two catalogue files carry the same `metadata.name`
      (broken deploy artifact — propagated from `Catalog.read_role/1`, fail-loud)
    * `{:error, :modop_not_found}` — at least one named modop is absent
      (the missing modop name is logged via `Logger.warning/1`)
    * `{:error, :invalid_schema}` — base or post-merge result nonconformant
    * `{:error, :invalid_modop}` — invalid modop YAML or reserved keys
    * `{:error, :schema_unavailable}` — the priv schema file is absent or corrupt
  """
  @impl Fleet.CapProfile.Loader
  @spec compose(String.t(), [String.t()]) :: {:ok, t()} | {:error, term()}
  def compose(role, modop_set) when is_binary(role) and is_list(modop_set) do
    with {:ok, base} <- Catalog.read_role(role),
         :ok <- Schema.validate(base, :cap_profile),
         {:ok, modops} <- Catalog.read_modops(modop_set),
         merged <- Enum.reduce(modops, base, &deep_merge_last_wins(&2, &1)),
         :ok <- Schema.validate(merged, :cap_profile) do
      {:ok, to_struct(merged)}
    end
  end

  @doc """
  The role's DEFAULT modops — `spec.modop_set.default` — the overlays applied AT SPAWN (their SP fragments
  are composed into the pod's system prompt by `SPBuilder.compose`). `[]` if absent, or if
  `modop_set`/`default` is any shape other than a map holding a list (defensive: a malformed/stub spec
  yields no overlay rather than crashing the spawn).
  """
  @spec default_modops(t()) :: [String.t()]
  def default_modops(%__MODULE__{spec: spec}) do
    case spec do
      %{"modop_set" => %{"default" => defaults}} when is_list(defaults) -> defaults
      _ -> []
    end
  end

  @doc """
  Does the profile declare the business CAPABILITY `cap`? (catalogue chantier L3, B-03 2026-07-20).

  A capability is a RESPONSIBILITY the role carries (`spec.capabilities`, e.g. `onboarder`,
  `project_delegate`, `exception_judge`, `producer`) — the gates resolve a CAPABILITY, never a magic
  role name (`role in ["starfleet","architect"]`). A rename/substitution of a role becomes a
  cap-profile edit, not an Elixir change. Absent/malformed `capabilities` → `false` (a role has a
  capability only if it DECLARES it, fail-closed for a gate).
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
  Turns a `role` into a SPAWN-READY cap-profile: base + its `default` modops (+ optional `extra`
  step-modops). THE single launch-site authority (catalogue chantier L1a) — every spawn path calls
  this via its injected `loader`, so the structural modop overlay is applied IDENTICALLY everywhere.

  Before this, the 5 launch sites diverged: architect/gatekeeper composed the modops, the dispatch/
  admin/permanent paths only `load`ed the base — a latent bug (the day a `modop/<n>/profile.yaml`
  overlay carries structural data, the same modop would behave differently by launch origin,
  A-01). `default_modops/1` is called on the loaded STRUCT (pure — a stub loader needs only
  `load`+`compose`, never `default_modops`).

  `loader` = the injected cap-profile loader (prod `Fleet.CapProfile`); `extra_modops` = step-level
  modops (validated against the role's `optional` by the caller — cf. B-01), `[]` by default.
  """
  @spec resolve(module(), String.t(), [String.t()]) :: {:ok, t()} | {:error, term()}
  def resolve(loader, role, extra_modops \\ [])
      when is_atom(loader) and is_binary(role) and is_list(extra_modops) do
    with {:ok, base} <- loader.load(role),
         :ok <- validate_extra_modops(base, extra_modops) do
      # A loader seam without `compose/2` is a TEST STUB (a fixed `%CapProfile{}` with no modop
      # overlays) → the base IS the resolved profile (composing empty overlays is a no-op). The
      # prod loader `Fleet.CapProfile` always exposes `compose/2`, so this branch never yields the
      # base in prod — it spares the stubs a trivial `compose` clause, nothing more.
      # The ACTIVE list is decided here — and it must survive to the SP composition. `compose/2` merges
      # the overlays but returns a profile that no longer says WHICH modops were asked for, so stamping
      # it is what makes a step's optional modop reach `SPBuilder.compose` instead of being validated
      # above and then silently dropped (the spawn path re-derived the role's defaults).
      active = default_modops(base) ++ extra_modops

      if function_exported?(loader, :compose, 2) do
        with {:ok, composed} <- loader.compose(role, active),
             do: {:ok, %{composed | active_modops: active}}
      else
        {:ok, %{base | active_modops: active}}
      end
    end
  end

  @doc """
  The modops ACTIVE for this composition — what `SPBuilder.compose` must receive so their `sp.md`
  fragments reach the pod's system prompt.

  Stamped by `resolve/3` (role defaults ++ the step's validated optional modops). `nil` means the
  profile never went through `resolve/3` (hand-built struct, fixture, direct `compose/2`): we then fall
  back to the role's declared defaults, which is exactly what the spawn path used to do for everyone.
  """
  @spec active_modops(t()) :: [String.t()]
  def active_modops(%__MODULE__{active_modops: mods}) when is_list(mods), do: mods
  def active_modops(%__MODULE__{} = profile), do: default_modops(profile)

  # B-01 GUARD: a STEP can only activate a modop the role itself declares in `modop_set.optional`
  # — it can never turn a reviewer into an engineer (that would be the killed profile-swap), only
  # run its own role in an optional mode (`role: engineer, modops: [tdd]`). And no `incompatible`
  # pair may end up both active (default ∪ extra). A modop outside `optional` = LOUD refusal, never
  # a silent mix.
  #
  # WHERE WHAT THIS GUARD ADMITS ACTUALLY LANDS. A modop's effect is NOT a cap-profile mutation: every
  # overlay under `canon/cap-profiles/modop/*/profile.yaml` is a deliberate empty identity overlay (its
  # own header says so), so `compose/2`'s deep-merge is a no-op BY DESIGN. The behaviour is carried by
  # the bundle's `canon/modop-bundles/<name>/sp.md`, injected by `SPBuilder.compose/3`.
  #
  # The route from here to there is the `active_modops` struct field: `resolve/3` stamps the validated
  # list (defaults ++ the step's extras), `active_modops/1` reads it back with a fallback to the role's
  # defaults, and `Spawner.Pod` hands THAT to `SPBuilder.compose`. So a step's `modops:` entry survives
  # validation and reaches the pod's system prompt.
  #
  # This used to be a real hole — the list was validated here and then re-derived from
  # `default_modops/1` downstream, so an extra silently vanished. It was closed on the struct rather
  # than in the spec (which would have needed a schema change: `modop_set` and the root are both
  # `additionalProperties: false`) or through `resolve/3`'s return shape (~8 call sites). Regression:
  # `cap_profile_test.exs`, via a loader whose `compose/2` returns `spec: %{}` — the exact shape that
  # used to lose them.
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
  Validates a `%Fleet.CapProfile{}` against the pure G24 semantic invariants
  (cap-profile canon v2.5 + containment gate). Pure: no process or FS read
  (same struct ⇒ same verdict).

  The per-code catalogue (what each `:g24_*` enforces) and the impure
  invariants excluded from `validate/1` live in `Fleet.CapProfile.Invariants`,
  the single source — this wrapper only carries the return contract.

  ## Exit codes
    * `:ok` — every invariant passes
    * `{:error, [codes]}` — the list of violated invariants, atoms among
      `:g24_1`, `:g24_3`, `:g24_4`, `:g24_6`, `:g24_8`, `:g24_9_strict`,
      `:g24_9_prefix`, `:g24_10`, `:g24_11`, `:g24_12`, `:g24_14`
  """
  @impl Fleet.CapProfile.Loader
  @spec validate(t()) :: :ok | {:error, [atom()]}
  def validate(%__MODULE__{} = profile) do
    # The pure invariant cluster (one function per check) lives in
    # `Fleet.CapProfile.Invariants`. Here we keep ONLY the single-authority
    # return contract consumed out-of-app: `[]` ⇒ `:ok`, otherwise `{:error, [codes]}`.
    case Fleet.CapProfile.Invariants.violations(profile) do
      [] -> :ok
      violations -> {:error, violations}
    end
  end

  @doc """
  Builds a `%Fleet.CapProfile{}` from an IN-MEMORY map (≠ `load/1`, which resolves a disk-catalogue
  profile by `metadata.name`), crossing the **SAME** schema validation as `load`/`compose`.

  **The only validated entry path** for a profile outside the catalogue: without it, code (fixtures,
  ad-hoc composition) hand-forges `%CapProfile{spec: %{}}` → the schema is short-circuited and the
  invalid state becomes representable again. A profile coming out of HERE IS schema-conformant
  (kind/metadata/spec + required fields); `to_struct/1` (private) stays the sole MAKER of the struct,
  never reached without prior validation (load / compose / here).

    * `{:ok, %Fleet.CapProfile{}}` — schema-conformant map
    * `{:error, :invalid_schema}` — nonconformant (SAME verdict as `load`)
    * `{:error, :schema_unavailable}` — the priv schema file is absent/corrupt
  """
  @spec from_map(map()) :: {:ok, t()} | {:error, atom() | String.t()}
  def from_map(raw) when is_map(raw) do
    with :ok <- Schema.validate(raw, :cap_profile) do
      {:ok, to_struct(raw)}
    end
  end

  @doc """
  Bang variant of `from_map/1`: returns the struct, or **raises** if the map is not
  schema-conformant. Meant for NOMINAL fixtures (the `Fleet.Support.CapProfileFixture` support
  builder relies on it) — a nominal fixture then crosses the SAME boundary as production instead
  of forging a partial `%CapProfile{}`. (A DELIBERATELY schema-bypassed profile, to test an
  accessor's fail-loud, stays hand-built in a test explicitly named "schema bypass".)
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

  # ============================================================
  # Public helpers
  # ============================================================

  @doc """
  Translates `spec.scope.git_ops_denied` into claude CLI `disallowedTools`
  patterns `Bash(git <entry>:*)`. **Delegates** to the resolution cluster
  `Fleet.CapProfile.DisallowedTools`. Public (tests + internal).
  """
  @spec git_ops_denied_patterns(t()) :: [String.t()]
  defdelegate git_ops_denied_patterns(profile), to: DisallowedTools

  @doc """
  Returns a `%CapProfile{}` whose `spec.scope.disallowedTools` merges (uniq,
  order preserved: existing, intangible universal baseline, profile patterns).
  Idempotent. Application point: `Fleet.Spawner.Pod.do_allocate/1` (writing the
  pod's `.cap-profile.json`). **Public + consumed by pod.ex** — **delegates** to
  `Fleet.CapProfile.DisallowedTools.with_resolved/1` (the API carried here stays put).
  """
  @spec with_resolved_disallowed_tools(t()) :: t()
  defdelegate with_resolved_disallowed_tools(profile), to: DisallowedTools, as: :with_resolved

  @doc """
  The `disallowedTools` patterns of the intangible universal baseline
  (`priv/cap_profile/canon/cap-profiles/_baseline-git-denied.yaml`) — **raises** fail-closed if
  the baseline is absent/corrupt. **Delegates** to
  `Fleet.CapProfile.DisallowedTools.baseline_patterns/0`. Public (tests + internal).
  """
  @spec baseline_git_ops_denied_patterns() :: [String.t()]
  defdelegate baseline_git_ops_denied_patterns(), to: DisallowedTools, as: :baseline_patterns

  @doc """
  Returns a `%CapProfile{}` whose `spec.project` is REPLACED by the given effective project (a map of
  string keys, same shape as the YAML's `spec.project`: `repo_path`, `repo`, `remote`…).

  A project pod may receive its project from the BRIEF (issue→repo dispatch, `opts[:project]`) rather
  than from the static cap-profile: the readers of `spec.project` (e.g. `Fleet.ProjectBootstrap.Phase.Clone`)
  then receive this EFFECTIVE cap-profile. **SINGLE SOURCE** of this substitution — the call sites
  (`Fleet.Spawner.Pod.Scaffold.maybe_bootstrap_project_workspace`, the workspace reprovision in
  `Fleet.Spawner.Pod`) do not re-build the `spec` map by hand. Pure (returns a new struct).
  """
  @spec with_project(t(), map()) :: t()
  def with_project(%__MODULE__{spec: spec} = cap, project) when is_map(project),
    # `stringify_keys` (deeply): the injected `project` may arrive with ATOM keys (from a brief/dispatch),
    # but readers (`Phase.Clone` → `project["repo_path"]`) use STRING keys — preserve the deep-string-keys
    # invariant that `to_struct/1` establishes, so this substitution can't silently null out a reader.
    do: %{cap | spec: Map.put(spec, "project", stringify_keys(project))}

  @doc """
  The profile's containment mode (`metadata.containment`). `"bwrap"` = sandboxed pod (RO mounts +
  tmpfs /home + bind credentials, the default); `"none"` = host-native, the OUT-OF-BAND mode
  (`bin/host_launch.sh`) for an off-fleet interactive session — the pod runs ON THE HOST *as* the human,
  outside the sandbox = the strongest power in the fleet. No canon cap-profile is host-native since the
  2026-07-19 reorg (starfleet became an ordinary bwrap orchestrator); the guard below still forbids it.

  **SINGLE SOURCE** of this read (the spawner selects the N0 launcher off it, the spawn API forbids
  host-native). Default `"bwrap"` if the key is absent: missing containment ⇒ we assume the confined
  mode, never the host — a config gap must NEVER open the host by default.
  """
  @spec containment(t()) :: String.t()
  # String key ONLY: `to_struct/1` deep-stringifies metadata, so an atom `:containment` key is
  # structurally impossible here — an atom fallback would re-validate what the boundary guarantees.
  def containment(%__MODULE__{metadata: meta}) when is_map(meta),
    do: Map.get(meta, "containment") || @default_containment

  def containment(%__MODULE__{}), do: @default_containment

  @doc """
  The default containment mode (`"bwrap"`, sandboxed pod) — SINGLE SOURCE of the literal, referenced
  by cross-app readers rather than re-typing it.
  """
  @spec default_containment() :: String.t()
  def default_containment, do: @default_containment

  @doc """
  Is the send-keys wake FALLBACK authorized for this pod? (`spec.invocation.wake_send_keys`,
  default `true`.) `false` = flag-only pod: the kick loop NEVER types into its terminal — set
  on the ARCHITECT, whose terminal is the HUMAN's interactive session (a fallback `wake` lands
  in the human's prompt and costs a spurious turn, live 2026-07-19); the no-ACK `wake.failed`
  escalation remains that pod's terminal net. Tolerates `nil`/non-profile input (`true` — test
  stubs build pod data without a cap_profile).
  """
  @spec wake_send_keys?(t() | nil | term()) :: boolean()
  def wake_send_keys?(%__MODULE__{spec: spec}) when is_map(spec),
    do: get_in(spec, ["invocation", "wake_send_keys"]) != false

  def wake_send_keys?(_), do: true

  @doc """
  Is this pod VISIBLE in Claude Desktop? (`spec.invocation.remote_control`, default `true`.)
  `false` = the launcher omits `--remote-control` (pod functional but invisible — churny judges).
  Read spawner-side to decide whether to arm the Desktop-slot capture (a no-RC pod never
  registers a slot → nothing to capture/preserve). Twin of the launcher's jq read of the
  SAME field. Tolerates `nil`/non-profile input (`true`).
  """
  @spec remote_control?(t() | nil | term()) :: boolean()
  def remote_control?(%__MODULE__{spec: spec}) when is_map(spec),
    do: get_in(spec, ["invocation", "remote_control"]) != false

  def remote_control?(_), do: true

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
  Resolves the requested cap-profile NAME from an admin-spawn request DTO (string-keyed map):
  `cap_profile_name` takes precedence, `role` is the fallback; both blank-normalized (`""` / non-string
  → `nil`, so a truthy `""` never masks a valid `role`). SINGLE SOURCE of the `cap_profile_name || role`
  interpretation, shared by the API admission
  (`Fleet.API.SpawnAdmission`) and the async consumer (`Fleet.Spawner.PublishConsumer`) — the Bus is NOT
  a trust boundary, so both parse, but from ONE parser: the DTO interpretation cannot drift between what
  admission validates and what the consumer executes.
  """
  @spec name_from_request(map()) :: String.t() | nil
  def name_from_request(dto) when is_map(dto) do
    blank_to_nil(Map.get(dto, "cap_profile_name")) || blank_to_nil(Map.get(dto, "role"))
  end

  defp blank_to_nil(v) when is_binary(v) and v != "", do: v
  defp blank_to_nil(_), do: nil

  @doc """
  The role's index in the hexspeak UUID (`metadata.role_index`, 0..15) — the `R` nibble of the
  deterministic session_id. The role → slot catalogue lives HERE: the encoder `Fleet.Spawner.SessionId`
  no longer catalogues, it receives this index. **SINGLE SOURCE** of this read.

  **No fabricated default**: a cap-profile without an integer `role_index` is not a catalogued role (no
  hexspeak identity to rebuild) → we **raise** (fail-loud, like `name/1`). To branch WITHOUT risking the
  raise, first test presence with `catalogued?/1`.
  """
  @spec role_index(t()) :: 0..15
  def role_index(%__MODULE__{metadata: %{"role_index" => r}}) when is_integer(r) and r in 0..15,
    do: r

  # An out-of-range integer (or a missing/non-integer) role_index is NOT a valid nibble (the `R` of the
  # hexspeak session_id is 4 bits, 0..15): fail-loud rather than encode a corrupt identity. The `@spec`
  # `0..15` is now ENFORCED, not merely declared.
  def role_index(%__MODULE__{}),
    do:
      raise(
        ArgumentError,
        "CapProfile without a valid role_index (integer 0..15) — not a catalogued role"
      )

  # (`protected?/1` and `fleet_level?/1` were REMOVED by the 2026-07-19 reorg: once every other role
  # went per-project, both bits collapsed into "role_index 0 ≡ starfleet" — `kill_class/1` carries the
  # kill tier, and the fleet-scope (repo 0000) is `role_index == 0` at the mint. The schema no longer
  # accepts the fields.)

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
  """
  @spec slot_scope(t()) :: String.t()
  def slot_scope(%__MODULE__{} = profile) do
    case lifetime_scope(profile) do
      "one-shot" -> "instance"
      _context_long -> "project"
    end
  end

  @doc """
  The pod's KILL/LIFECYCLE class — the `<X>` nibble of the deterministic session_id
  (`Fleet.Spawner.SessionId.encode`), DERIVED from existing metadata (no new field):

    * `0` = **starfleet** (`role_index == 0`) — the fleet-level global orchestrator, NEVER killed
      (`pkill -f 1badcafe` / `2badcafe` spare it).
    * `2` = **spawn-dead** (`lifetime_scope == "one-shot"` — the fan-out judges) — ephemeral, accumulate,
      reaped by `pkill -f 2badcafe`.
    * `1` = **persistent-resumable** (everything else: arch, gatekeeper, engineer) — kill-SAFE, they
      resume their slot + context (Phase 0 slots). `pkill -f 1badcafe` restarts them without loss.

  Replaces the old `protected` bit as the `<X>` source: "protected" collapses into "class 0 = starfleet"
  (the arch moves from protected(0) to persistent(1) — kill-safe because resumable).
  """
  @spec kill_class(t()) :: 0..2
  def kill_class(%__MODULE__{} = profile) do
    cond do
      role_index(profile) == 0 -> 0
      lifetime_scope(profile) == "one-shot" -> 2
      true -> 1
    end
  end

  @doc """
  Is the cap-profile a CATALOGUED role (carries an integer `role_index`)? A predicate WITHOUT a raise —
  it is the presence test `Fleet.Spawner.Pod.SessionMint.mint/2` queries BEFORE calling `role_index/1`:
  a non-catalogued role (ad-hoc, out-of-fleet) has no deterministic identity to rebuild → a random
  session_id is legitimate for it, not an error.
  """
  @spec catalogued?(t()) :: boolean()
  def catalogued?(%__MODULE__{metadata: meta}) when is_map(meta) do
    # SAME 0..15 predicate as `role_index/1`: `catalogued?` true ⟺ `role_index/1` returns without raising
    # (the doc's promise — branch on `catalogued?` to avoid the raise). An out-of-range integer is NOT a
    # catalogued nibble.
    r = Map.get(meta, "role_index")
    is_integer(r) and r in 0..15
  end

  def catalogued?(%__MODULE__{}), do: false

  @doc """
  Returns the canonical JSON sha256 (lowercase hex) of a composed map
  or struct. Used by callers to assert deterministic composition.
  Underlying map iteration order is irrelevant — the canonical encoder
  (`Fleet.CapProfile.CanonicalJson`) sorts keys recursively before encoding.
  """
  @spec sha256(t() | map()) :: String.t()
  def sha256(%__MODULE__{} = profile), do: profile |> struct_to_map() |> sha256()
  def sha256(map) when is_map(map), do: CanonicalJson.sha256(map)

  # ============================================================
  # Catalogue FS (delegated)
  # ============================================================

  @doc """
  Lists the NAMES (`metadata.name`) of the catalogue's cap-profiles (`dir`, default `root_dir/0`).
  **Delegates** to the FS cluster `Fleet.CapProfile.Catalog`. Public + **consumed out-of-app**
  (`Fleet.Spawner.PermanentBoot` enumerates, `Fleet.Observation.Deck` lists the dashboard) →
  the API carried here stays put.
  """
  @spec list(String.t()) :: {:ok, [String.t()]} | {:error, term()}
  defdelegate list(), to: Catalog
  defdelegate list(dir), to: Catalog

  @doc """
  Root of the cap-profiles catalogue (`<root_dir>/<role>.yaml`). **SINGLE SOURCE**: every
  enumerator (e.g. `Fleet.Spawner.PermanentBoot`) MUST scan this dir, otherwise enum and load
  drift apart. **Delegates** to `Fleet.CapProfile.Catalog.root_dir/0` (consumed out-of-app).
  """
  @spec root_dir() :: String.t()
  defdelegate root_dir(), to: Catalog

  # ============================================================
  # Deep merge
  # ============================================================

  defp deep_merge_last_wins(left, right) when is_map(left) and is_map(right) do
    Map.merge(left, right, fn _key, lv, rv ->
      if is_map(lv) and is_map(rv), do: deep_merge_last_wins(lv, rv), else: rv
    end)
  end

  defp deep_merge_last_wins(_left, right), do: right

  # ============================================================
  # Struct conversion
  # ============================================================

  @doc """
  Canonical accessor for a cap-profile's `lifetime_scope` (`spec.invocation.lifetime_scope`,
  schema v2.5). **Single source**: the extraction must NOT be re-implemented at the readers
  (spawner/step_runner/sp_builder/pod) — otherwise inconsistent defaults. `default` defaults to
  `"one-shot"` (the canon default); readers that want to distinguish absence (e.g. brief_guard)
  pass `nil`.
  """
  @spec lifetime_scope(t(), term()) :: String.t() | term()
  def lifetime_scope(%__MODULE__{spec: spec}, default \\ "one-shot") do
    get_in(spec, ["invocation", "lifetime_scope"]) || default
  end

  @doc """
  Load-bearing accessor for `lifetime_scope` — NO default. `{:ok, scope}` iff the
  schema-REQUIRED field is present as a non-empty string, `{:error, :no_lifetime_scope}` otherwise.

  `lifetime_scope` decides at least four things (brief-required, slot scope, state-fs scope, release).
  A `%CapProfile{}` without it is an INVALID state that the STRUCT type still allows (a schema-loaded
  profile always has it; a hand-forged/unvalidated struct may not). The SPAWN path (`Fleet.Spawner.
  spawn_pod`, the choke point of every spawn) gates on THIS: an absent lifetime_scope is REFUSED, never
  spawned — otherwise the same profile receives DIVERGENT downstream reads (brief-exempt at the guard,
  yet `"one-shot"` at extraction via the lenient `lifetime_scope/2` default → releases). The lenient
  `lifetime_scope/2` stays for the derivations that run AFTER the gate (`slot_scope`, `Pod.Paths`),
  where the scope is guaranteed present.
  """
  @spec fetch_lifetime_scope(t()) :: {:ok, String.t()} | {:error, :no_lifetime_scope}
  def fetch_lifetime_scope(%__MODULE__{spec: spec}) do
    case get_in(spec, ["invocation", "lifetime_scope"]) do
      s when is_binary(s) and s != "" -> {:ok, s}
      _ -> {:error, :no_lifetime_scope}
    end
  end

  @doc """
  Canonical accessor for `deliverable_mode` (`spec.deliverable_mode`, schema v2.5). **Single source**:
  the publication-mode selection (`Fleet.Workflow.Deliverable.publish/1`) is read HERE, not
  re-implemented at the readers. `default` `"payload"` (the canon default, back-compat: a profile
  without the field = the-system-writes-the-payload). Code roles declare `git_native`.
  """
  @spec deliverable_mode(t(), term()) :: String.t() | term()
  def deliverable_mode(%__MODULE__{spec: spec}, default \\ "payload") do
    get_in(spec, ["deliverable_mode"]) || default
  end

  @doc """
  Canonical accessor for `brief_kind` (`spec.brief_kind`, schema v2.5). The INPUT dual of
  `deliverable_mode` (output): it declares the **shape of the brief** the role receives, by catalogue
  and NOT by a magic role name.

    * `"worker"` — the brief is an executable instruction (the issue body): the role ACTS (engineer,
      architect…). A worker profile can still be driven as a judge for a SPECIFIC step via the
      workflow_map's per-step `brief_kind: judge` override (`Fleet.Pilot.BriefBuilder`).
    * `"judge"` — the role JUDGES: it receives a `GateBrief` that is structurally **defused** (context +
      deliverable + verdict contract, NO executable instruction — otherwise the judge would run the body).

  `brief_kind` is **REQUIRED** by the schema (`spec.required`): judge-ness is a security property, NEVER
  inferred — a profile without it is REJECTED at load. There is NO silent `worker` default (a judge that
  forgot `judge` would otherwise fall back to worker=execute, running attacker-controlled issue content —
  the fail-open this closes). Returns `nil` only for a hand-built struct that bypassed the schema → the
  consumer (`BriefBuilder`) fail-louds on `nil` (out-of-vocab), never a silent worker.
  """
  @spec brief_kind(t()) :: String.t() | nil
  def brief_kind(%__MODULE__{spec: spec}) do
    get_in(spec, ["brief_kind"])
  end

  @doc """
  The role's fleet-MCP tool surface, DERIVED from `spec.scope.allowedTools` — the `mcp__fleet__<tool>`
  entries, stripped to `<tool>`. **Single source**: the pod-facing MCP `tools/list` is BUILT from
  this (the central serves it, filtered per role by the names the spawner threads from HERE) —
  one catalogue, no second copy anywhere on the wire path. The UNIVERSAL base
  (`get_work_item`/`submit_result` — every pod is a task-worker) is NOT here: it is the pod interface,
  added by the MCP authority; this returns only the role-GATED extras. Absent/empty `allowedTools` → `[]`.
  """
  @spec mcp_fleet_tools(t()) :: [String.t()]
  def mcp_fleet_tools(%__MODULE__{spec: spec}) do
    (get_in(spec, ["scope", "allowedTools"]) || [])
    |> Enum.filter(&(is_binary(&1) and String.starts_with?(&1, "mcp__fleet__")))
    |> Enum.map(&String.replace_prefix(&1, "mcp__fleet__", ""))
    |> Enum.uniq()
  end

  defp to_struct(raw) when is_map(raw) do
    %__MODULE__{
      kind: Map.get(raw, "kind"),
      metadata: stringify_keys(Map.get(raw, "metadata", %{})),
      spec: stringify_keys(Map.get(raw, "spec", %{}))
    }
  end

  # `metadata`/`spec` are guaranteed to have **deeply STRING keys**, here at
  # production (the single boundary `to_struct`). Readers (ProjectBootstrap,
  # sp_builder, spawner) access with string keys WITHOUT a defensive atom|string
  # double-lookup — the inconsistent shape (mixed keys) becomes structurally
  # impossible downstream. Structs (DateTime…) and scalars pass through as-is;
  # only map KEYS are stringified.
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
