# Fleet.CapProfile

**Date** : 2026-05-09
**Dernière révision** : 2026-07-02
**Statut** : implémenté run #3.1 chantier #1 — design note PROMOTED
**Référencé par** : 04_design-notes/fleet_cap_profile.md

Capability Profile composer/loader/validator (LCARS schema v2.5).

Module pure data transformer — YAML on disk → struct Elixir composée.
Behaviour `Fleet.CapProfile.Loader` exposé pour mock test + futur 2e vendor.

## API

- `Fleet.CapProfile.load/1` — charge un cap-profile depuis le FS, valide schema ; **délègue** la
  conformité JSON-schema au cluster `Fleet.CapProfile.Schema` (`validate/2`)
- `Fleet.CapProfile.compose/2` — compose role + modop_set, deep-merge last-wins ; valide base +
  résultat via `Fleet.CapProfile.Schema.validate/2`, et les fragments modop via
  `Fleet.CapProfile.Schema.validate_modop_keys/1` (clés réservées) + `validate/2`
- `Fleet.CapProfile.validate/1` — invariants G24 (incl. G24-9 F-CONT-RISK) ; **délègue** au
  cluster pur `Fleet.CapProfile.Invariants` (une fonction par check), n'y garde que le contrat de
  retour single-authority `:ok | {:error, [codes]}` consommé hors-app (spawner `do_allocate`,
  `mix lcars.contracts.check`)
- `Fleet.CapProfile.containment/1` — `metadata.containment` (`"bwrap"` sandboxé / `"none"` host-native ;
  défaut conservateur `"bwrap"`). **Source UNIQUE** de cette lecture : le spawner sélectionne le launcher N0
  dessus, l'API `/api/admin/spawn` REFUSE le host-native dessus (un trou de config ne doit jamais ouvrir l'hôte)
- `Fleet.CapProfile.slot_scope/1` — `metadata.slot_scope` (`"project"` = 1 identité/slot Desktop par projet ;
  `"instance"` = fan-out par issue ; **requis, sans défaut → raise**). **Source UNIQUE** : le dispatcher
  (`Fleet.Pilot.StepDispatcher`) choisit `PodId.for_repo` vs `for_issue`/`for_pr` et sérialise les rôles
  project-scoped là-dessus
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

Validation structurelle portée par `Fleet.CapProfile.Schema` (cluster extrait, en AMONT du cœur —
distinct des invariants métier G24 de `Fleet.CapProfile.Invariants`) :

- `Fleet.CapProfile.Schema.validate/2` — valide une map brute contre le JSON-schema du kind
  (`:cap_profile` / `:modop`) ; retourne `:invalid_schema` / `:invalid_modop` / `:schema_unavailable`
- `Fleet.CapProfile.Schema.validate_modop_keys/1` — refuse un fragment modop portant une clé
  réservée top-level (`kind`)
- schemas cachés en `:persistent_term` (keyé par path résolu) ; `schema_dir` lit la clé env
  `:fleet_cap_profile, :schema_dir` (surchargeable en test), défaut `priv/schema`

Fichiers :

- `priv/schema/cap-profile-v2.5.json` — JSON Schema strict du profile composé
- `priv/schema/modop-profile.json` — JSON Schema strict du fragment modop
  (clés réservées interdites : apiVersion, kind, metadata.containment,
  metadata.name)

## DisallowedTools

Résolution write-time de `spec.scope.disallowedTools` portée par le cluster
`Fleet.CapProfile.DisallowedTools` (extrait du cœur — concern UNIQUE
`disallowedTools`, ne touche aucune autre face du profil ; dépend du struct
`%Fleet.CapProfile{}`, pas de l'API cœur → pas de cycle). `Fleet.CapProfile`
expose les trois helpers en **délégateurs** (l'API publique consommée hors-app ne
bouge pas) :

- `Fleet.CapProfile.with_resolved_disallowed_tools/1` → `DisallowedTools.with_resolved/1` —
  fusionne (uniq, ordre préservé) `disallowedTools` existant ∪ baseline universel ∪
  patterns du profil. **Consommé par `Fleet.Spawner.Pod.do_allocate/1`** (écriture
  `.cap-profile.json`). Idempotent
- `Fleet.CapProfile.git_ops_denied_patterns/1` → `DisallowedTools.git_ops_denied_patterns/1` —
  traduit `spec.scope.git_ops_denied` en patterns claude CLI `Bash(git <entrée>:*)`
- `Fleet.CapProfile.baseline_git_ops_denied_patterns/0` → `DisallowedTools.baseline_patterns/0` —
  patterns du baseline universel intangible ; **raise** fail-closed si baseline absent/corrompu

Fichier + cache :

- `priv/canon/cap-profiles/_baseline-git-denied.yaml` — baseline universel intangible
  (résolu via `:code.priv_dir(:fleet_cap_profile)`) ; read+parse caché en
  `:persistent_term` (lazy, erreurs non-cachées)

## Configuration

- `:fleet_cap_profile, :root_dir` — racine FS des cap-profiles (default
  `cap-profiles` cwd-relative)
