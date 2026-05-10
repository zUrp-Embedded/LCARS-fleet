# Phase 1 — Herald/Signal

## Context

Les instances communiquent via fichiers handoff plats. Quand une instance est bloquée en attente d'une autre (ou de lordzurp), il n'y a aucune notification active — il faut surveiller le dashboard manuellement. Le herald ajoute un mécanisme de signal : l'instance déclare qu'elle attend + qui notifier, et fleet-monitor déclenche une alerte tmux.

Pré-requis constaté : cDs-architect manque dans `fleet-hub.py` INSTANCE_FILES, et le layout de `fleet-monitor.py` n'affiche que 4 cards sur 5. Corrigé dans la foulée.

## Fichiers modifiés

| Fichier | Action |
|---|---|
| `fleet/fleet-hub.py` | Regex STATE 5→7 lignes (backward-compatible), ajout cDs-architect, nouveaux champs |
| `fleet/fleet-monitor.py` | Layout 5 cards (3+2), affichage waiting/notify, logique herald trigger |
| `fleet/colorize-handoff.py` | Colorisation lignes waiting:/notify: |
| `fleet/herald.sh` | **Nouveau** — `tmux display-message` |
| `memory/ipc-protocol.md` | Format STATE 5→7 lignes |

## Design

### 1. Format STATE étendu (7 lignes)

```
## STATE
date: 2026-03-03 00:18
ref: none
action: idle
status: done
blocker: none
waiting: none
notify: none
```

- `waiting:` — ce qu'attend l'instance (ex: `build-arm-done`, `lordzurp-signal`, `dev-commit`)
- `notify:` — qui alerter (ex: `lordzurp`, `starfleet`, `none`)
- Valeur par défaut : `none` pour les deux

### 2. fleet-hub.py — regex backward-compatible

```python
STATE_RE = re.compile(
    r'## STATE\n'
    r'date:\s*(.+)\n'
    r'ref:\s*(.+)\n'
    r'action:\s*(.+)\n'
    r'status:\s*(.+)\n'
    r'blocker:\s*(.+)'
    r'(?:\nwaiting:\s*(.+))?'
    r'(?:\nnotify:\s*(.+))?'
)
```

Les deux derniers groupes sont optionnels — les handoffs non mis à jour restent lisibles. `parse_state()` renvoie `waiting` et `notify` (default `"none"` si absent).

Ajout dans INSTANCE_FILES :
```python
"cDs-architect": "cDs-architect-handoff.md",
```

### 3. fleet-monitor.py — affichage + herald trigger

**Layout 3+2 :**
```
[starfleet] [architect] [dev]
[build-ARM]  [build-X86-64]
```
Top row : management. Bottom row : workers.

**Affichage dans chaque card :**
- Si `waiting != "none"` : ligne `waiting` en magenta, icône ⏳
- Si `notify != "none"` : ligne `notify` en magenta bold

**Herald trigger :**
- fleet-monitor maintient un dict `notified: dict[str, str]` (instance → dernier notify vu)
- À chaque refresh, pour chaque instance :
  - Si `notify` passe de `"none"` à une valeur → appeler `herald.sh <instance> <waiting> <notify>`
  - Si `notify` revient à `"none"` → effacer de `notified`
- Pas de re-notification tant que `notify` reste identique (anti-spam)

### 4. herald.sh

```bash
#!/bin/bash
# herald.sh — notification tmux pour lordzurp
INSTANCE="${1:?usage: herald.sh <instance> <waiting> <notify>}"
WAITING="${2:-unknown}"
NOTIFY="${3:-lordzurp}"
tmux display-message -d 8000 "⚡ ${INSTANCE} waiting: ${WAITING} → notify: ${NOTIFY}"
```

Appel non-bloquant depuis fleet-monitor via `subprocess.Popen` (fire-and-forget). Durée affichage : 8 secondes.

### 5. colorize-handoff.py

Ajout de deux cas dans `colorize_line()` :
- `waiting:` → magenta si valeur != "none", dim sinon
- `notify:` → magenta bold si valeur != "none", dim sinon

### 6. ipc-protocol.md

Section format STATE mise à jour : 7 lignes, documentation des deux nouveaux champs, note backward-compat.

## Vérification

1. Lancer `fleet-hub.py` manuellement, `curl localhost:8765/state` → vérifier que les champs `waiting`/`notify` apparaissent (default `none` pour les instances pas encore mises à jour)
2. Lancer `fleet-monitor.py` → vérifier layout 5 cards, pas de crash
3. Mettre à jour mon propre handoff avec `notify: architect` → vérifier que herald.sh fire une fois (tmux display-message visible)
4. Remettre `notify: none` → vérifier pas de re-notification
5. `deploy.sh` pour distribuer aux instances
