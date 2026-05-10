---
name: ponce
description: >
  Analyse complete d'un repo externe : sonde (API) -> reverse (specs) -> audit (conformite).
  Enchaine /sonde, /reverse, /audit avec gate apres sonde.
allowed-tools:
  - Bash(gh:*)
  - Bash(jq:*)
  - Bash(git:*)
  - Bash(wc:*)
  - Bash(date:*)
  - Read
  - Write
  - Glob
  - Grep
  - Skill
when_to_use: >
  Use when the user says 'ponce' followed by a repo URL or name.
  Protocol keyword for full external repo analysis (reputation + architecture + audit).
  Chains /sonde, /reverse, /audit automatically with a gate after sonde.
  Examples: 'ponce https://github.com/org/repo', 'ponce org/repo'.
argument-hint: "<repo-url-or-owner/name>"
arguments:
  - repo_url
---
# Skill: ponce

**Date** : 2026-03-30
**Derniere revision** : 2026-03-30
**Statut** : active — architect, consultant, starfleet
**Reference par** : fleet/system-prompt/sources/user/protocole.md

Analyse complete d'un repo externe. Enchaine sonde, reverse et audit avec gate de credibilite.

---

## Inputs
- `$repo_url`: URL GitHub ou format `owner/repo`

---

## Goal
Consommer a fond un repo externe : reputation, architecture, conformite. Produire le triptyque complet de rapports (brief + specs + architecture + audit-report/).

---

## Steps

### 1. Sonde (API, zero clone)
Invoke `/sonde $repo_url`.

Le skill sonde collecte les metriques GitHub via API, calcule un score /100, produit le brief et affiche le verdict inline.

**Success criteria** : brief ecrit, score et verdict affiches.

### 2. Gate de credibilite
Evaluer le verdict de la sonde :

- **Score 70+** (sain) : continuer automatiquement vers le clone. Signaler "sonde OK, on continue".
- **Score 40-69** (litigieux) : afficher le resume des risques et demander a l'user "on continue ? le repo a des signaux faibles mais peut valoir le coup". Attendre confirmation.
- **Score <40** (toxique) : afficher le resume et recommander l'arret. Demander confirmation quand meme — un repo peut etre precieux malgre des metriques mortes (ex: LCARS lui-meme).

**Important** : la gate ne bloque jamais. L'user decide toujours.

**Success criteria** : decision continue/stop prise (par l'agent ou par l'user selon le score).

### 3. Clone
Si gate passee :
```bash
git clone --depth 50 "https://github.com/$OWNER_REPO.git" "/tmp/$REPO_NAME"
```
Clone shallow dans /tmp/ (jetable). Profondeur 50 commits suffit pour l'analyse.

**Success criteria** : repo clone dans /tmp/.

### 4. Reverse (specs + architecture)
Invoke `/reverse /tmp/$REPO_NAME`.

Produit `<repo>-specs.md` + `<repo>-architecture.md`.

**Success criteria** : les deux fichiers reverse ecrits.

### 5. Audit (conformite + dette)
Invoke `/audit /tmp/$REPO_NAME`.

Produit `audit-report/` (rapports detailles + derives + bilan).

**Success criteria** : audit-report/ complet avec bilan.

### 6. Bilan ponce
Afficher un resume inline :
- Score sonde /100
- Resume architecture (1-2 lignes du reverse)
- Score audit x/10
- Verdict final : "repo exploitable" / "a eviter" / "a surveiller"

**Success criteria** : bilan inline affiche.

---

## Rules
- L'ordre est strict : sonde → gate → clone → reverse → audit. Pas de shortcut.
- Le clone est le point de non-retour couteux. Tout avant = gratuit (API).
- Si l'user dit stop a la gate, on s'arrete au brief sonde. Pas de clone, pas de reverse, pas d'audit.
- Les rapports de chaque phase sont des checkpoints. Si la session coupe, les rapports partiels sont exploitables.
- `dry-ponce` = simulation : execute sonde + affiche ce que reverse et audit feraient, sans cloner.
