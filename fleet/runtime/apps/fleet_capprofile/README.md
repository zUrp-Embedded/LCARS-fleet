# Fleet.CapProfile

**Date** : 2026-05-09
**Dernière révision** : 2026-05-22
**Statut** : implémenté run #3.1 chantier #1 — design note PROMOTED
**Référencé par** : 04_design-notes/fleet_capprofile.md

Capability Profile composer/loader/validator (LCARS schema v2.5).

Module pure data transformer — YAML on disk → struct Elixir composée.
Behaviour `Fleet.CapProfile.Loader` exposé pour mock test + futur 2e vendor.

## API

- `Fleet.CapProfile.load/1` — charge un cap-profile depuis le FS, valide schema
- `Fleet.CapProfile.compose/2` — compose role + modop_set, deep-merge last-wins
- `Fleet.CapProfile.validate/1` — 9 invariants G24 (incl. G24-9 F-CONT-RISK)
- `Fleet.CapProfile.sha256/1` — hash canonique stable d'un profile composé

## Schemas

- `priv/schema/cap-profile-v2.5.json` — JSON Schema strict du profile composé
- `priv/schema/modop-profile.json` — JSON Schema strict du fragment modop
  (clés réservées interdites : apiVersion, kind, metadata.containment,
  metadata.name)

## Configuration

- `:fleet_capprofile, :root_dir` — racine FS des cap-profiles (default
  `cap-profiles` cwd-relative)
