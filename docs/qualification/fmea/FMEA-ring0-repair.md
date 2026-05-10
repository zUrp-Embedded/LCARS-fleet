# FMEA — Ring 0 Repair (3 scripts)

**Date** : 2026-03-28
**Derniere revision** : 2026-03-28
**Statut** : premiere passe
**Reference par** : v6-rings-and-interfaces.md
**Derive de** : code review Ring 0 repair

---

## Methode

S/O/D echelle 1-10. RPN = S x O x D. Seuil fix : RPN > 10.

## Scripts : fleet-update.sh, deploy.sh, deploy-lib.sh

| ID | Script | Mode de defaillance | S | O | D | RPN | Mitigation |
|---|---|---|---|---|---|---|---|
| R0R-01 | fleet-update | git pull --ff-only echoue (divergence remote) | 6 | 2 | 1 | 12 | Exit 1 + message clair. Intervention manuelle. |
| R0R-02 | fleet-update | sudo manquant (non-root execution) | 8 | 1 | 1 | 8 | git pull et deploy.sh necessitent sudo. Echec immediat visible. |
| R0R-03 | fleet-update | deploy.sh absent apres pull (fichier supprime upstream) | 9 | 1 | 2 | 18 | Guard `-x "$DEPLOY"` avec exit 1. Mais le pull a reussi — runtime partiellement mis a jour. |
| R0R-04 | fleet-update | cache invalidation incomplete (homes manquantes) | 4 | 2 | 5 | 40 | La boucle `for _home in "$HOMES_ROOT"/*/` skip les homes non creees. Si un agent est ajoute au blueprint mais pas encore provisionne, son cache n'est pas invalide. |
| R0R-05 | fleet-update | fleet-build-yaml.sh echoue silencieusement | 7 | 1 | 4 | 28 | `[ -x "$BUILD_YAML" ] && bash "$BUILD_YAML"` — si build-yaml echoue, deploy continue avec l'ancien fleet.yaml. Pas d'exit check. |
| R0R-06 | deploy.sh | deploy.d sub-script echoue mid-chain | 7 | 2 | 3 | 42 | set -euo pipefail arrete la chain. Mais les sub-scripts precedents ont deja modifie des fichiers — etat partiellement deploye. |
| R0R-07 | deploy.sh | SOURCE_DIR incorrect (SCRIPT_DIR resolution echoue) | 8 | 1 | 3 | 24 | readlink -f + cd/pwd. Si le path est un symlink casse, SCRIPT_DIR est faux → tout le deploy copie depuis le mauvais endroit. |
| R0R-08 | deploy-lib | sync_tree ecrase un fichier modifie localement par l'agent | 5 | 3 | 6 | 90 | sync_tree fait `cmp -s` et ne copie que si different. Mais "different" inclut les modifications locales legit (agent a edite un skill). Le deploy ecrase sans warning. |
| R0R-09 | deploy-lib | register_hook echoue si patch-json.py absent | 4 | 1 | 2 | 8 | Le chemin PATCH_JSON est verifie dans deploy.sh. Mais si le fichier est present mais bugge, le hook n'est pas enregistre silencieusement. |
| R0R-10 | deploy-lib | umask 002 trop permissif pour certains fichiers | 3 | 1 | 5 | 15 | umask 002 = group-writable. Voulu pour le groupe fleet. Mais si un fichier sensible est deploye (credentials), il est lisible par tous les agents fleet. |

---

## Fixes RPN > 10

| ID | RPN | Action |
|---|---|---|
| R0R-01 | 12 | Acceptable — fail-fast by design. |
| R0R-03 | 18 | Acceptable — scenario theorique (fichier deploye supprime upstream). |
| R0R-04 | 40 | **Important.** Ajouter un log quand un home n'existe pas pendant l'invalidation. |
| R0R-05 | 28 | **Important.** Ajouter un check du exit code de build-yaml avant de continuer. |
| R0R-06 | 42 | **Important.** Ajouter un rollback ou au minimum un log de l'etat partiel. |
| R0R-07 | 24 | Acceptable — readlink -f est robuste. |
| R0R-08 | 90 | **Critique.** sync_tree ecrase les modifications locales sans warning. Ajouter un check : si le fichier cible a ete modifie apres le dernier deploy (mtime > deploy timestamp), avertir au lieu d'ecraser. |
| R0R-10 | 15 | Acceptable — voulu pour collaboration fleet. Credentials dans /home/private/ (mode 700). |

---

## Bilan

- 10 modes de defaillance
- 1 critique (R0R-08 RPN 90) — sync_tree ecrase localement
- 3 importants (R0R-04:40, R0R-05:28, R0R-06:42) — mitigations proposees
- 6 sous controle
