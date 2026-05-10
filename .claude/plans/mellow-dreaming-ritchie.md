# Plan — Auto-wake directionnels + simplification Haiku builders

_architect — 2026-03-03_

## Contexte

**Problème observé (2 occurrences)** : un builder (Haiku) écrit la réponse dans le fichier
directionnel (`build-arm-to-dev.md`) mais oublie d'appeler `fleet-notify.sh` — dev n'est
jamais réveillé. Root cause : Haiku doit faire 2 opérations cohérentes sur 2 fichiers
distincts en fin de session, moment où son contexte est le plus contraint.

**Décision** : traiter le problème à deux niveaux.
1. **Infrastructure** : fleet-monitor détecte automatiquement les nouvelles entrées DONE dans
   les directionnels et réveille le destinataire. Plus besoin de fleet-notify.sh côté builder.
2. **Modèle** : directives builder radicalement allégées pour Haiku + une seule commande
   atomique pour le chemin succès (comme fleet-blocker.sh pour le chemin échec).

---

## Phase 1 — Auto-wake via fleet-monitor (core fix)

### 1a — fleet-hub.py : add done_count

**Fichier** : `fleet/fleet-hub.py`

Dans `parse_state()`, après le bloc ACTIONS, ajouter le comptage des entrées `### ` dans
## DONE. Retourner `done_count` dans le dict résultat.

```python
# Compter les entrées complétées dans ## DONE
done_count = 0
dm = re.search(r'^## DONE\s*$', text, re.MULTILINE)
if dm:
    done_start = dm.end()
    next_sec = re.search(r'^## ', text[done_start:], re.MULTILINE)
    done_block = text[done_start: done_start + next_sec.start()] if next_sec else text[done_start:]
    done_count = len(re.findall(r'^### ', done_block, re.MULTILINE))
```

Ajout à la fin du return dict : `"done_count": done_count`

Expose immédiatement via `/handoffs` (déjà disponible, parse_state appelé pour tous les fichiers).

### 1b — fleet-monitor.py : surveillance des directionnels

**Fichier** : `fleet/fleet-monitor.py`

**Constantes à ajouter :**
```python
DONE_COUNTS_CACHE = Path("/tmp/fleet-monitor-done-counts.json")

# Mapping directionnel → instance à réveiller
DIRECTIONAL_WAKE = {
    "build-arm-to-dev":          "dev",
    "build-x86-to-dev":          "dev",
    "build-arm-to-starfleet":   "starfleet",
    "build-x86-to-starfleet":   "starfleet",
}
```

**Fonctions à ajouter :**
- `load_done_counts() -> dict[str, int]` : même pattern que load_notified(), invalidé si >10 min
- `save_done_counts(counts: dict[str, int]) -> None` : même pattern que save_notified()

**Dans run()** : après la boucle states, ajouter un bloc directionnels :
```python
handoffs, _ = fetch_json(f"{hub_url}/handoffs")
for hname, recipient in DIRECTIONAL_WAKE.items():
    new_count = handoffs.get(hname, {}).get("done_count", 0)
    old_count = done_counts.get(hname)
    if old_count is None:
        # Premier poll — établir la baseline sans réveiller
        done_counts[hname] = new_count
        save_done_counts(done_counts)
    elif new_count > old_count:
        # Nouvelle entrée DONE → réveiller le destinataire
        fire_wake(hname, recipient,
                  f"[auto-wake] {hname} : nouvelle entrée DONE — lis tes handoffs entrants")
        done_counts[hname] = new_count
        save_done_counts(done_counts)
```

`done_counts` initialisé en `run()` via `load_done_counts()`.

**Résultat** : builder écrit dans build-arm-to-dev.md ## DONE → fleet-monitor détecte
dans les 2s → fire_wake("dev") → dev est réveillé. Zéro action builder supplémentaire.

---

## Phase 2 — fleet-build-done.sh (atomizer succès)

**Fichier nouveau** : `fleet/fleet-build-done.sh`

Symétrique de `fleet-blocker.sh` (qui atomise le chemin échec). Atomise le chemin succès :

```bash
#!/bin/bash
# fleet-build-done.sh — séquence complète "build réussi" en un seul appel
# Usage: fleet-build-done.sh <ref> "<résumé>" ["<corps détaillé>"]

REF="${1:?usage: fleet-build-done.sh <ref> <résumé> [corps]}"
SUMMARY="${2:?usage: fleet-build-done.sh <ref> <résumé> [corps]}"
BODY="${3:-}"

INSTANCE=$(...)
DEV_FILE="/home/commons/handoff/build-{arm|x86}-to-dev.md"  # selon instance

# 1 — STATE : succès
fleet-state.sh action=idle status=done ref="$REF"

# 2 — DONE dans own handoff
fleet-done.sh "$SUMMARY" "$BODY"

# 3 — DONE dans directionnel dev (fleet-monitor auto-wake dev)
# fleet-inject.sh done --file "$DEV_FILE"
# (ou awk direct sur le fichier directionnel)

echo ">>> Build livré — fleet-monitor réveillera dev automatiquement"
```

Déployé via `deploy.sh` dans `builder-utils → ~/.local/bin/` des builders.

**Résultat** : builder réussit → `fleet-build-done.sh abc123 "libostdriftva.so livré"` →
tout est géré (state, own handoff, directional). Zero fleet-notify.sh.

---

## Phase 3 — Builder CLAUDE.md allégé

### 3a — Nouveau fichier : home_claude_CLAUDE-builder.md

**Fichier nouveau** : `home_claude_CLAUDE-builder.md` (à la racine du repo)

Contenu radical : ~60 lignes, linéaire, sans ambiguïté.

**Structure :**
- `## Identité` — rôle, scope interdit (jamais modifier sources OST)
- `## Cycle de build` — séquence unique à 3 étapes : lire → builder → reporter
- `## Commandes disponibles` — table avec les 3 seules commandes utiles + quand les utiliser
- `## Escalade` — fleet-blocker.sh, un seul appel, attendre, ne pas spéculer
- `## Règles shell` — 3 règles only (no error masking, fix root cause, reproductible)
- `## Fin de session` — fleet-state.sh action=handoff status=offline

Ce que le builder n'a PAS besoin de savoir (supprimé) :
- docs_and_plans, bug-journal, context management (/compact)
- Git branches, worktrees, README avant push
- Règles édition fichiers (builders n'éditent pas de sources)
- Plans pour interventions >1 file (hors scope)
- Test policy
- Détail des autres instances et leurs scopes

### 3b — deploy.sh : CLAUDE.md différencié par type

**Fichier** : `deploy.sh`

Actuellement, tous les homes reçoivent le symlink vers `home_claude_CLAUDE.md`.
Pour build-arm et build-x86-64, utiliser `home_claude_CLAUDE-builder.md` :

```bash
# Dans la boucle de déploiement, lors du symlink CLAUDE.md :
case "$instance" in
    build-arm|build-x86-64)
        ln -sf "$DIRECTIVES_PATH/home_claude_CLAUDE-builder.md" "$HOME_DIR/.claude/CLAUDE.md"
        ;;
    *)
        ln -sf "$DIRECTIVES_PATH/home_claude_CLAUDE.md" "$HOME_DIR/.claude/CLAUDE.md"
        ;;
esac
```

---

## Phase 4 — Cleanup protocol builder

### 4a — builder-rules.md : supprimer fleet-notify.sh

**Fichier** : `memory/builder-rules.md`

Supprimer la ligne `fleet-notify.sh dev "..."` du chemin succès.
Ajouter une note : "Le wake de dev est automatique — fleet-monitor détecte les nouvelles
entrées dans build-*-to-dev.md. Aucune action de notification requise."

Remplacer la séquence succès actuelle par :
```bash
fleet-build-done.sh <ref> "<résumé>"   # STATE + own DONE + directional DONE
```

Chemin échec inchangé : `fleet-blocker.sh "<titre>" "<desc>"`.

### 4b — hook post-directional-handoff-reminder.sh

**Fichier** : `.claude/hooks/post-directional-handoff-reminder.sh`

Le hook est inoffensif pour dev et starfleet (leur rappelle de mettre à jour l'own handoff —
toujours valide). Pour les builders, le message est devenu caduc (fleet-notify.sh n'est plus
requis). Pas de suppression — le hook reste, son message sera ignoré ou incompris sans danger.
Le vrai garde-fou est maintenant dans fleet-monitor.

Option : mettre à jour le message pour les builders (détecter INSTANCE et adapter le texte).
Non prioritaire.

---

## Fichiers à modifier / créer

| Fichier | Action | Phase |
|---|---|---|
| `fleet/fleet-hub.py` | Ajouter `done_count` dans `parse_state()` | 1a |
| `fleet/fleet-monitor.py` | Poll `/handoffs`, DIRECTIONAL_WAKE, done_counts | 1b |
| `fleet/fleet-build-done.sh` | Nouveau script (atomizer succès) | 2 |
| `home_claude_CLAUDE-builder.md` | Nouveau fichier (directives Haiku) | 3a |
| `deploy.sh` | CLAUDE.md différencié par instance type | 3b |
| `memory/builder-rules.md` | Supprimer fleet-notify.sh, référencer fleet-build-done.sh | 4a |

---

## Ordre d'implémentation

1. Phase 1 (fleet-hub + fleet-monitor) — core fix, teste auto-wake en isolation
2. Phase 2 (fleet-build-done.sh) — atomizer, teste séquence succès complète
3. Phase 4a (builder-rules.md) — update avant Phase 3 (les directives doivent référencer le bon script)
4. Phase 3 (CLAUDE.md builder + deploy.sh) — deploy en dernier, impacte les sessions builder actives

## Vérification

1. **Auto-wake** : écrire manuellement une entrée `### TEST` dans `build-arm-to-dev.md` ## DONE.
   Dans les 2s, dev doit recevoir un wake. Vérifier via `tmux list-panes` et log fleet-monitor.

2. **fleet-build-done.sh** : tester depuis build-arm (si disponible), sinon simuler depuis
   architect en passant `INSTANCE=build-arm`. Vérifier que les 3 fichiers sont mis à jour
   (own handoff, directional, STATE).

3. **CLAUDE.md builder** : après deploy.sh, vérifier que
   `/home/wsl-root/#2_Home/build-arm/.claude/CLAUDE.md` pointe vers le fichier builder.
   Ouvrir une session build-arm et vérifier que le context chargé est correct (court).

4. **Régression** : vérifier que dev et starfleet reçoivent toujours le CLAUDE.md complet.
