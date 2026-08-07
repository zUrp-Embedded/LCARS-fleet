# FMEA — Ring 0 Setup (20 scripts)

**Date** : 2026-03-28
**Derniere revision** : 2026-03-28
**Statut** : premiere passe
**Reference par** : v6-rings-and-interfaces.md
**Derive de** : code review Ring 0 setup

---

## Methode

S/O/D echelle 1-10. RPN = S x O x D. Seuil fix : RPN > 10.

## Bloc 1 — deploy.d/ (6 scripts)

| ID | Script | Mode de defaillance | S | O | D | RPN |
|---|---|---|---|---|---|---|
| R0S-01 | deploy-restore | rsync --ignore-existing rate un fichier corrompu | 3 | 2 | 5 | 30 |
| R0S-02 | deploy-restore | ready-room absent (drvfs non monte) | 2 | 3 | 1 | 6 |
| R0S-03 | deploy-claude | CLAUDE.md source manquant | 7 | 1 | 2 | 14 |
| R0S-04 | deploy-claude | settings.json ecrase par le deploy (modif locale perdue) | 5 | 2 | 5 | 50 |
| R0S-05 | deploy-fleet | DEPLOY marker absent dans un script → pas deploye | 3 | 2 | 4 | 24 |
| R0S-06 | deploy-bashrc | patch .bashrc casse la syntax bash | 6 | 1 | 2 | 12 |
| R0S-07 | deploy-hooks | hooks.yaml absent ou mal forme | 5 | 1 | 3 | 15 |
| R0S-08 | deploy-infra | spool permissions incorrectes (inbox non writable) | 6 | 1 | 2 | 12 |

## Bloc 2 — Provisioning top-level (7 scripts)

| ID | Script | Mode de defaillance | S | O | D | RPN |
|---|---|---|---|---|---|---|
| R0S-10 | provision-system | sub-script echoue mid-chain | 7 | 1 | 2 | 14 |
| R0S-11 | provision-users | user cree sans home (useradd bug) | 6 | 1 | 2 | 12 |
| R0S-12 | provision-fleet | runtime absent (/local/LCARS vide) | 8 | 1 | 1 | 8 |
| R0S-13 | onboard-preflight | faux positif (detecte un etat incorrect) | 2 | 2 | 3 | 12 |
| R0S-14 | post-install-offline | git init sur un repo deja initialise | 2 | 1 | 2 | 4 |
| R0S-15 | post-reboot | credentials wizard absentes | 5 | 2 | 2 | 20 |
| R0S-16 | deploy-migrations | migration re-executee (non idempotente en pratique) | 4 | 1 | 4 | 16 |

## Bloc 3 — provision.d/ (7 scripts)

| ID | Script | Mode de defaillance | S | O | D | RPN |
|---|---|---|---|---|---|---|
| R0S-20 | provision-packages | apt install echoue (reseau, dpkg lock) | 5 | 3 | 1 | 15 |
| R0S-21 | provision-groups | fleet group existe deja avec un GID different | 3 | 1 | 3 | 9 |
| R0S-22 | provision-sudoers | sudoers syntax error → sudo casse pour tous | 9 | 1 | 1 | 9 |
| R0S-23 | provision-directories | spool dir cree avec mauvais ownership | 5 | 1 | 2 | 10 |
| R0S-24 | provision-claude-bin | install.sh curl echoue (reseau) | 4 | 2 | 1 | 8 |
| R0S-25 | provision-git | PAT expire ou invalide | 4 | 3 | 2 | 24 |
| R0S-26 | provision-wsl | wsl.conf modification casse le boot WSL | 7 | 1 | 3 | 21 |

---

## Fixes RPN > 10

| ID | RPN | Action |
|---|---|---|
| R0S-01 | 30 | Acceptable — rsync --ignore-existing est conservateur. |
| R0S-03 | 14 | Acceptable — detection immediate. |
| R0S-04 | 50 | **Important.** Meme probleme que R0R-08. deploy-claude ecrase settings.json si modifie localement. |
| R0S-05 | 24 | Acceptable — le marker est documente dans header-template. |
| R0S-06 | 12 | Acceptable — les patches sont idempotents (grep avant sed). |
| R0S-07 | 15 | Acceptable — fallback si hooks.yaml absent. |
| R0S-08 | 12 | Acceptable — chown explicite dans deploy-infra. |
| R0S-10 | 14 | Acceptable — set -euo pipefail stoppe la chaine. |
| R0S-11 | 12 | Acceptable — useradd + mkdir -p /home. |
| R0S-13 | 12 | Acceptable — report only, pas d'action. |
| R0S-15 | 20 | Acceptable — wizard absent = message explicite, l'user est guide. |
| R0S-16 | 16 | Acceptable — chaque migration est gardee par un test d'existence. |
| R0S-20 | 15 | Acceptable — apt errors sont visibles. |
| R0S-25 | 24 | Acceptable — PAT expiration detectee par gh auth status. |
| R0S-26 | 21 | **Important.** wsl.conf modifie = reboot WSL. Ajouter un backup avant modif. |

---

## Bilan

- 26 modes de defaillance (3 blocs)
- 0 critique (aucun RPN > 100)
- 2 importants (R0S-04:50, R0S-26:21)
- 24 sous controle
