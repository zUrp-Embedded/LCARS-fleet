---
name: adopt-project
description: >
  Integrates an existing project into the LCARS fleet workflow.
  Adds missing structure (docs/, work/, hooks, LICENSE), fixes permissions,
  provisions ready-room, and dispatches to Engineer.
allowed-tools:
  - Bash(git:*)
  - Bash(mkdir:*)
  - Bash(chmod:*)
  - Bash(chown:*)
  - Bash(sudo:*)
  - Bash(fleet-send.sh:*)
  - Bash(fleet-scrub.sh:*)
  - Bash(install-hooks.sh:*)
  - Bash(stat:*)
  - Bash(ls:*)
  - Bash(yq:*)
  - Read
  - Write
  - Edit
  - Glob
  - Grep
when_to_use: >
  Use when the user wants to integrate an existing project into LCARS fleet.
  Examples: 'adopt this project', 'integrate into fleet', 'add project to LCARS',
  'adopt-project /home/projects/my-app'.
argument-hint: "/path/to/project"
arguments:
  - project_path
---
# Skill: /adopt-project

**Date** : 2026-03-18
**Dernière révision** : 2026-03-18
**Statut** : active
**Référencé par** : —
**Dérivé de** : .claude/skills/new-project/SKILL.md

Intègre un projet existant dans le workflow LCARS.
Analyse ce qui existe, ajoute ce qui manque, ne casse rien.

---

## Step 1 — Identification

**Q1 — Path** :
> "Path du projet ? (ex: /home/projects/arduino-morse)"

Validation : le path doit exister et contenir un `.git/`.
Si pas de `.git/` : "Ce répertoire n'est pas un repo git. Initialiser d'abord avec `git init`."

**Q2 — Licence** (si absente) :
> "Licence ? (AGPL-3 / MIT / Apache-2 / GPL-3 / none / garder l'existante)"

Posée uniquement si aucun fichier LICENSE/LICENSE.md/COPYING n'existe.

---

## Step 2 — Diagnostic

Scanner le projet et produire un rapport binaire :

```bash
PROJECT_ROOT="<path>"
SLUG=$(basename "$PROJECT_ROOT")
```

| Check | Commande | Résultat |
|---|---|---|
| git init | `[ -d .git ]` | OK / FAIL |
| docs/ | `[ -d docs ]` | OK / absent |
| docs/spec.md | `[ -f docs/spec.md ]` | OK / absent |
| docs/#11_bug-journal.md | `[ -f "docs/#11_bug-journal.md" ]` | OK / absent |
| work/ | `[ -d work ]` | OK / absent |
| work/doing/ | `[ -d work/doing ]` | OK / absent |
| work/backlog.md | `[ -f work/backlog.md ]` | OK / absent |
| work/scratchpad.md | `[ -f work/scratchpad.md ]` | OK / absent |
| .gitignore | `[ -f .gitignore ]` | OK / absent |
| .editorconfig | `[ -f .editorconfig ]` | OK / absent |
| LICENSE | `ls LICENSE* COPYING* 2>/dev/null` | OK / absent |
| README.md | `[ -f README.md ]` | OK / incomplet / absent |
| Git hooks | `[ -f .git/hooks/pre-commit ]` | OK / absent |
| Ownership | `stat -c '%U' .` | OK / mauvais |
| Ready-room | `[ -d /home/ready-room/projects/$SLUG ]` | OK / absent |

Afficher le diagnostic :

```
=== adopt-project diagnostic ===
Projet : <SLUG> (<path>)

[OK]   git repo
[+]    docs/ — à créer
[OK]   README.md
[+]    LICENSE — à créer (MIT)
[+]    .editorconfig — à créer
[OK]   .gitignore
[+]    work/ — à créer
[+]    git hooks — à installer
[+]    ownership — chown dev:fleet
[+]    ready-room — à provisionner

Actions : 7 ajouts, 0 modifications
================================
```

`[OK]` = existe et conforme. `[+]` = à ajouter. `[~]` = existe mais incomplet.

Attendre `go` ou `nope`.

**Success criteria** : diagnostic affiche, chaque check OK/+/~ visible, nombre d'actions annonce.

---

## Step 3 — Complétion

Pour chaque `[+]` ou `[~]` du diagnostic, appliquer la correction. Ne jamais modifier un fichier existant sauf si explicitement `[~]`.

### 3a — docs/

Si absent : `mkdir -p docs`

**`docs/spec.md`** — si absent, générer depuis le README existant ou demander :
```markdown
# <TITRE> — Spec

**Date** : <YYYY-MM-DD>
**Dernière révision** : <YYYY-MM-DD>
**Statut** : adopté — spec initiale
**Référencé par** : —
**Dérivé de** : README.md

## Pitch

<extrait du README ou demander à l'user>

## Stack

<détecté depuis les fichiers : .c → C, .py → Python, package.json → Node, etc.>

## Structure existante

<arborescence ls -R src/ ou racine>
```

**`docs/#11_bug-journal.md`** — si absent, créer le template standard (même que /new-project).

### 3b — work/

Si absent : `mkdir -p work/TODO work/doing work/done`

**`work/backlog.md`** — si absent, créer le template standard.
**`work/scratchpad.md`** — si absent, créer vide.

**Bootstrap index** — après création de tous les fichiers work/ :
```bash
cd "$PROJECT_ROOT" && fleet-scrub.sh init
```

### 3c — .editorconfig

Si absent, créer le template standard (même que /new-project).

### 3d — LICENSE

Si absent et Q2 != `none` et Q2 != `garder` : générer le fichier LICENSE.
Copyright : `<YYYY> <git config user.name>`.

### 3e — .gitignore — compléter

Si `.gitignore` existe : vérifier que `work/` est ignoré. Si non, ajouter `work/` à la fin.
Si `.gitignore` absent : créer avec au minimum `work/`.

### 3f — README.md — compléter si incomplet

Si README existe mais n'a pas de section License : ajouter en fin.
Ne pas toucher le reste — le contenu existant est la source de vérité.

Si README absent : créer un squelette minimal (titre + "à compléter").

### 3g — Git hooks

```bash
bash /local/LCARS/fleet/git-hooks/install-hooks.sh --repo "$PROJECT_ROOT"
```

### 3h — Ownership

```bash
WORKER=$(yq '.instances[] | select(.scope == "code") | .role' /local/LCARS/fleet/fleet.yaml 2>/dev/null | head -1)
: "${WORKER:=dev}"
sudo chown -R "$WORKER":fleet "$PROJECT_ROOT"
sudo chmod -R 775 "$PROJECT_ROOT"
```

### 3i — Ready-room

```bash
mkdir -p "/home/ready-room/projects/$SLUG"
```

---

## Step 4 — Commit des ajouts

```bash
WORKER=$(yq '.instances[] | select(.scope == "code") | .role' /local/LCARS/fleet/fleet.yaml 2>/dev/null | head -1)
: "${WORKER:=dev}"
sudo -u "$WORKER" git -C "$PROJECT_ROOT" add docs/ .editorconfig LICENSE .gitignore
sudo -u "$WORKER" git -C "$PROJECT_ROOT" commit -m "chore: adopt into LCARS fleet (docs, hooks, license)" 2>/dev/null || true
```

Ne commiter que les fichiers AJOUTÉS. Ne pas toucher aux fichiers existants dans le commit.

**Success criteria** : commit reussi, uniquement fichiers ajoutes dans le diff.

---

## Step 5 — Dispatch Engineer

```bash
fleet-send.sh engineer "PROJECT-ADOPTED $SLUG" <<EOF
slug: $SLUG
root: $PROJECT_ROOT
spec: docs/spec.md
---
Projet existant adopté dans LCARS. Structure complétée.
Lire spec.md (généré depuis le README existant) et compléter si nécessaire.
EOF
```

**Success criteria** : message envoye dans le spool engineer, output final affiche.

Output final :

```
=== adopt-project terminé ===
Projet     : <SLUG>
Racine     : <PROJECT_ROOT>
Ajoutés    : <liste des fichiers/dirs créés>
Hooks      : installés
Ownership  : <WORKER>:fleet
Ready-room : provisionné
Engineer   : notifié
=============================
```

---

## Notes

- Ne modifie JAMAIS les fichiers source existants (src/, code, configs projet).
- Ne modifie le README que pour ajouter une section License si absente.
- Ne modifie le .gitignore que pour ajouter `work/` si absent.
- La spec.md est générée par inférence depuis le README + détection stack. L'user peut la corriger après.
- Si le projet a déjà une structure docs/ ou work/, ne pas écraser — compléter uniquement les fichiers manquants.
- Git hooks : si des hooks existent déjà (non-fleet), ils sont backupés en `.bak` par install-hooks.sh.
