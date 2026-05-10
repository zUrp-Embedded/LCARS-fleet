# /handoff

**Date** : 2026-03-22
**Derniere revision** : 2026-03-31
**Statut** : actif — deploye vers tous les agents
**Reference par** : .claude/skills/handoff/SKILL.md

Generate or update the session handoff file for seamless continuation.

The handoff file lives in the worktree: `$FLEET_HANDOFFS/<instance>-handoff.md`.
Instance name : utiliser `$CLAUDE_AGENT_NAME` (priorité absolue — positionné par tmux/wake-instance.sh). Fallback : `cat ~/.claude/instance-name`.

Target file: `$FLEET_HANDOFFS/<instance>-handoff.md`

**Pour les mises à jour en cours de session (STATE, DONE, notify) — utiliser les shell hooks directement, sans appeler /handoff :**

```bash
fleet-state.sh action=build status=in-progress ref=abc123   # transition STATE
fleet-done.sh "titre" "corps"                                # entrée DONE courte
fleet-inject.sh done                                         # entrée DONE multiline (depuis /tmp/fleet-snippet-<instance>.md)
fleet-send.sh <dest> "sujet"                                 # message via spool inbox
```

**/handoff est réservé à la fin de session** — réécriture complète STATE+ACTIONS+DONE pour la continuité.

**Checklist session-hygiene — avant toute écriture handoff :**

```bash
git -C $(git rev-parse --show-toplevel 2>/dev/null) status --short 2>/dev/null | grep -E "^.M|^\?\?" || true
```
Vérifier :
- `git status` clean — aucun fichier modifié non-commité. Si sale : commiter ou expliquer pourquoi.
- bug-queue.md — aucun `[ ]` résolu sans entrée bug-journal correspondante.
- beads IN_PROGRESS — si une tâche est marquée IN_PROGRESS dans handoff ACTIONS, vérifier qu'elle a des acceptance criteria dans le DONE ou une note de blocage.
- context budget — noter le % fenêtre utilisé dans le DONE si >60%.

Séquence exacte — dans cet ordre :

```bash
fleet-state.sh action=shutdown status=in-progress        # 1. signaler fermeture en cours
# handoff-trim.sh SUPPRIMÉ — GO-3
```

**Avant le Read** — passe contexte obligatoire (GO-0 compliance) :
Parcourir le contexte de la session pour détecter :
- actions annoncées ("on fait X", "je vais X", "ensuite X") mais non exécutées
- fixes relevés ou corrigés mais non inscrits au backlog
- "TODO → backlog" dit verbalement sans écriture effective dans backlog.md
- items `note-bien:` acquittés oralement mais non persistés

Pour chaque item détecté : exécuter si coût trivial, sinon écrire dans backlog.md ou ACTIONS avant de continuer.

Ensuite, **Read** le fichier existant. Puis **Write** la réécriture complète STATE+ACTIONS+DONE.

⚠️ **Ne pas appeler fleet-state.sh entre le Read et le Write** — il modifie le fichier sur disque, ce qui invalide la lecture et fait échouer le Write. L'appel `shutdown` ci-dessus est AVANT le Read — pas de conflit.

**Si le Write échoue** (filesystem drvfs, lock, etc.) : utiliser fleet-inject.sh / fleet-done.sh pour écrire tout le contenu DONE, **puis** appeler fleet-state.sh offline en **dernière** étape. Ne jamais appeler fleet-state.sh offline avant que le contenu soit écrit.

---

## STATE  ← always overwrite, exactly 7 lines, key: value, no markdown
```
date: YYYY-MM-DD HH:MM    ← real timestamp only — never "session-start", "today", etc.
ref: <commit hash or branch>
action: code | build | deploy | validate | idle | handoff
status: pending | in-progress | blocked | done | offline
blocker: <short reason or "none">
waiting: <what this instance is waiting for, or "none">
notify: architect | <instance-name> | none
```

## ACTIONS  ← rolling list of what this instance must do
```
[ ] ACTION — context               ← pending
[x] ACTION — DONE YYYY-MM-DD      ← completed this session, kept 1 session then → DONE
```

## DONE  ← newest-first narrative, keep 5 entries max
```
### YYYY-MM-DD HH:MM — <short title>
What was done, why, key decisions, architectural choices.
For dev/build-*: new files, new deps, changed APIs.
```

---

### Convention session-end

Quand le handoff clôt une session (dernière action avant de fermer Claude) :
```
action: handoff
status: offline
```
Le dashboard affiche `— offline` (gris) — signal visuel que la session est terminée proprement.
À la reprise, la prochaine session remet `status` à `pending` ou `in-progress`.

**Garantie offline** : `fleet-state.sh action=handoff status=offline` est **toujours la dernière opération** — après Write (succès), ou après fleet-inject.sh (si Write échoue). `shutdown` est transitoire (début de séquence) ; `offline` est final (fin de séquence).

L'ordre complet est : `shutdown` (début) → Read → Write → `offline` (fin).
Handoffs are versioned in worktree (work/ops branch) — auto-committed by on-stop.sh.

### Mises à jour partielles via shell (zéro Read/Edit)

Préférer ces scripts pour toute mise à jour ne nécessitant pas de réécrire le fichier entier.
Sur engineer : `bash ~/fleet/<script>`. Sur les autres : `bash ~/.local/bin/<script>`.

**STATE — champs action/status/blocker/ref** (date auto) :
```bash
fleet-state.sh action=build status=in-progress ref=abc123
fleet-state.sh action=idle status=done
fleet-state.sh action=handoff status=blocked blocker="description courte"
```

**STATE — champs notify/waiting** :
```bash
fleet-state.sh notify=starfleet waiting="description"
fleet-state.sh notify=none waiting=none   # reset
```

**DONE — une ligne** (titre + corps court) :
```bash
fleet-done.sh "Titre court" "Corps optionnel sur une ligne"
```

**DONE — narratif multiline** (Write tool sur fichier vierge, zéro Read préalable) :
```
# Écrire dans /tmp/fleet-snippet-<instance>.md :
# ligne 1 = titre
# lignes 2+ = corps (multiline, libre)
```
```bash
fleet-inject.sh done                                        # propre handoff
```

**ACTIONS — ajouter des items** (Write [ ] dans snippet, puis inject) :
```bash
fleet-inject.sh actions                  # insère après ## ACTIONS
```

**ACTIONS — marquer [ ] comme [x]** :
```bash
fleet-action-done.sh              # première [ ] trouvée
fleet-action-done.sh "fragment"   # première [ ] contenant ce texte
```

**Bug queue — ajouter une entrée** :
```bash
fleet-bug.sh <source> <platform> "description [— ref contexte]"
fleet-bug.sh builder ARM64 "losetup -P échoue — builder-handoff.md"
```

### Rules

- `## STATE` : always overwritten (live state)
- `## ACTIONS` : `[x]` items from previous session move to `## DONE` at next handoff
- `## DONE` : append newest-first. If > 5 entries: copy oldest to `#9_archives/YYYYMMDD-<instance>.md`
- Keep total file under 120 lines
- Handoffs are auto-committed to work/ops by on-stop.sh. No manual commit needed.

### StarFleet — vérification backup

Si tu es starfleet, exécute `~/toolbox/check-backup.sh` avant d'écrire le handoff final.
En cas d'alerte (fichiers manquants), ajoute une note dans `## DONE`.

### Optional — Key files
Add a `## Key files` section if non-obvious files are needed to resume work:
```
## Key files
- `<path>` — one-line description
```
