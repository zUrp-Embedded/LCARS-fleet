# Plan — Auto-wake inter-instance + canaux builder→starfleet

## Context

Herald actuel : notification humaine uniquement (tmux display-message 8s, une fois).
Objectif : communication entièrement automatique instance→instance sans intervention humaine.
Builders (haiku, économiques) posent des questions bloquantes → starfleet (sonnet) répond → builder reprend.

## Fichiers modifiés / créés

| Fichier | Action |
|---|---|
| `/home/commons/handoff/build-arm-to-starfleet.md` | créer |
| `/home/commons/handoff/build-x86-to-starfleet.md` | créer |
| `/home/lordzurp/fleet/wake-instance.sh` | créer |
| `/home/lordzurp/fleet/fleet-monitor.py` | modifier (~10 lignes) |
| `/home/lordzurp/fleet/fleet-hub.py` | modifier (~4 lignes) |
| `/home/lordzurp/fleet/fleet-launch.sh` | modifier (~8 lignes) |
| `/home/wsl-root/#0_Claude-directives/fleet/*` | sync source repo |
| `/home/wsl-root/#0_Claude-directives/memory/ipc-protocol.md` | mettre à jour |

---

## 1. Nouveaux canaux handoff

`/home/commons/handoff/build-arm-to-starfleet.md` et `build-x86-to-starfleet.md` :
```markdown
# build-arm → starfleet handoff

## STATE
date: 2026-03-03 00:00
ref: none
action: idle
status: pending
blocker: none
waiting: none
notify: none

## ACTIONS

## DONE
```

Séparation des responsabilités :
- `build-arm-to-dev.md` — résultats de build, artifacts, notes de code (dev lit)
- `build-arm-to-starfleet.md` — questions bloquantes, choix d'outils, manque de dépendance (starfleet lit)

---

## 2. fleet-hub.py — ajout HANDOFF_FILES

```python
HANDOFF_FILES = {
    "dev-to-build":           "dev-to-build.md",
    "build-arm-to-dev":       "build-arm-to-dev.md",
    "build-x86-to-dev":       "build-x86-to-dev.md",
    "build-arm-to-starfleet":"build-arm-to-starfleet.md",   # nouveau
    "build-x86-to-starfleet":"build-x86-to-starfleet.md",   # nouveau
}
```

---

## 3. wake-instance.sh (nouveau)

```bash
wake-instance.sh <instance> <message>
```

Table hardcodée basée sur fleet-launch.sh :
```
starfleet   → fleet:starfleet   (pane 0)
dev          → fleet:dev          (pane 0)
build-arm    → fleet:monitor.1    (bottom-left)
build-x86-64 → fleet:monitor.2    (bottom-right)
lordzurp     → herald.sh (message humain)
```

Logique :
1. Lookup tmux target depuis table
2. Vérifier que le pane existe (`tmux list-panes`)
3. Vérifier si Claude Code tourne dans le pane (`tmux display-message -p "#{pane_current_command}"`)
4. Si WSL pas démarré (pane vide ou process = bash en exit) : inject `wsl.exe -d <distro>` + sleep 5
5. Si Claude Code pas running : inject `claude --resume` + sleep 8
6. Inject message : `tmux send-keys -t <target> "<message>" Enter`

Gestion offline : si `wsl.exe --list --running` ne montre pas la distro, on relance le pane.

---

## 4. fleet-monitor.py — routing notify

Remplacer `fire_herald(iid, waiting_val, notify_val)` par dispatch :

```python
INSTANCE_NAMES = {"starfleet", "architect", "dev", "build-arm", "build-x86-64"}

def dispatch_notify(instance: str, waiting: str, notify: str):
    if notify == "architect":
        fire_herald(instance, waiting, notify)
    elif notify in INSTANCE_NAMES:
        wake_msg = f"[auto-wake] {instance} attend: {waiting} — lis tes handoffs entrants"
        fire_wake(instance, notify, wake_msg)
    # else: inconnu, ignorer

def fire_wake(source: str, target: str, message: str):
    if WAKE_SCRIPT.exists():
        subprocess.Popen(
            [str(WAKE_SCRIPT), target, message],
            stdout=subprocess.DEVNULL, stderr=subprocess.DEVNULL,
        )
```

`notified` dict : inchangé (évite les déclenchements répétés).

---

## 5. fleet-launch.sh — fenêtre starfleet channels

Ajouter fenêtre 7 `sup-channels` :
```bash
tmux new-window -t "$SESSION" -n "sup-channels"
tmux send-keys -t "$SESSION:sup-channels" \
    "watch -n2 -t --color python3 $HOME/fleet/colorize-handoff.py $HANDOFF/build-arm-to-starfleet.md" Enter
tmux split-window -v -t "$SESSION:sup-channels"
tmux send-keys -t "$SESSION:sup-channels" \
    "watch -n2 -t --color python3 $HOME/fleet/colorize-handoff.py $HANDOFF/build-x86-to-starfleet.md" Enter
tmux select-layout -t "$SESSION:sup-channels" even-vertical
```

---

## 6. ipc-protocol.md — mise à jour

- Table handoffs : ajouter les 2 nouveaux fichiers
- `notify:` : documenter les valeurs acceptées (`lordzurp` | nom d'instance)
- Protocole builder→starfleet : séquence write→notify→wait→reset
- Protocole reset : après traitement, l'émetteur remet `notify: none` + `waiting: none`

---

## Protocole résultant

```
build-arm bloqué (ex: quel outil pour image RPi ?)
  1. Écrit question dans build-arm-to-starfleet.md (## ACTIONS ou ## DONE)
  2. build-arm-handoff.md STATE: waiting: <sujet>, notify: starfleet

fleet-monitor (2s poll) détecte notify: starfleet
  → wake-instance.sh starfleet "[auto-wake] build-arm attend: <sujet>..."
  → tmux send-keys → Claude Code starfleet

Supervisor lit build-arm-to-starfleet.md, cherche solution
  (si non trivial: demande validation lordzurp via notify: architect)
  Écrit réponse dans starfleet-notes.md
  starfleet-handoff.md STATE: notify: build-arm

fleet-monitor détecte notify: build-arm
  → wake-instance.sh build-arm "[auto-wake] starfleet a répondu..."
  → Claude Code build-arm reprend

build-arm remet notify: none, waiting: none et continue le build
```

---

## Déploiement

1. Créer les 2 fichiers handoff dans `/home/commons/`
2. Modifier fleet-hub.py + fleet-monitor.py + fleet-launch.sh dans `/home/lordzurp/fleet/`
3. Créer wake-instance.sh dans `/home/lordzurp/fleet/` + `chmod +x`
4. Sync source : copier les modifiés vers `/home/wsl-root/#0_Claude-directives/fleet/`
5. Mettre à jour `ipc-protocol.md` dans Claude-directives
6. Commit + push Claude-directives
7. Redémarrer fleet-hub + fleet-monitor (`fleet-restart.sh` si disponible, sinon kill+relaunch)
8. **Ne pas** relancer fleet-launch.sh (session active) — la fenêtre sup-channels sera dispo au prochain lancement

## Vérification

1. `curl -s http://127.0.0.1:8765/handoffs` → doit retourner les 5 canaux dont les 2 nouveaux
2. Modifier `build-arm-handoff.md` → `notify: starfleet` → vérifier que wake-instance.sh se déclenche (log stderr)
3. Vérifier `tmux send-keys` injecte dans le bon pane (fenêtre starfleet)
4. Test end-to-end : build-arm écrit question + notify → starfleet reçoit wake → répond → build-arm reçoit wake
