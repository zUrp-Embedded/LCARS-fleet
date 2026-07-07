# Fleet.CapProfile

**Date**: 2026-05-09
**Last revised**: 2026-07-07 (translated to EN; resynced against the code: `do_allocate` ref replaced by the real spawn-boundary mechanism, `apiVersion` dropped from the modop reserved keys [removed from the schema], API admission module = `Fleet.API.SpawnAdmission`. Previous resync 2026-07-05: Ring 0 [renumbering 2026-07-04], + `Fleet.Layout` section, `:schema_dir` knob + `LCARS_CAPPROFILES_ROOT` env, exact g24_9_strict/prefix codes; canonical encoding + sha256 extracted into `Fleet.CapProfile.CanonicalJson`, `sha256/1` API unchanged)
**Status**: implemented — design note PROMOTED
**Referenced by**: 04_design-notes/fleet_cap_profile.md

Capability Profile composer/loader/validator (LCARS schema v2.5).

Pure data-transformer module — YAML on disk → composed Elixir struct.
Behaviour `Fleet.CapProfile.Loader` exposed for test mocks + a future 2nd vendor
(callbacks `load/1`, `compose/2`, `validate/1`; default implementation =
`Fleet.CapProfile`). Also hosts two cross-cutting Ring 0 utilities:
`Fleet.Slug` and `Fleet.Layout` (dedicated sections).

## API

- `Fleet.CapProfile.load/1` — loads a cap-profile from the FS, validates schema; **delegates**
  JSON-schema conformance to the `Fleet.CapProfile.Schema` cluster (`validate/2`)
- `Fleet.CapProfile.compose/2` — composes role + modop_set, deep-merge last-wins; validates base +
  result via `Fleet.CapProfile.Schema.validate/2`, and the modop fragments via
  `Fleet.CapProfile.Schema.validate_modop_keys/1` (reserved keys) + `validate/2`
- `Fleet.CapProfile.validate/1` — G24 invariants (incl. `g24_9_strict`/`g24_9_prefix`: refusal of
  Anthropic's native server-tools, which run server-side and are therefore outside the bwrap sandbox
  by construction); **delegates** to the pure cluster `Fleet.CapProfile.Invariants` (one function per
  check, FROZEN error codes `:g24_1` … `:g24_14`), keeps only the single-authority
  return contract `:ok | {:error, [codes]}` consumed out of the app (the spawner's spawn-boundary
  containment gate — `Fleet.Spawner.Pod`, `:allocating` boot step — and
  `mix lcars.contracts.check`)
- `Fleet.CapProfile.containment/1` — `metadata.containment` (`"bwrap"` sandboxed / `"none"` host-native;
  conservative default `"bwrap"`). **SINGLE source** of this read: the spawner selects the N0 launcher
  on it, the `/api/admin/spawn` API REFUSES host-native on it (a config hole must never open the host)
- `Fleet.CapProfile.default_containment/0` / `bwrap?/1` — **single source of the `"bwrap"` literal**
  (default sandboxed mode, `@default_containment`) + host-native predicate. API admission
  (`Fleet.API.SpawnAdmission`) decides via `bwrap?/1` instead of retyping the literal
- `Fleet.CapProfile.slot_scope/1` — `metadata.slot_scope` (`"project"` = 1 Desktop identity/slot per
  project; `"instance"` = fan-out per issue; **required, no default → raise**). **SINGLE source**: the
  dispatcher (`Fleet.Pilot.StepDispatcher`) picks `PodId.for_repo` vs `for_issue`/`for_pr` and
  serializes project-scoped roles on it
- `Fleet.CapProfile.with_project/2` — returns a `%CapProfile{}` whose `spec.project` is REPLACED by the
  given effective project (string-keyed map). **SINGLE source** of the brief > static substitution: a
  project pod may receive its project from the issue→repo dispatch rather than from the cap-profile
  YAML; the spawner call-sites (`Pod.Scaffold.maybe_bootstrap_project_workspace`, `Pod`'s workspace
  reprovision) go through it instead of re-hacking the `spec` map
- `Fleet.CapProfile.sha256/1` — stable canonical hash of a composed profile (struct or map).
  **Delegates** to the `Fleet.CapProfile.CanonicalJson` cluster (extracted concern: « composition
  determinism », orthogonal to the loader and the accessors) — `CanonicalJson.encode/1` (canonical
  JSON, keys stringified then recursively sorted, FROZEN hash format) + `CanonicalJson.sha256/1`
  (lowercase hex). The API hosted here does not move

## Fleet.Slug — path-safe smart-constructor (cross-cutting utility)

SINGLE source of the path-safe charset `^[a-z0-9][a-z0-9_-]*$` (hosted here, Ring 0, reused
by spawner / workflow / credentials / pilot). Every client/payload/catalogue name interpolated
into a `Path.join` (FS leaf) or a bounded URL segment goes through it — fail-closed.

- `Fleet.Slug.cast/1` — `{:ok, slug}` or `{:error, {:invalid_slug, raw}}`
- `Fleet.Slug.cast!/1` — bang (raises `ArgumentError`) for sites where an invalid name = caller bug
- `Fleet.Slug.valid?/1` — boolean predicate
- `Fleet.Slug.under_root?/2` — confinement guard (resolved dest stays under root)
- `Fleet.Slug.confined_join/2` — cast + join under root + confine, in one gesture (FS leaf)

## Fleet.Layout — platform layout authority (cross-cutting utility)

SINGLE authority on « where things live » on the box (doctrine
2026-07-04: LCARS lives ALONE in a dedicated container, layout IMPOSED by
design — structural, hard-coded, typed ONCE, **not deployment
knobs**). Ring 0, next to `Fleet.Slug`; consumed by spawner /
pilot / starfleet. Consumers' TEST seams (e.g. `seed_store_root`)
stay: their default derives from here.

- `Fleet.Layout.projects_root/0` — root of the working repos (`/home/projects`)
- `Fleet.Layout.work_root/0` — meta/ops root (`/home/projects.work`: journals, seeds, resume)
- `Fleet.Layout.state_dir/0` — per-human runtime state (`~/.lcars`); unresolvable HOME
  = fail-loud (`System.user_home!/0` raises), never a fabricated path

## Schemas

Structural validation carried by `Fleet.CapProfile.Schema` (extracted cluster, UPSTREAM of the core —
distinct from the G24 business invariants of `Fleet.CapProfile.Invariants`):

- `Fleet.CapProfile.Schema.validate/2` — validates a raw map against the kind's JSON-schema
  (`:cap_profile` / `:modop`); returns `:invalid_schema` / `:invalid_modop` / `:schema_unavailable`
- `Fleet.CapProfile.Schema.validate_modop_keys/1` — refuses a modop fragment carrying a reserved
  top-level key (`kind`)
- schemas cached in `:persistent_term` (keyed by resolved path — assumed local copy of the
  `Fleet.SchemaCache` pattern, no intra-R0 edge toward `fleet_event_router`); `schema_dir` reads the
  env key `:fleet_cap_profile, :schema_dir` (overridable in test), default `priv/schema`

Files:

- `priv/schema/cap-profile-v2.5.json` — strict JSON Schema of the composed profile
- `priv/schema/modop-profile.json` — strict JSON Schema of the modop fragment
  (forbidden reserved keys: kind, metadata.containment, metadata.name)

## DisallowedTools

Write-time resolution of `spec.scope.disallowedTools` carried by the
`Fleet.CapProfile.DisallowedTools` cluster (extracted from the core — SINGLE concern
`disallowedTools`, touches no other face of the profile; depends on the
`%Fleet.CapProfile{}` struct, not on the core API → no cycle). `Fleet.CapProfile`
exposes the three helpers as **delegators** (the public API consumed out of the app does
not move):

- `Fleet.CapProfile.with_resolved_disallowed_tools/1` → `DisallowedTools.with_resolved/1` —
  merges (uniq, order preserved) existing `disallowedTools` ∪ universal baseline ∪
  profile patterns. **Consumed by `Fleet.Spawner.Pod`** at the `:allocating` boot step
  (`.cap-profile.json` write). Idempotent
- `Fleet.CapProfile.git_ops_denied_patterns/1` → `DisallowedTools.git_ops_denied_patterns/1` —
  translates `spec.scope.git_ops_denied` into claude CLI patterns `Bash(git <entry>:*)`
- `Fleet.CapProfile.baseline_git_ops_denied_patterns/0` → `DisallowedTools.baseline_patterns/0` —
  patterns of the intangible universal baseline; **raises** fail-closed if the baseline is
  absent/corrupt

File + cache:

- `priv/canon/cap-profiles/_baseline-git-denied.yaml` — intangible universal baseline
  (resolved via `:code.priv_dir(:fleet_cap_profile)`); read+parse cached in
  `:persistent_term` (lazy, errors not cached)

## Catalog

FS front of the catalogue (directory scan, YAML decoding, resolution of a role/modop into a raw
pre-`to_struct` map) carried by the `Fleet.CapProfile.Catalog` cluster (extracted from the core —
SINGLE concern: the catalogue's I/O; the `load`/`compose` core never touches the FS).
UPSTREAM of the core: depends on `Fleet.CapProfile.Schema` (modop validation) + `Fleet.Slug`
(confinement), neither calls Catalog → no cycle. **Security invariant**: a
profile is resolved by its `metadata.name` prop, **never** by the file name
(cosmetic) — enum and load share the same key; a modop name is confined under
`<root>/modop/` via `Fleet.Slug.confined_join/2` (fail-closed).

- `Fleet.CapProfile.Catalog.read_role/1` — resolves by `metadata.name`, returns the raw map
  (`{:ok, raw}` / `:not_found` / `:invalid_schema`). Called by `load/1` + `compose/2` (core)
- `Fleet.CapProfile.Catalog.read_modops/1` — reads + validates (via `Schema`) the named modop
  fragments, order preserved, Slug confinement. Called by `compose/2` (core)
- `Fleet.CapProfile.Catalog.list/1` — names (`metadata.name`) of the catalogue, sorted;
  `:name_collision` fail-loud on duplicate
- `Fleet.CapProfile.Catalog.root_dir/0` — FS root of the catalogue

`Fleet.CapProfile` re-exposes `list/1` (arities 0 and 1) and `root_dir/0` as **delegators**
(the public API consumed **out of the app** does not move):

- `Fleet.CapProfile.list/0,1` → `Catalog.list/0,1` — **SINGLE source** of enumeration;
  consumed by `Fleet.Spawner.PermanentBoot` (aligns its dir + enumerates) and
  `Fleet.Observation.Deck` (dashboard roles)
- `Fleet.CapProfile.root_dir/0` → `Catalog.root_dir/0` — consumed by `Fleet.Spawner.PermanentBoot`

## Configuration

- `:fleet_cap_profile, :root_dir` — FS root of the cap-profiles, read by
  `Fleet.CapProfile.Catalog.root_dir/0` (tests drive it via `Application.put_env/3`).
  Default = the BUNDLED canon `priv/canon/cap-profiles` resolved via
  `:code.priv_dir(:fleet_cap_profile)` (resolves in a release as in dev, without env).
  Set by `config/runtime.exs` from the `LCARS_CAPPROFILES_ROOT` env (the same
  env source also sets `:fleet_spawner, :cap_profiles_dir` — shared canon path)
- `:fleet_cap_profile, :schema_dir` — directory of the JSON-schemas, read by
  `Fleet.CapProfile.Schema` (overridable in test). Default = `priv/schema`
  resolved via `:code.priv_dir(:fleet_cap_profile)`
