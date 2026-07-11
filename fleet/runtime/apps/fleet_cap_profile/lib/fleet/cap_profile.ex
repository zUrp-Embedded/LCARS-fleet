defmodule Fleet.CapProfile do
  @moduledoc """
  Capability Profile composer/loader/validator (LCARS schema v2.5).

  Pure data transformer: YAML on disk → composed `%Fleet.CapProfile{}`
  struct. No process, no state.

  Two roles in one module:

    * the `Fleet.CapProfile.Loader` behaviour (`load/1`, `compose/2`,
      `validate/1`); and
    * the single-authority accessor surface for a composed profile's
      properties (`name/1`, `role_index/1`, `containment/1`, `slot_scope/1`,
      `lifetime_scope/2`, `deliverable_mode/2`, `brief_kind/2`, …) — each the
      sole reader of its field, so cross-app callers never re-derive it.

  The schema version (LCARS v2.5) is pinned by the code / the bundled schema file path
  (`priv/schema/cap-profile-v2.5.json`), NOT by an embedded `apiVersion` field (that field was
  removed — R0.8-brick3). Every profile is matched against `priv/schema/cap-profile-v2.5.json`
  at load time. Modops are
  matched against `priv/schema/modop-profile.json` (strict — reserved
  keys forbidden, so a modop cannot override the base profile's
  containment/name/kind).

  Composition is deterministic: deep-merge last-wins in declared order;
  the canonical JSON encoding (recursive key sort) and the `:crypto` sha256
  live in `Fleet.CapProfile.CanonicalJson` (`sha256/1` here delegates). The
  pure G24 semantic invariants live in `Fleet.CapProfile.Invariants`
  (`validate/1` delegates).
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
  defstruct [:kind, :metadata, :spec]

  @type t :: %__MODULE__{
          kind: String.t(),
          metadata: map(),
          spec: map()
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
  are composed into the pod's system prompt by `SPBuilder.compose`, F-C146/PORT). `[]` if absent, or if
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
  (`priv/canon/cap-profiles/_baseline-git-denied.yaml`) — **raises** fail-closed if
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
  tmpfs /home + bind credentials, the default); `"none"` = host-native (interactive-architect, starfleet —
  the pod runs ON THE HOST *as* the human, outside the sandbox = the strongest power in the fleet).

  **SINGLE SOURCE** of this read (the spawner selects the N0 launcher off it, the spawn API forbids
  host-native). Default `"bwrap"` if the key is absent: missing containment ⇒ we assume the confined
  mode, never the host — a config gap must NEVER open the host by default.
  """
  @spec containment(t()) :: String.t()
  def containment(%__MODULE__{metadata: meta}) when is_map(meta),
    do: Map.get(meta, "containment") || Map.get(meta, :containment) || @default_containment

  def containment(%__MODULE__{}), do: @default_containment

  @doc """
  The default containment mode (`"bwrap"`, sandboxed pod) — SINGLE SOURCE of the literal, referenced
  by cross-app readers rather than re-typing it.
  """
  @spec default_containment() :: String.t()
  def default_containment, do: @default_containment

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

  @doc """
  Is the role a PROTECTED TIER (`metadata.protected`)? `true` = spared by the worker kill
  (`pkill -f 1badcafe`) and encoded `0badcafe` in the session_id. **SINGLE SOURCE** of this read.

  Default `false` (unprotected) if the key is absent or non-boolean: a conservative default — a config
  gap NEVER promotes a role to the protected tier.
  """
  @spec protected?(t()) :: boolean()
  def protected?(%__MODULE__{metadata: %{"protected" => p}}) when is_boolean(p), do: p
  def protected?(%__MODULE__{}), do: false

  @doc """
  Is the role FLEET-LEVEL (`metadata.fleet_level`)? `true` = a single instance, repo always
  `0000` (no project dimension). `false` = project-bound → the session_id REQUIRES the repo (otherwise
  cross-project collision). **SINGLE SOURCE** of this read.

  Default `false` (project-bound) if the key is absent or non-boolean: a conservative default — we never
  promote a role to fleet-level status (repo 0000) by accident.
  """
  @spec fleet_level?(t()) :: boolean()
  def fleet_level?(%__MODULE__{metadata: %{"fleet_level" => f}}) when is_boolean(f), do: f
  def fleet_level?(%__MODULE__{}), do: false

  @doc """
  The role's identity/slot granularity (`metadata.slot_scope`) — an axis ORTHOGONAL to `lifetime_scope`.
  `"project"`: pod_id per (repo, role) → ONE identity per project → ONE stable Desktop slot (cwd +
  session-id pinned), dispatch serialized per (repo, role) (engineer, fleet-level singletons). `"instance"`:
  pod_id per (repo, number, role) → fan-out per issue/PR (ephemeral judges). **SINGLE SOURCE** of this
  read: `Fleet.Pilot.StepDispatcher` chooses `PodId.for_repo` vs `for_issue`/`for_pr` off it.

  **No fabricated default** (like `role_index/1` / `name/1`): the slot policy is a routing property
  declared explicitly by EACH role — a profile without `slot_scope ∈ {project, instance}` is a
  catalogue gap → we **raise** (fail-loud), never a silent inference in code.
  """
  @spec slot_scope(t()) :: String.t()
  def slot_scope(%__MODULE__{metadata: %{"slot_scope" => s}}) when s in ["project", "instance"],
    do: s

  def slot_scope(%__MODULE__{}),
    do:
      raise(
        ArgumentError,
        "CapProfile without metadata.slot_scope ∈ {project, instance} — slot policy not declared " <>
          "(catalogue-only, no default: declare the scope in the role's cap-profile)"
      )

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
  entries, stripped to `<tool>`. **Single source** (F-C138): the pod-facing MCP `tools/list` is BUILT from
  this (the central serves it, filtered per role by the names the spawner threads from HERE) — the stdio
  bridge no longer hard-codes a second, divergent catalogue. The UNIVERSAL base
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
