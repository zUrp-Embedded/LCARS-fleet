---
name: new-project
description: >
  Interactive project bootstrapper. Scaffolds full directory structure,
  README, LICENSE, git hooks, GitHub repo. Integrated with LCARS fleet workflow.
allowed-tools:
  - Bash
  - Read
  - Write
  - Edit
  - Glob
when_to_use: >
  Use when the user wants to create a new project from scratch.
  Examples: '/new-project', 'create a new project', 'start a project',
  'bootstrap project', 'nouveau projet'.
---
# Skill: /new-project

**Date** : 2026-03-18
**Dernière révision** : 2026-03-18
**Statut** : active
**Référencé par** : —
**Dérivé de** : —

Crée un projet complet en une passe : structure, README, LICENSE, git, GitHub, ready-room, dispatch.
Zéro manipulation manuelle après confirmation.

---

## Step 1 — Collecte interactive

Poser les questions suivantes **une par une** via AskUserQuestion. Stocker les réponses.

**Q1 — Slug** (identifiant technique, kebab-case) :
> "Slug du projet ? (kebab-case, ex: arduino-morse, my-lib-v2)"

Validation immédiate : `^[a-z0-9][a-z0-9-]*[a-z0-9]$` (minimum 2 caractères, pas de tiret en début/fin).
Si invalide : reformuler l'erreur en une ligne + re-poser Q1.

**Q2 — Titre** (nom lisible) :
> "Titre du projet ? (ex: Arduino Morse, My Library v2)"

**Q3 — Pitch** (1-3 phrases, description fonctionnelle) :
> "Pitch du projet ? (ce que ça fait, pour qui, pourquoi)"

**Q4 — Type** (détermine la structure src/) :
> "Type ? firmware / host-app / lib / script / webapp / autre"

Réponse normalisée en lowercase. Si valeur hors liste : re-poser.

**Q5 — Stack technique** :
> "Stack technique ? (langages, frameworks, contraintes — ex: C/Arduino, WinAPI C MinGW, Python 3.11)"

**Q6 — Livrables attendus** :
> "Livrables ? (ex: .exe portable, .hex firmware, .whl, rapport PDF — séparer par virgule)"

**Q7 — Licence** :
> "Licence ? (AGPL-3 / MIT / Apache-2 / GPL-3 / none)"

Valeurs acceptées : `AGPL-3`, `MIT`, `Apache-2`, `GPL-3`, `none`. Défaut si vide : `MIT`.

**Q8 — GitHub** :
> "Créer un repo GitHub ? (oui / non / public / private) — 'oui' = public par défaut"

Valeurs acceptées : `oui`, `non`, `public`, `private`. `oui` → `public`.

**Q9 — Agents requis** :
> "Agents nécessaires ? (ex: dev, qualifier, reviewer — ou 'standard' pour dev+qualifier)"

`standard` → `dev qualifier`. Sinon : liste normalisée, séparée par espaces.

---

## Step 2 — Idempotence + confirmation

Vérifier que le projet n'existe pas déjà :

```bash
PROJECT_ROOT="/home/projects/$SLUG"
[ -d "$PROJECT_ROOT" ] && echo "STOP : $PROJECT_ROOT existe déjà." && exit 1
```

Afficher le récapitulatif :

```
=== new-project ===
Slug        : <slug>
Titre       : <titre>
Type        : <type>
Stack       : <stack>
Licence     : <licence>
GitHub      : <public|private|non>
Agents      : <agents>
Racine      : /home/projects/<slug>/
================
```

Attendre `go` ou `nope`.

---

## Step 3 — Création structure

### 3a — Répertoires

```bash
mkdir -p "$PROJECT_ROOT"/{docs,work/TODO,work/doing,work/done}
```

Structure src/ par type :

| Type | Répertoires |
|---|---|
| firmware | `src/{core,hal,drivers,config}` |
| host-app | `src/{host,tests}` |
| lib | `src/{include,lib,tests}` |
| script | `src` |
| webapp | `src/{frontend,backend,api}` |
| autre | `src` |

### 3b — README.md

```markdown
# <TITRE>

<PITCH>

## Installation

(à compléter)

## Usage

(à compléter)

## Stack

<STACK>

## Livrables

<LIVRABLES — liste markdown>

## Licence

<LICENCE_NAME> — voir [LICENSE](LICENSE).
```

### 3c — LICENSE

Générer le fichier LICENSE complet correspondant à Q7.
Utiliser les textes canoniques (SPDX). Remplir le champ copyright :

```
Copyright (c) <YYYY> <GIT_USER_NAME from git config>
```

Si `none` → pas de fichier LICENSE. Ajouter un commentaire dans README : `Tous droits réservés.`

### 3d — .editorconfig

```ini
root = true

[*]
charset = utf-8
end_of_line = lf
insert_final_newline = true
indent_style = space
indent_size = 4
trim_trailing_whitespace = true
```

### 3e — .gitignore (type-aware)

| Type | Contenu |
|---|---|
| firmware | `build/ *.hex *.elf *.map *.d *.o work/` |
| host-app | `build/ *.exe *.o *.obj *.pdb work/` |
| lib | `build/ dist/ *.egg-info/ __pycache__/ *.so *.a work/` |
| script | `__pycache__/ *.pyc .env work/` |
| webapp | `node_modules/ dist/ .env .env.local work/` |
| autre | `build/ work/` |

### 3f — docs/

**`docs/spec.md`** :

```markdown
# <TITRE> — Spec

**Date** : <YYYY-MM-DD>
**Dernière révision** : <YYYY-MM-DD>
**Statut** : draft v1
**Référencé par** : work/doing/<SLUG>-lead.md
**Dérivé de** : —

## Pitch

<PITCH>

## Stack

<STACK>

## Livrables

<LIVRABLES>

## Contraintes

(à compléter)

## Structure fichiers

(auto-générée — voir arborescence src/)
```

**`docs/#11_bug-journal.md`** :

```markdown
# <TITRE> — Bug Journal

**Date** : <YYYY-MM-DD>
**Dernière révision** : <YYYY-MM-DD>
**Statut** : actif
**Référencé par** : —
**Dérivé de** : —

<!-- Entrée format : ## YYYY-MM-DD — <titre bug> · <fixé par> -->
```

### 3g — work/

**`work/doing/<SLUG>-lead.md`** :

```markdown
# <TITRE> — Plan

**Date** : <YYYY-MM-DD>
**Dernière révision** : <YYYY-MM-DD>
**Statut** : draft v1
**Référencé par** : —
**Dérivé de** : docs/spec.md

## Spec

`docs/spec.md` — lire en premier.

## Phases

(à compléter par Engineer après dispatch)

## Ordre d'exécution

(à compléter)
```

**`work/backlog.md`** :

```markdown
# <TITRE> — Backlog

**Date** : <YYYY-MM-DD>
**Dernière révision** : <YYYY-MM-DD>
**Statut** : actif
**Référencé par** : —
**Dérivé de** : —

## Todo

- [ ] Phase 1 (voir lead.md)

## Done

(vide)
```

**`work/scratchpad.md`** — fichier vide (append-only par convention).

**Bootstrap index** — après création de tous les fichiers work/ :
```bash
cd "$PROJECT_ROOT" && fleet-scrub.sh init
```

---

## Step 4 — Git + GitHub

### 4a — Init + hooks

```bash
cd "$PROJECT_ROOT"
git init
git branch -m main
```

Installer les fleet git hooks :
```bash
bash /local/LCARS/fleet/git-hooks/install-hooks.sh --repo "$PROJECT_ROOT"
```

### 4b — Ownership

```bash
WORKER=$(yq '.instances[] | select(.scope == "code") | .role' /local/LCARS/fleet/fleet.yaml 2>/dev/null | head -1)
: "${WORKER:=dev}"
sudo chown -R "$WORKER":fleet "$PROJECT_ROOT"
sudo chmod -R 775 "$PROJECT_ROOT"
```

### 4c — Premier commit

```bash
sudo -u "$WORKER" git -C "$PROJECT_ROOT" add .
sudo -u "$WORKER" git -C "$PROJECT_ROOT" commit -m "chore: init project $SLUG"
```

### 4d — GitHub

Si Q8 != `non` et `gh` disponible + authentifié :

```bash
GH_ORG=$(yq '.fleet.github.org' /local/LCARS/fleet/fleet.yaml 2>/dev/null)
if [[ "$GH_ORG" != "null" && -n "$GH_ORG" ]]; then
    GH_OWNER="$GH_ORG"
else
    REPO_URL=$(yq '.fleet.repo' /local/LCARS/fleet/fleet.yaml 2>/dev/null)
    GH_OWNER=$(echo "$REPO_URL" | cut -d/ -f1)
fi
VISIBILITY="public"  # ou private selon Q8
gh repo create "$GH_OWNER/$SLUG" \
    --"$VISIBILITY" \
    --description "<PITCH tronqué à 100 chars>" \
    --source "$PROJECT_ROOT" \
    --remote origin \
    --push
```

Si `gh` absent ou erreur : afficher instructions manuelles, ne pas bloquer.

---

## Step 5 — Ready-room

```bash
mkdir -p "/home/ready-room/projects/$SLUG"
```

---

## Step 6 — Dispatch Engineer

```bash
fleet-send.sh engineer "NEW-PROJECT $SLUG" <<EOF
slug: $SLUG
title: $TITRE
plan: work/doing/$SLUG-lead.md
spec: docs/spec.md
root: $PROJECT_ROOT
agents: $AGENTS
---
Nouveau projet bootstrappé. Lire spec.md puis compléter le lead.md avec les phases.
EOF
```

Output final :

```
=== new-project terminé ===
Projet     : <SLUG>
Racine     : /home/projects/<SLUG>/
GitHub     : <URL ou "non créé">
Licence    : <LICENCE>
Hooks      : installés (pre-commit, post-commit, pre-push)
Engineer   : notifié
===========================
```

---

## Notes

- `work/` est gitignored — non versionné, non poussé.
- Tous les fichiers ont les GO-7 headers corrects dès la création.
- Git hooks installés dès le premier commit — STARDATE et GO-7 actifs immédiatement.
- Ownership transférée au worker (dev) — dev code sans sudo.
- GitHub : si `gh repo create` échoue, afficher l'erreur + instructions. Ne pas bloquer.
