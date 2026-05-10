---
name: audit
description: >
  Audit de conformite et dette technique d'un dossier de code.
  Produit audit-report/ (rapports detailles + derives + bilan). Progress tracker inclus.
  Contrainte batch : <=3 fichiers par cycle.
allowed-tools:
  - Read
  - Write
  - Glob
  - Grep
  - Bash(wc:*)
  - Bash(git:*)
when_to_use: >
  Use when the user says 'audit' followed by a directory or file path.
  This is the protocol keyword for exhaustive code conformity analysis.
  See protocole.md for the full definition. Not for quick reviews (use 'review')
  or content evaluation (use 'evalue').
argument-hint: "<directory-path>"
arguments:
  - target_path
---
# Skill: audit

**Date** : 2026-03-22
**Dernière révision** : 2026-03-22
**Statut** : active — architect, consultant
**Référencé par** : fleet/system-prompt/sources/protocole.md

Audit exhaustif d'un dossier de code : conformité, dette, sécurité, références cassées.

---

## Définition

| Attribut | Valeur |
|---|---|
| Cible | Dossier complet ou ensemble de fichiers de code |
| Angle | Conformité + dette |
| Outputs fichier | `audit-report/*.md` (3 fichiers minimum) |
| Output inline | Bilan synthétique |

Mot-clé actif : `audit` (sans backticks). `dry-audit` = simulation sans écriture fichier.

Scope par défaut : **TOUS** les fichiers du dossier cible — aucun skip, aucun raccourci.

Contrainte batch : ≤3 fichiers par cycle Read→Write. Au-delà, sub-agents (Agent tool).

---

## Séquence obligatoire (par bloc structurel)

1. Read fichiers du bloc N (≤3 par cycle)
2. Analyser : conformité, méthodes, procédures, liens inter-fichiers
3. Auditer : bugs, patterns, dette technique, sécurité, références cassées, erreurs triviales
4. **Écrire** les findings dans le rapport du bloc (append) — AVANT de Read le bloc N+1
5. Proposer corrections si applicable

Le rapport est incrémental : chaque Write est un checkpoint. Si la session coupe, le rapport partiel est exploitable.

---

## Progress tracker

À chaque checkpoint, écrire dans `audit-report/_progress.md` la liste des fichiers traités et restants. Avant chaque Read, vérifier dans `_progress.md` s'il est déjà traité — si oui, skip.

---

## Points d'analyse par fichier

1. Conformité (headers, conventions, style)
2. Méthodes et procédures implémentées
3. Liens et dépendances inter-fichiers
4. Bugs et erreurs triviales
5. Patterns et anti-patterns
6. Dette technique
7. Sécurité (injections, permissions, secrets)
8. Références cassées (imports, paths, variables)

---

## Outputs

Les trois outputs sont toujours produits (si un seul est demandé, c'est un `analyse`, pas un `audit`) :

1. **rapport détaillé** — un fichier `.md` par bloc structurel (ex : `01-core-audit.md`, `02-ipc-helpers-audit.md`…), analyse exhaustive sur les 8 points → sauvé dans `audit-report/NN-<bloc>-audit.md`
2. **rapport dérives** — consolidation de TOUTES les dérives, références cassées, erreurs triviales → sauvé dans `audit-report/dérives.md`
3. **bilan synthétique** — résumé, métriques (fichiers lus, dérives détectées, erreurs critiques vs mineures), conclusion ~5 lignes, score x/10 → sauvé dans `audit-report/bilan.md`

Affichage : le bilan synthétique est présenté en fin d'audit pour retour immédiat. Les rapports détaillés restent dans `audit-report/` — l'user consulte à la demande.
