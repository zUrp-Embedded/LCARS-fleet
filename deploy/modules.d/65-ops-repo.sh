#!/usr/bin/env bash
# SOURCE: deploy/modules.d/65-ops-repo.sh
# AUTHOR: bob
# STARDATE: 2026-09-04
# STATUS: le dépôt du système : un APPELANT du geste de forge du produit (runtime/services/forge.d/ops-repo.sh), qui vérifie ce que la recette a posé
# APPLY-ON: wsl linux
# CHECK-ON: wsl linux
# NEEDS: root
# AFTER: 10-packages 48-forge-host 61-forge-structure 63-forge-tokens

set -euo pipefail
# shellcheck source=../lib/provision-lib.sh
. "${PROVISION_LIB:?PROVISION_LIB non posé — ce module se joue par ./provision, pas nu}"

prov_geste ops-repo "${1:?usage: 65-ops-repo.sh <check|apply>}"
