# Fleet.CapProfile

**Date** : 2026-05-09
**Dernière révision** : 2026-06-25
**Statut** : implémenté run #3.1 chantier #1 — design note PROMOTED
**Référencé par** : 04_design-notes/fleet_cap_profile.md

Capability Profile composer/loader/validator (LCARS schema v2.5).

Module pure data transformer — YAML on disk → struct Elixir composée.
Behaviour `Fleet.CapProfile.Loader` exposé pour mock test + futur 2e vendor.

## API

- `Fleet.CapProfile.load/1` — charge un cap-profile depuis le FS, valide schema
- `Fleet.CapProfile.compose/2` — compose role + modop_set, deep-merge last-wins
- `Fleet.CapProfile.validate/1` — 9 invariants G24 (incl. G24-9 F-CONT-RISK)
- `Fleet.CapProfile.containment/1` — `metadata.containment` (`"bwrap"` sandboxé / `"none"` host-native ;
  défaut conservateur `"bwrap"`). **Source UNIQUE** de cette lecture : le spawner sélectionne le launcher N0
  dessus, l'API `/api/admin/spawn` REFUSE le host-native dessus (un trou de config ne doit jamais ouvrir l'hôte)
- `Fleet.CapProfile.sha256/1` — hash canonique stable d'un profile composé

## Fleet.Slug — smart-constructor path-safe (utilitaire transverse)

Source UNIQUE du charset path-safe `^[a-z0-9][a-z0-9_-]*$` (hébergé ici, Ring 1, réutilisé
par spawner / pipeline / credentials / pilot). Tout nom de client/payload/catalogue interpolé
dans un `Path.join` (feuille FS) ou un segment d'URL borné passe par lui — fail-closed.

- `Fleet.Slug.cast/1` — `{:ok, slug}` ou `{:error, {:invalid_slug, raw}}`
- `Fleet.Slug.cast!/1` — bang (raise `ArgumentError`) pour les sites où un nom invalide = bug appelant
- `Fleet.Slug.valid?/1` — prédicat booléen
- `Fleet.Slug.under_root?/2` — garde de confinement (dest résolu reste sous root)
- `Fleet.Slug.confined_join/2` — caste + joint sous root + confine, en un geste (feuille FS)

## Schemas

- `priv/schema/cap-profile-v2.5.json` — JSON Schema strict du profile composé
- `priv/schema/modop-profile.json` — JSON Schema strict du fragment modop
  (clés réservées interdites : apiVersion, kind, metadata.containment,
  metadata.name)

## Configuration

- `:fleet_cap_profile, :root_dir` — racine FS des cap-profiles (default
  `cap-profiles` cwd-relative)
