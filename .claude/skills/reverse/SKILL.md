---
name: reverse
description: >
  Reconstruction des specs fonctionnelles et de l'architecture d'un repo/dossier local.
  Produit <repo>-specs.md + <repo>-architecture.md. Progress tracker inclus.
allowed-tools:
  - Read
  - Write
  - Glob
  - Grep
  - Bash(git:*)
  - Bash(wc:*)
when_to_use: >
  Use when the user says 'reverse' followed by a directory or repo path.
  Protocol keyword for architecture + specs reconstruction from code.
  Examples: 'reverse this repo', 'reverse /home/projects/my-app'.
argument-hint: "<directory-path>"
arguments:
  - target_path
---
# Skill: reverse

**Date** : 2026-03-22
**Dernière révision** : 2026-03-22
**Statut** : active — architect, consultant
**Référencé par** : fleet/system-prompt/sources/protocole.md

Reconstruit les specs fonctionnelles et l'architecture à partir du code — le code est la source de vérité.

---

## Définition

| Attribut | Valeur |
|---|---|
| Cible | Repo ou dossier de code (local ou cloné via `ponce`) |
| Angle | Architecture + comportement |
| Outputs fichier | `<repo>-specs.md` + `<repo>-architecture.md` |
| Output inline | Résumé archi ~10 lignes |

Mot-clé actif : `reverse` (sans backticks). `dry-reverse` = simulation sans écriture fichier.

Scope : **TOUS** les fichiers source — aucun skip, aucun raccourci.

---

## Séquence obligatoire

1. Scan structure : arborescence, entry points, build system, dépendances
2. Lecture systématique des fichiers sources (batch ≤3 par cycle)
3. Pour chaque module/composant : extraire responsabilité, API publique, dépendances, flux de données
4. **Écrire** les findings dans le rapport (append) — AVANT de Read le bloc suivant
5. Consolidation : architecture globale, patterns, flux inter-composants
6. Écriture du rapport final

Le rapport est incrémental : chaque Write est un checkpoint. Si la session coupe, le rapport partiel est exploitable.

---

## Progress tracker

À chaque cycle, écrire dans `<repo>-reverse/_progress.md` les fichiers traités et restants. Vérifier avant chaque Read si le fichier est déjà traité — si oui, skip.

---

## Points d'analyse par module

1. Architecture globale (modules, couches, patterns)
2. Entry points et flux d'exécution principaux
3. API publiques (signatures, contrats, types)
4. Dépendances internes (qui appelle qui)
5. Dépendances externes (libs, services)
6. Gestion d'état (storage, caches, config)
7. Protocoles et formats (wire protocols, fichiers, IPC)
8. Contraintes implicites (timing, ordering, limites)

---

## Outputs

Les deux outputs sont toujours produits (si un seul est demandé, c'est un `analyse`, pas un `reverse`) :

1. **specs** — specs fonctionnelles reconstruites, structurées par module/composant : responsabilité, API, flux, dépendances, contraintes → sauvé en `<repo>-specs.md`
2. **architecture** — vue d'ensemble : diagramme textuel de l'archi, patterns identifiés, décisions de design inférées, zones grises et dette documentaire → sauvé en `<repo>-architecture.md`

Affichage : résumé archi inline (~10 lignes) — entry points, stack, pattern dominant, taille estimée du projet.
