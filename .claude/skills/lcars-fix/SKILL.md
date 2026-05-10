---
name: lcars-fix
description: >
  Quick-fix workflow for LCARS modifications by StarFleet.
  Boundary based on risk (cross-agent behavior, topology) not file count.
  Single OK gate, fully automatic thereafter. Replaces /lcars-patch.
allowed-tools:
  - Bash(git:*)
  - Bash(gh:*)
  - Bash(fleet-update.sh:*)
  - Bash(fleet-send.sh:*)
  - Bash(shellcheck:*)
  - Bash(tests/.bats:*)
  - Read
  - Write
  - Edit
  - Glob
  - Grep
when_to_use: >
  Use for LCARS modifications within the quick-fix boundary (no cross-agent
  behavior change, no topology change, no file deletions).
  Examples: '/lcars-fix', '/lcars-patch', 'quick fix on LCARS', 'patch this script'.
---
# Skill: /lcars-fix

**Date** : 2026-03-18
**Dernière révision** : 2026-04-18
**Statut** : active — starfleet only
**Référencé par** : fleet/system-prompt/sources/organisation/workflow.md
**Dérivé de** : —

Workflow obligatoire pour toute modification LCARS par StarFleet.
Séquence : check + propose → user OK → tout le reste est automatique.

Alias actif : `/lcars-patch` redirige vers ce skill.

---

## Boundary — critère de risque

| Critère | Quick-fix ✓ | Feature → /lcars-feature |
|---|---|---|
| Fichiers existants modifiés | ≤ 8 | > 8 |
| Fichiers créés | ≤ 2 | > 2 |
| Fichiers supprimés | 0 | ≥ 1 |
| Topologie (Tiers, IPC, matrice K×T) | inchangée | modifiée |
| Comportement cross-agent (IPC format, spool paths, wake protocol) | inchangé | modifié |

Header-only (GO-7, STARDATE, version tag) : exempt du comptage.

Si boundary dépassé :
```
Ce changement dépasse le quick-fix boundary ([critère violé]).
→ /lcars-feature requis.
```

---

## Step 1 — Check + Propose

```bash
FLEET_REPO="/home/projects/LCARS"
git -C "$FLEET_REPO" status --short
git -C "$FLEET_REPO" branch --show-current   # doit être main
```

Résumé comportemental par fichier modifié/créé — pas de verbatim. `diff ?` pour le détail.

```
=== Proposed fix ===

[1] fleet/fichier.sh
    Ce qui change en termes de comportement (1-2 lignes)

Fichiers : N modifiés + M créé(s) | Boundary OK
```

Attendre `ok`, `go`, ou `GO`.

---

## Step 2 — Branche

```bash
FLEET_REPO="/home/projects/LCARS"
BRANCH="fix/lcars-$(date +%Y%m%d-%H%M)"
git -C "$FLEET_REPO" checkout -b "$BRANCH"
```

---

## Step 3 — Apply

StarFleet opère directement dans le clone (owned starfleet depuis provision-system.sh 8b).
**Pas de cp/tmp.** Edit tool écrit directement dans `/home/projects/LCARS/`.

---

## Step 4 — QA

Checklist par fichier modifié :

1. GO-7 header présent et à jour (STARDATE = aujourd'hui)
2. Cohérence inter-directives
3. Références non cassées
4. Correctness vs Step 1
5. `bash -n` si script shell

```
=== QA ===
[OK/FAIL] GO-7 headers
[OK/FAIL] Cohérence inter-directives
[OK/FAIL] Références
[OK/FAIL] Correctness du patch
[OK/N/A] Syntax check (scripts uniquement)
```

FAIL → corriger, re-QA (boucle autonome). Boundary cassé → escalade user.

QA PASS → Step 5 immédiat.

---

## Step 5 — Commit + Push + PR + Auto-merge + Deploy

Automatique — aucun gate humain.

```bash
FLEET_REPO="/home/projects/LCARS"
REPO=$(yq '.fleet.repo' /local/LCARS/fleet/fleet.yaml 2>/dev/null)

# Commit (starfleet identity depuis ~/.gitconfig)
git -C "$FLEET_REPO" add <fichiers>
git -C "$FLEET_REPO" commit -m "<description>"

# Push + PR + auto-merge
git -C "$FLEET_REPO" push -u origin "$BRANCH"
PR_URL=$(gh pr create --repo "$REPO" --base main --head "$BRANCH" \
    --title "<description>" \
    --body "$(cat <<'PRBODY'
## Metadata
type: plomberie
scope: fleet/*.sh
files_modified: N
files_created: M
lines_changed: +X -Y

## Changes
<résumé comportemental par fichier>

---
Quick-fix LCARS — StarFleet via /lcars-fix
PRBODY
)")
PR_NUM=$(echo "$PR_URL" | grep -oE '[0-9]+$')
gh pr merge "$PR_NUM" --repo "$REPO" --merge

# Runtime frozen v2 bootstrap — fleet-update INTERDIT
# Le runtime /local/LCARS/ est sacré pendant la forge v2. Aucune
# propagation vers le runtime. Le merge sur main NE déclenche PAS
# de fleet-update. Si fleet-update.sh est invoqué, échec attendu
# (rename en fleet-update.sh-NE_PAS_UTILISER + chmod -x).
echo "[lcars-fix] fleet-update SKIPPED — runtime frozen pendant forge v2"

git -C "$FLEET_REPO" checkout main
git -C "$FLEET_REPO" pull
```

Output :
```
PR #<num> merged. Déployé : <ancien> → <nouveau>.
```

---

## Notes

- Seul chemin autorisé pour modifier LCARS en tant que StarFleet (GO-0)
- Commits signés `StarFleet` dans le git log — `/lcars-feature` signe `dev`
- `gh pr create` utilise le token lordzurp — PR creator = lordzurp (normal, c'est son repo)
- Auto-merge quick-fix uniquement. Features → merge gate /lcars-feature.
- Rollback : `git -C /home/projects/LCARS revert <hash>` puis re-push + PR
