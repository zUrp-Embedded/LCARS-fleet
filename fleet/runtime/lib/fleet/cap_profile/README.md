# fleet_cap_profile

**Date** : 2026-07-13
**Dernière révision** : 2026-07-18 (en-tête déclaratif LCARS ajouté — uniformisation acte3 vague A ; carte co-localisée `lib/fleet/<dom>/` depuis le collapse)
**Statut** : actif — composeur/loader/validateur de cap-profiles (substrat, schéma v2.5)
**Référencé par** : —

Capability Profile composer/loader/validator (substrate, LCARS schema v2.5):
a pure data transformer, YAML on disk → composed `%Fleet.CapProfile{}` struct, no
process/state. Also hosts two cross-cutting foundation utilities: `Fleet.Slug` and `Fleet.Layout`.

**This file is a map, not the contract.** Each module owns its contract in its own
`@moduledoc` — read those (`h Fleet.CapProfile` in IEx, or `lib/`). Nothing here is
restated, only pointed at.

## Modules
- `Fleet.CapProfile` — public-API surface: the `Fleet.CapProfile.Loader` behaviour (`load/1`, `compose/2`, `validate/1`) + the single-authority accessors (`containment/1`, `slot_scope/1`, `with_project/2`, `sha256/1`…); delegates to the clusters below
- `Fleet.CapProfile.Loader` — the loader/composer/validator behaviour (test mocks + a future 2nd vendor)
- `Fleet.CapProfile.Schema` — JSON-schema structural validation (`:cap_profile` / `:modop`); `priv/cap_profile/schema/` cached in `:persistent_term`
- `Fleet.CapProfile.Invariants` — the pure G24 semantic invariants (one fn per check, FROZEN `:g24_*` error codes)
- `Fleet.CapProfile.Catalog` — FS front of the catalogue (scan/decode, resolve by `metadata.name`, Slug-confined)
- `Fleet.CapProfile.DisallowedTools` — write-time `spec.scope.disallowedTools` resolution (baseline ∪ profile patterns)
- `Fleet.CapProfile.CanonicalJson` — canonical (order-independent) JSON encode + sha256 (FROZEN hash format)
- `Fleet.Slug` — path-safe smart-constructor `^[a-z0-9][a-z0-9_-]*$` (cross-cutting R0 utility, reused fleet-wide)
- `Fleet.Layout` — platform layout authority ("where things live", hard-coded roots — cross-cutting R0 utility)

## Config & deps
... default = bundled `priv/cap_profile/canon/cap-profiles`.
- Knob `:fleet_cap_profile, :schema_dir` — read by `Schema`; default = bundled `priv/cap_profile/schema`.
- Deps: see `mix.exs`.
