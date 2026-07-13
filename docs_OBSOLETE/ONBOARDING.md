# LCARS Fleet — Operations Quickstart

**Date** : 2026-03-21
**Dernière révision** : 2026-03-30
**Statut** : guide opératoire
**Référencé par** : README.md, #00_index.md

> Guide court pour démarrer, arrêter, regarder l'état, et reprendre la main quand quelque chose coince.

Détail commandes : `<script> --help`. Ce guide ne remplace pas les man-pages runtime.

---

## Démarrer / arrêter

```bash
~/start
~/stop
~/restart
```

Règles :
- utiliser `~/stop`, pas `tmux kill-session`
- redémarrer proprement avant de diagnostiquer plus loin
- après une modification LCARS, redeploy via `fleet-update.sh`

---

## Tmux

| Fenêtre | Usage | Raccourci |
|---|---|---|
| `1:monitor` | dashboard, builder, btop | `Alt+m` |
| `2:dev` | session dev | `Alt+d` |
| `4:starfleet` | session sysadmin | `Alt+s` |
| `7-10` | canaux IPC lecture seule | `Alt+h` pour dev-notes |

Navigation : `Alt+←` / `Alt+→`.

---

## Parler à un agent

1. Aller dans la fenêtre voulue
2. `claude --resume` pour reprendre, ou `claude` pour une session neuve
3. Écrire le message

Pour l'usage normal, le point d'entrée reste **architect**. Les autres fenêtres servent surtout au diagnostic, à l'observation, ou à une intervention explicite.

---

## Observer la fleet

| Niveau | Commande |
|---|---|
| Dashboard | fenêtre `1:monitor` |
| API état | `curl -s localhost:8765/state \| python3 -m json.tool` |
| Handoff direct | `cat $FLEET_HANDOFFS/<role>-handoff.md` |
| Suivi live | `watch-handoff.sh <role>` |

Ready Room :
- `/home/ready-room/inbox/` : user vers fleet
- `/home/ready-room/outbox/` : fleet vers user
- `/home/ready-room/fleet-live/` : vue lecture seule du runtime

---

## Premier réflexe quand ça casse

```bash
fleet-doctor.sh
```

Puis selon le symptôme :
- agent muet : `fleet-fetch.sh <role>` puis `wake-instance.sh <role> "check inbox"`
- message non traité : regarder `/var/spool/fleet/inbox/<role>/`
- comportement incohérent : `fleet-check-coherence.sh`, puis `fleet-update.sh --force`
- lock zombie : `fleet-lock-cleanup.sh`

Le guide détaillé est [#19_troubleshooting.md](#19).

---

## Déployer

```bash
fleet-update.sh
```

Principe :
- source de vérité dans le repo
- runtime jetable
- mise à jour par redeploy, pas par bricolage sur instance vivante

Triangle strict :
- source
- remote
- runtime

Ne pas appeler `deploy.sh` directement en exploitation normale.
