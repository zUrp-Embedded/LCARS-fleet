#!/bin/bash
#
#       ______________________________________________________
#      /          LCARS FLEET - FEDERATION DATABASE           \
#     |   ________   __________________________________________\
#     |  |  2026  |  | SOURCE: hook-config.sh
#     |  |________|  | AUTHOR: LORDZURP
#     |   ________   | SYSTEM: LCARS-FLEET v5.4
#     |  |  v5.4  |  | STATUS: OPERATIONAL
#     |  |________|  |__________________________________________
#     |              \__________________________________________\
#      \    "To boldly go where no code has gone before..."     /
#       \______________________________________________________/
#
#     +-----------------------------------------------------------+
#     | [ LCARS FLEET ] COMMAND INTERFACE    [ ACCESS GRANTED ]   |
#     +-----------------------------------------------------------+
#     | MODULE: HOOK-CONFIG       | SUBSYSTEM: GIT-HOOKS / CONFIG  |
#     | LICENSE: AGPL-3           | STARDATE: 2026.226             |
#     +-------------------------+---------------------------------+
#     |                                                           |
#     |  Context detection for git hooks. Sources by pre-commit   |
#     |  and pre-push to adapt behavior per repo type.            |
#     |                                                           |
#     +-----------------------------------------------------------+
#
#
#     [FR]
#     Configuration partagée des git hooks. Détecte le type de repo.
#
#     [EN]
#     NAME
#         hook-config.sh — shared context detection for git hooks
#
#     INTERFACE
#         Ring:    0 (gate)
#         Input:   git repo root (runtime/mix.exs carrying `app: :lcars_fleet`)
#         Output:  exported variables: HOOK_REPO_TYPE (lcars|project),
#                  HOOK_DATE_FORMAT (stardate|iso), HOOK_DATE_FIELD,
#                  HOOK_POST_PUSH (fleet-update|none)
#
#     EXIT CODES
#         N/A (sourced by pre-commit/pre-push hooks)
#
# --- END HEADER ---

# ⚠ AUCUN `set` ICI : ce fichier est SOURCE (pre-commit l.80, pre-push, repo_type.bats). Un
# `set -e` y imposerait son mode a l'appelant — un hook qui n'en veut pas mourrait sur la
# premiere commande non nulle d'un autre fichier que le sien.

HOOK_REPO_ROOT="$(git rev-parse --show-toplevel 2>/dev/null || echo ".")"

# LA BRANCHE `lcars` ETAIT MORTE, ET RIEN NE LE DISAIT. Le marqueur teste etait
# `fleet/fleet-env.sh` : ce fichier n'existe nulle part dans le depot et n'a aucun producteur. Toute
# installation nominale des hooks DANS LCARS prenait donc la branche `project` — le tampon STARDATE
# annonce par `pre-commit` ne s'executait jamais, et les variables de politique LCARS etaient
# inatteignables. Un detecteur qui ne detecte rien ne leve pas : il repond l'autre branche.
#
# Le marqueur est desormais l'IDENTITE de l'app, versionnee et impossible a deplacer par accident :
# `runtime/mix.exs` DOIT porter `app: :lcars_fleet`. Le test du contenu et pas seulement du chemin,
# parce qu'un depot projet peut tres bien porter un `runtime/mix.exs` a lui.
# `git-hooks/tests/repo_type.bats` tient la propriete, et l'un de ses cas lit le VRAI `mix.exs` du
# depot : le jour ou l'app est renommee, c'est ce test qui le dit, pas un hook redevenu muet.
if [ -f "$HOOK_REPO_ROOT/runtime/mix.exs" ] &&
   grep -q 'app: :lcars_fleet' "$HOOK_REPO_ROOT/runtime/mix.exs"; then
    HOOK_REPO_TYPE="lcars"
    HOOK_DATE_FORMAT="stardate"
    HOOK_DATE_FIELD="STARDATE"
    HOOK_POST_PUSH="fleet-update"
else
    HOOK_REPO_TYPE="project"
    HOOK_DATE_FORMAT="iso"
    HOOK_DATE_FIELD="Dernière révision"
    HOOK_POST_PUSH="none"
fi

export HOOK_REPO_TYPE HOOK_DATE_FORMAT HOOK_DATE_FIELD HOOK_POST_PUSH
