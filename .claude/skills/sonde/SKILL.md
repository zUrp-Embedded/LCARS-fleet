---
name: sonde
description: >
  Brief rapide de credibilite d'un repo externe via API GitHub.
  Zero clone. Produit <repo>-brief.md + verdict go/nope.
allowed-tools:
  - Bash(gh:*)
  - Bash(jq:*)
  - Bash(date:*)
  - Write
when_to_use: >
  Use when the user says 'sonde' followed by a repo URL or name.
  Protocol keyword for quick repo credibility check via GitHub API.
  No clone, no code reading — API metrics only.
  Examples: 'sonde https://github.com/org/repo', 'sonde org/repo'.
argument-hint: "<repo-url-or-owner/name>"
arguments:
  - repo_url
---
# Skill: sonde

**Date** : 2026-03-30
**Derniere revision** : 2026-03-30
**Statut** : active — architect, consultant, starfleet
**Reference par** : fleet/system-prompt/sources/user/protocole.md

Brief de credibilite d'un repo externe. API GitHub uniquement, zero clone, zero lecture de code.

---

## Inputs
- `$repo_url`: URL GitHub ou format `owner/repo`

---

## Goal
Verdict rapide sur la credibilite et la pertinence d'un repo externe. Produire un brief fichier + verdict inline.

---

## Steps

### 1. Normaliser l'URL
Extraire `owner/repo` depuis l'URL fournie. Accepter les formats :
- `https://github.com/owner/repo`
- `owner/repo`
- `https://github.com/owner/repo.git`

**Success criteria** : variable `OWNER_REPO` definie au format `owner/repo`.

### 2. Collecter les metriques via gh API
Executer en un seul bloc Bash :

```bash
# Repo metadata
gh api "repos/$OWNER_REPO" --jq '{
  name: .name,
  full_name: .full_name,
  description: .description,
  created_at: .created_at,
  updated_at: .updated_at,
  pushed_at: .pushed_at,
  stars: .stargazers_count,
  forks: .forks_count,
  open_issues: .open_issues_count,
  license: (.license.spdx_id // "none"),
  language: .language,
  archived: .archived,
  default_branch: .default_branch,
  topics: .topics
}'

# Contributors count
gh api "repos/$OWNER_REPO/contributors?per_page=1&anon=true" --jq 'length'

# Recent commits (last 30 days)
gh api "repos/$OWNER_REPO/commits?since=$(date -u -d '30 days ago' +%Y-%m-%dT%H:%M:%SZ)&per_page=1" --jq 'length'

# Open PRs
gh api "repos/$OWNER_REPO/pulls?state=open&per_page=1" --jq 'length'

# Last closed issue response time (sample)
gh api "repos/$OWNER_REPO/issues?state=closed&per_page=3&sort=updated" --jq '.[].closed_at'
```

**Success criteria** : JSON metadata + contributor count + activity indicators collected.

### 3. Lire le README via API
```bash
gh api "repos/$OWNER_REPO/readme" --jq '.content' | base64 -d | head -100
```
Pas de clone. Le README suffit pour comprendre le positionnement.

**Success criteria** : README content disponible (ou absent note).

### 4. Calculer le score de reputation
Evaluer sur 10 criteres (0-10 chacun, total /100) :

1. Anciennete du repo (>2 ans = 10, <3 mois = 2)
2. Derniere activite (<1 mois = 10, >1 an = 1)
3. Stars (>1k = 10, >100 = 7, >10 = 4, <10 = 2)
4. Forks (>100 = 10, >10 = 6, <10 = 3)
5. Commits recents (actif = 10, mort = 1)
6. PRs ouvertes (sain = gere, malsain = accumulation)
7. Reactivite issues (rapide = 10, pas de reponse = 2)
8. Contributors (>5 = 10, solo = 4)
9. License (MIT/Apache/GPL = 10, none = 3)
10. README qualite (clair + exemples = 10, absent = 1)

Score brut /100 → verdict :
- 70+ : sain, continuer
- 40-69 : litigieux, signaler les risques
- <40 : toxique, recommander stop (sans bloquer)

**Success criteria** : score calcule + verdict formule.

### 5. Ecrire le brief
Sauver dans `<repo>-brief.md` :
- Metriques brutes (tableau)
- Score /100 + detail par critere
- Verdict : go / litigieux / nope
- Pertinence par rapport au contexte courant (si connu)

Afficher inline le verdict condense.

**Success criteria** : fichier brief ecrit + verdict inline affiche.

---

## Rules
- ZERO clone. Tout passe par `gh api`.
- ZERO lecture de code source. Le README via API est la seule lecture.
- Le brief est le seul output fichier. Pas d'insight (c'est le job de reverse).
- Score honnete : LCARS aurait 15/100 en metriques pures. Le score mesure la sante communautaire, pas la qualite intrinseque.
