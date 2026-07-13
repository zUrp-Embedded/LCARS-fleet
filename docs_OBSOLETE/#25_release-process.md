# Release Process — LCARS

**Date** : 2026-03-23
**Dernière révision** : 2026-03-30
**Statut** : v6.0-RC
**Référencé par** : #00_index.md
**Dérivé de** : —

> Modèle FreeBSD appliqué à LCARS. Cycle : freeze → beta → RC → release.

---

## Modèle de version

LCARS suit un versionning **umbrella** :

- `LCARS v1.x` nomme le système distribué dans son ensemble
- le **runtime** et le **jeu de règles** peuvent avancer séparément
- ce qui doit rester stable n'est pas l'identité de numéro partout, mais la **compatibilité de l'interface** entre couches

En pratique :

- la release publique initiale fixera une version minimale de compatibilité
- tant que runtime et règles restent compatibles, LCARS reste dans le même major umbrella
- le freeze actuel porte sur la fermeture propre du couple runtime/règles `v6`, en vue du passage `v6-rc`

---

## Rôles

| Rôle | Qui | Responsabilité |
|---|---|---|
| Release manager | User | Décide ce qui passe, valide les transitions, donne le go |
| Release engineer | StarFleet | Exécute le workflow, gère les tags, les merges, `fleet-update` |
| Coherence gate | Architect | Valide la cohérence directives↔runtime avant chaque transition |

---

## Phases

```
CURRENT (feature-open)
    │
    ▼  ── triage ──
    │
FREEZE (fix-only)          ← /lcars-fix passe, /lcars-feature bloqué
    │  audit architect
    │  fleet-doctor 0 FAIL
    │  drift-audit clean
    ▼
BETA (test)                ← tout est là, on observe
    │  48h observation
    │  RC-critical only
    ▼
RC (candidat)              ← showstopper only
    │  fleet-doctor 0 FAIL (re-check)
    ▼
RELEASE                    ← tag, freeze retrocompat
```

---

## Détail par phase

### 1. Freeze

**Entrée** : décision user. StarFleet encode dans `fleet-system.yaml` :

```yaml
fleet:
  version: "6.0.0-beta"
  release_phase: "freeze"
  release_target: "6.0.0"
```

**Ce qui passe** : bug fixes, corrections de docs, purge de résidus. Via `/lcars-fix` uniquement.

**Ce qui ne passe pas** : nouvelles features, refactoring, changements de topologie. Via `/lcars-feature` — bloqué pendant le freeze.

**Exception — MFC (Merge From Current)** : features critiques pré-approuvées par le release manager. Fenêtre MFC limitée, fermée explicitement.

**Travail architect** : audit des directives (cohérence interne, cross-check runtime, refs mortes, stale). Bump des headers.

**Critères de sortie** :
- audit architect terminé
- `fleet-doctor.sh` → exit 0 (0 FAIL)
- `/drift-audit` → rapport clean
- MFC window fermée

**Transition** : release manager donne le go. StarFleet bump `release_phase: "beta"`.

### 2. Beta

**Entrée** : toutes les modifications sont en place. On observe.

**Durée** : 48h minimum. Pas de timer mécanique — le release manager juge.

**Ce qui passe** : RC-critical fixes uniquement. Un fix RC-critical = "sans ce fix, la release est inutilisable".

**Observation** :
- usage normal de la fleet sur des projets réels
- vérifier que les agents se comportent conformément aux directives
- vérifier que les skills fonctionnent
- vérifier que l'IPC route correctement

**Critères de sortie** :
- 48h sans régression
- pas de FAIL dans `fleet-doctor`
- aucun comportement agent incohérent avec les directives

**Transition** : release manager donne le go. StarFleet bump `release_phase: "rc"`.

### 3. RC (Release Candidate)

**Entrée** : beta stable. On prépare la release.

**Ce qui passe** : showstoppers uniquement. Un showstopper = "la fleet ne peut pas fonctionner".

**Préparation release** :
- vérification finale `fleet-doctor` (0 FAIL)
- drift-audit final
- changelog (manuel — depuis `git log`)
- README à jour
- docs canoniques au cordeau

**Critères de sortie** :
- `fleet-doctor` 0 FAIL
- `drift-audit` clean
- README reflète l'état actuel
- docs canoniques reflètent l'état réel
- release manager valide

**Transition** : release manager donne le go final.

### 4. Release

**Actions StarFleet** :
1. Bump des versions stables de release
2. Tag git annoté
3. Push via `/push-github`
4. `fleet-update.sh` sur le runtime
5. `fleet-doctor.sh` — vérification post-deploy

**Artefacts** :
- tag git sur `main`
- changelog (si applicable)
- docs et headers stables sur les fichiers source

---

## Outils

### fleet-doctor.sh

Diagnostic complet de la fleet.

```bash
fleet-doctor.sh
fleet-doctor.sh 3
fleet-doctor.sh --help
```

- exit 0 = 0 FAIL (WARN acceptés)
- exit 1 = au moins 1 FAIL
- rôles non-provisionnés = WARN, pas FAIL

### fleet-update.sh

Déploie les changements depuis GitHub vers le runtime.

```bash
fleet-update.sh
fleet-update.sh --dry-run
fleet-update.sh --force
```

Séquence interne :
1. `git pull --ff-only` sur `/local/LCARS/`
2. normalisation `chmod/chgrp`
3. `fleet-build-yaml.sh`
4. `deploy.sh`

Toujours vérifier après :

```bash
fleet-update.sh && fleet-doctor.sh
```

### /drift-audit

Skill de vérification de cohérence. Contrôle sources, runtime, hooks, déploiement, plans et références.

### /lcars-fix et /lcars-feature

| Skill | Quand | Pendant freeze |
|---|---|---|
| `/lcars-fix` | Correction ciblée (≤8 fichiers modifiés, ≤2 créés, 0 supprimés) | ✅ Autorisé |
| `/lcars-feature` | Au-delà du boundary quick-fix | ❌ Bloqué |

---

## Checklist release

```
Phase FREEZE :
  [ ] fleet-system.yaml → release_phase: "freeze"
  [ ] MFC features identifiées et listées
  [ ] MFC window fermée
  [ ] Audit architect terminé
  [ ] fleet-doctor 0 FAIL
  [ ] drift-audit clean

Phase BETA :
  [ ] fleet-system.yaml → release_phase: "beta"
  [ ] 48h observation
  [ ] Pas de régression
  [ ] fleet-doctor 0 FAIL (re-check)

Phase RC :
  [ ] fleet-system.yaml → release_phase: "rc"
  [ ] fleet-doctor 0 FAIL (final)
  [ ] drift-audit clean (final)
  [ ] README à jour
  [ ] Docs canoniques à jour

Phase RELEASE :
  [ ] Versions stables alignées
  [ ] Tag annoté
  [ ] Push GitHub
  [ ] fleet-update.sh
  [ ] fleet-doctor.sh post-deploy
  [ ] release_phase: "stable"
```

---

## Rollback

Si la release casse :

1. **Fix forward** (préféré) : `/lcars-fix` sur le problème identifié, re-deploy
2. **Rollback tag** : checkout d'une version précédente sur `/local/LCARS/`, puis `deploy.sh --force`
3. **Rollback complet** : `fleet-update.sh` après revert sur `main`

Le rollback complet est destructif. Toujours tenter le fix forward d'abord.
