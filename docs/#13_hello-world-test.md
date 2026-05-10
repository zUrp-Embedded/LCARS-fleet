# Hello World — Test d'acceptance fleet

**Date** : 2026-03-08
**Dernière révision** : 2026-03-21
**Statut** : procédure active
**Référencé par** : ONBOARDING.md

> **Quickstart** — Valide le protocole IPC sur un cas trivial (`echo "Hello, World!"`). Cycle : engineer → dev → qualifier. Si ça tourne sans intervention humaine, la fleet est opérationnelle. Si ça coince, c'est un bug bloquant.

---

## Prérequis

Fleet démarrée (`~/start`), 4 instances actives (engineer, dev, qualifier, starfleet), `/home/projects/hello-world/` n'existe pas.

---

## Cycle

```
[user] → engineer : "specs hello world"
  → fleet-send.sh dev "Implement hello-world"
    → dev : crée hello.sh, git init+commit
      → fleet-send.sh qualifier "Validate hello-world"
        → qualifier : exécute, vérifie output
          → fleet-send.sh engineer "QA result: PASS|FAIL"
[user] → fleet-fetch.sh engineer → DONE
```

---

## Étapes

| # | Action | Vérification |
|---|---|---|
| 0 | `tmux ls` — fleet active ? `ls /var/spool/fleet/inbox/dev/` — spool OK ? | Session "fleet" présente, répertoire inbox existe |
| 1 | Fenêtre engineer → taper mission (specs hello.sh, repo `/home/projects/hello-world/`, dispatch à dev) | `ls /var/spool/fleet/inbox/dev/` contient un message |
| 2 | Observer dev (Alt+d) — crée hello.sh, commit, dispatch qualifier | `bash /home/projects/hello-world/hello.sh` → "Hello, World!" |
| 3 | Observer qualifier — exécute, vérifie, envoie PASS/FAIL | — |
| 4 | `fleet-fetch.sh engineer` — ACK PASS reçu | `bash hello.sh` → "Hello, World!" |

**Timeout** : 5 min par étape. Au-delà → vérifier le handoff de l'instance.

---

## PASS si

1. `hello.sh` existe et output = `Hello, World!`
2. Qualifier a envoyé PASS
3. Zéro intervention humaine entre étapes 1 et 4

---

## Troubleshooting

| Symptôme | Action |
|---|---|
| Engineer ne dispatche pas | `cat ~/.claude/CLAUDE.md` dans l'instance |
| Dev ne reçoit pas | `ls /var/spool/fleet/inbox/dev/` |
| hello.sh absent | Vérifier `/home/projects/` accessible depuis dev |
| Qualifier bloqué | Permissions hello.sh, `chmod +x` |
| ACK manquant | Vérifier handoff, relancer instance |
