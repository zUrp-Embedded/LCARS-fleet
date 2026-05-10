---
name: lcars-feature
description: >
  Feature workflow for LCARS modifications beyond quick-fix boundary.
  StarFleet provisions clone, dispatches directly to dev, merges at the end.
  No Engineer in the loop. No formal plan file required.
allowed-tools:
  - Bash(git:*)
  - Bash(gh:*)
  - Bash(fleet-dispatch.sh:*)
  - Bash(fleet-update.sh:*)
  - Bash(fleet-send.sh:*)
  - Bash(sudo:*)
  - Bash(chown:*)
  - Bash(yq:*)
  - Read
  - Write
  - Edit
  - Glob
  - Grep
when_to_use: >
  Use when LCARS modifications exceed the quick-fix boundary (cross-agent behavior
  changes, topology changes, file deletions). Examples: '/lcars-feature',
  'this needs a feature branch', 'beyond quick-fix scope'.
---
# Skill: /lcars-feature

**Date** : 2026-03-17
**Dernière révision** : 2026-04-18
**Statut** : active — starfleet only
**Référencé par** : fleet/system-prompt/sources/organisation/workflow.md
**Dérivé de** : —

Workflow pour les modifications LCARS dépassant le quick-fix boundary.
StarFleet provisionne le clone et tient le merge gate.
Dev implémente. Pas d'intermédiaire.

Complément de /lcars-fix (boundary dans conventions.md § Git/deploy).

---

## Preamble

```bash
FLEET_USER=$(yq '.fleet.identity.fleet_user' /local/LCARS/fleet/fleet.yaml 2>/dev/null)
REPO=$(yq '.fleet.repo' /local/LCARS/fleet/fleet.yaml 2>/dev/null)
WORKER=$(yq '.instances[] | select(.scope == "code") | .role' /local/LCARS/fleet/fleet.yaml 2>/dev/null | head -1)
: "${WORKER:=dev}"
echo "fleet_user: $FLEET_USER  repo: $REPO  worker: $WORKER"
SLUG="<slug>"
CLONE_PATH="/home/projects/lcars-$SLUG"
BRANCH="feature/lcars-$SLUG"
```

**Règle SLUG** : dérivé du sujet de la feature (kebab-case court).
Exemple : IPC wake robustness → `ipc-wake-robustness`.

---

## Step 1 — Résumé + confirmation user

Produire en 5 lignes max :
- Slug retenu
- Scope : fichiers cibles + comportement ajouté
- Pourquoi ça dépasse le quick-fix boundary

```
=== Proposed feature ===
slug     : <slug>
scope    : <N fichiers existants, M créés>
behavior : <ce qui change>
boundary : <critère dépassé>
```

Attendre `ok`, `go`, ou `GO`. **Pas de fichier plan requis.**

---

## Step 2 — Provisioning

Idempotence : vérifier que `$CLONE_PATH` n'existe pas avant de cloner.

```bash
if [ -d "$CLONE_PATH" ]; then
    echo "Clone $CLONE_PATH existe déjà — suppression manuelle requise avant provisioning."
    exit 1
fi

# Clone + branche
git clone /home/projects/LCARS "$CLONE_PATH"
git -C "$CLONE_PATH" checkout -b "$BRANCH"
git -C "$CLONE_PATH" remote set-url origin \
    "git@github.com:${REPO}.git"

# Ownership → worker
sudo chown -R "$WORKER":fleet "$CLONE_PATH"
sudo chmod -R 775 "$CLONE_PATH"

# Vérifier que /home/projects/LCARS/ est toujours sur main
git -C /home/projects/LCARS branch --show-current   # doit afficher main
```

---

## Step 3 — Dispatch vers dev

```bash
fleet-send.sh "$WORKER" "LCARS-FEATURE-READY" <<EOF
clone: $CLONE_PATH
branch: $BRANCH
slug: $SLUG
---
Clone LCARS feature prêt. Implémenter dans $CLONE_PATH sur $BRANCH.
Créer la PR avec ce format :

gh pr create --repo $REPO --base main --head $BRANCH \
    --title "feat: <description>" \
    --body "$(cat <<'PRBODY'
## Metadata
type: plomberie | directive | feature
scope: <fichiers principaux>
files_modified: N
files_created: M
lines_changed: +X -Y

## Changes
<résumé comportemental par fichier>

---
Feature LCARS — Dev via /lcars-feature
PRBODY
)"

Puis envoyer MERGE-REQUEST à starfleet :

fleet-send.sh starfleet "MERGE-REQUEST" <<BODY
pr_num: <PR_NUM>
slug: $SLUG
clone_path: $CLONE_PATH
branch: $BRANCH
BODY
EOF
```

**StarFleet s'arrête ici.** Dev implémente, commite, pousse, crée la PR, envoie MERGE-REQUEST.

---

## Step 4 — Merge gate

Déclenché par réception de `MERGE-REQUEST`.

**Extraction depuis le message :**
```bash
PR_NUM=$(grep '^pr_num:' "$MSG_FILE" | awk '{print $2}')
SLUG=$(grep '^slug:' "$MSG_FILE" | awk '{print $2}')
CLONE_PATH=$(grep '^clone_path:' "$MSG_FILE" | awk '{print $2}')
BRANCH=$(grep '^branch:' "$MSG_FILE" | awk '{print $2}')
REPO=$(yq '.fleet.repo' /local/LCARS/fleet/fleet.yaml 2>/dev/null)
```

**QA merge gate — dispatch reviewer (PAS qualifier) :**

LCARS = L4. Le validateur est `reviewer` (contexte L4), pas `qualifier` (contexte L1 projet).
Ne PAS utiliser de subagent inline — dispatcher via `fleet-dispatch.sh reviewer`.

Checklist reviewer :
1. GO-7 header présent et à jour dans tous les fichiers modifiés
2. Cohérence inter-directives
3. Références non cassées (imports, paths, variables)
4. Correctness vs résumé Step 1
5. `bash -n` pour tous les scripts shell modifiés

```
=== QA merge gate ===
[OK/FAIL] GO-7 headers
[OK/FAIL] Cohérence inter-directives
[OK/FAIL] Références
[OK/FAIL] Correctness vs scope
[OK/N/A] Syntax check (scripts uniquement)
```

QA FAIL → demander correction à dev avant merge.

**Merge — runtime frozen pendant forge v2 :**
```bash
gh pr merge "$PR_NUM" --repo "$REPO" --merge

# Runtime frozen v2 bootstrap — fleet-update INTERDIT
# Le runtime /local/LCARS/ est sacré pendant la forge v2. Aucune
# propagation vers le runtime. Le merge sur main NE déclenche PAS
# de fleet-update. Si fleet-update.sh est invoqué, échec attendu
# (rename en fleet-update.sh-NE_PAS_UTILISER + chmod -x).
echo "[lcars-feature] fleet-update SKIPPED — runtime frozen pendant forge v2"

git -C /home/projects/LCARS pull
```

---

## Step 5 — Cleanup

```bash
sudo rm -rf "$CLONE_PATH"
echo "clone $CLONE_PATH supprimé"
git -C /home/projects/LCARS branch --show-current   # doit afficher main
```

---

## Rollback

Runtime frozen v2 bootstrap — pas de fleet-update, donc pas de rollback
runtime à gérer. Si le merge lui-même pose problème :
1. `git -C /home/projects/LCARS log --oneline -3` — identifier le commit
2. Notifier l'user avec le hash et l'erreur
3. Attendre instruction avant tout `git revert`

---

## Notes

- /lcars-fix pour quick-fix (boundary dans conventions.md). /lcars-feature pour tout ce qui dépasse.
- StarFleet = merge gate. Dev = implémentation. Engineer n'est pas dans la boucle LCARS.
- Clone owned par le worker (chown après clone) — dev code sans sudo.
- `/home/projects/LCARS/` JAMAIS modifié — lecture seule pour le clone initial.
- Multi-PR (feature découpée en groupes) : après chaque merge, relancer à Step 3 avec le slug existant.
- Si dev ne répond pas : l'user le voit dans le contexte de session et agit.
