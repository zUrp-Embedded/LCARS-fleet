#!/usr/bin/env bash
# SOURCE: deploy/modules.d/63-forge-tokens.sh
# AUTHOR: bob
# STARDATE: 2026-09-04
# STATUS: les jetons de rôle : un APPELANT du geste de forge du produit (runtime/services/forge.d/tokens.sh)
# APPLY-ON: wsl linux
# CHECK-ON: wsl linux
# NEEDS: root
# AFTER: 48-forge-host 50-catalogues 61-forge-structure

set -euo pipefail
# shellcheck source=../lib/provision-lib.sh
. "${PROVISION_LIB:?PROVISION_LIB non posé — ce module se joue par ./provision, pas nu}"

prov_geste tokens "${1:?usage: 63-forge-tokens.sh <check|apply>}" LCARS_CLI="$PROV_LINK_DIR/lcars"
