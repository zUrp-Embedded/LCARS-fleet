# _archived — fichiers stale post-migration v5

**Date** : 2026-03-14
**Dernière révision** : 2026-03-14
**Statut** : archive non destructive — rollback possible
**Référencé par** : fleet/known-issues-v5-migration.md
**Dérivé de** : audit chaîne d'appels v5 (engineer, 2026-03-14)

## Contexte

Migration IPC v3 → v5 terminée. La chaîne v5 est :

```
install.sh → provision-system.sh → provision-users.sh → deploy.sh
fleet-update.sh → deploy.sh
start → fleet-launch.sh
```

Tous les fichiers ci-dessous ont été identifiés comme **non appelés** par aucune chaîne v5.
Méthode : trace exhaustive de tous les appels (source, bash, cp, référence) depuis install.sh
en suivant chaque branche. Tout fichier dans fleet/ absent de toute chaîne = stale.

**Aucun fichier supprimé.** Déplacés ici pour nettoyage. Git history préservée via `git mv`.

## Inventaire

### Racine fleet/ — remplacés ou doublons

| Fichier | Raison |
|---|---|
| `self-update.sh` | Remplacé par fleet-update.sh (header l.23 : "Replaces self-update.sh") |
| `backup-wsl.sh` | Doublon de toolbox/backup-wsl.sh (deploy.sh déploie toolbox/, pas la racine) |
| `check-backup.sh` | Doublon de toolbox/check-backup.sh (idem) |
| `deploy-fleet.py` | Générateur PS1 pour ancien déploiement WSL multi-distro. Non appelé par v5 |
| `filter-build-output.sh` | build-cycle.sh référence .sh mais deploy.sh déploie .py — incohérence, voir known-issues |

### hooks/ — orphelin

| Fichier | Raison |
|---|---|
| `hooks/block-agent-spawn.sh` | Zéro référence dans tout le repo (settings, CLAUDE.md, deploy, fleet.yaml) |

### docker/ — dead

| Fichier | Raison |
|---|---|
| `docker/Dockerfile` | Aucune référence. Pas de CI, pas de build, pas de deploy |
| `docker/entrypoint.sh` | Idem |

### provisioning/ top-level — stale v3

| Fichier | Raison |
|---|---|
| `config.local.ps1.example` | Exemple PowerShell ancien déploiement |
| `gh-token.example` | Doublon multi-plateforme, non référencé par v5 |
| `git-identity.conf.example` | Idem |
| `githooks/pre-commit` | Hook shellcheck, non référencé par v5 (les hooks actifs sont dans git-hooks/) |
| `new-agent.sh` | Zéro référence dans tout le repo |

### linux/ — chaîne v3 complète (16 fichiers)

Ancienne chaîne de provisioning Linux. Remplacée par les scripts v5 top-level
(provision-system.sh, provision-users.sh, deploy.sh). Se référencent entre eux
mais JAMAIS appelés par la chaîne v5.

- `configure-plan.sh` — v3 plan config
- `deploy-fleet.sh` — v3 deploy
- `gh-token.example` — v3 example
- `git-identity.conf.example` — v3 example
- `new-agent.sh` — v3 agent creator
- `post-install-architect.sh` — v3 post-install
- `post-install-builder.sh` — v3 post-install
- `post-install-dev.sh` — v3 post-install
- `post-install-engineer.sh` — v3 post-install
- `post-install-qualifier.sh` — v3 post-install
- `post-install-starfleet.sh` — v3 post-install
- `post-install-steward.sh` — v3 post-install
- `post-install.sh` — v3 dispatcher
- `provision-system.sh` — v3 system provision (≠ v5 top-level homonyme)
- `provision-user.sh` — v3 user provision
- `setup-linux.sh` — v3 setup

### mac/ — chaîne v3 (5 fichiers)

Aucun appel depuis v5. Chaîne Mac complète morte.

- `deploy-fleet.sh`
- `gh-token.example`
- `git-identity.conf.example`
- `new-agent.sh`
- `setup-mac.sh`

### wsl2/ — chaîne v3 (15 fichiers + 2 sous-dossiers déjà archivés)

Post-install WSL, non appelé par v5. Les PS1 (Instanciator, Fetch-Rootfs)
opèrent côté Windows — potentiellement encore utiles, à vérifier avant suppression.

- `Deploy-Fleet.ps1` — probablement stale (remplacé par deploy.sh v5)
- `Fetch-Rootfs.ps1` — potentiellement actif côté Windows
- `Instanciator.ps1` — potentiellement actif côté Windows
- `configure-plan.sh`
- `gh-token.example`
- `git-identity.conf.example`
- `post-install-base.sh`
- `post-install-builder.sh`
- `post-install-dev.sh`
- `post-install-engineer.sh`
- `post-install-qualifier.sh`
- `post-install-starfleet.sh`
- `post-install.sh`
- `rpi-target-set.sh`
- `wsl-setup.sh`
- `_archived/` — déjà archivé avant cette passe
- `#9_ps1-legacy/` — déjà marqué legacy
