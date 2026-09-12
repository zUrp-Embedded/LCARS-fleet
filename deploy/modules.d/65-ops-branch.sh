#!/usr/bin/env bash
# SOURCE: deploy/modules.d/65-ops-branch.sh
# AUTHOR: bob
# STARDATE: 2026-09-04
# STATUS: la branche ops : un APPELANT du geste de forge du produit (runtime/services/forge.d/ops-branch.sh)
# APPLY-ON: wsl linux
# CHECK-ON: wsl linux
# NEEDS: root
# AFTER: 48-forge-host 63-forge-tokens

set -euo pipefail
# shellcheck source=../lib/provision-lib.sh
. "${PROVISION_LIB:?PROVISION_LIB non posé — ce module se joue par ./provision, pas nu}"

exec env \
  LCARS_MODULE_PROTOCOL="$(product_tree)/services/lib/module-protocol.sh" \
  LCARS_MODULE_TAG="${PROV_MODULE_TAG:-}" \
  FORGE_BASE_URL="${PROV_FORGE_URL:-}" \
  LCARS_SYSTEM_ACCOUNT="${PROV_SYSTEM_ACCOUNT:-}" \
  LCARS_SYSTEM_TOKEN_FILE="${PROV_SYSTEM_TOKEN_FILE:-}" \
  ${LCARS_OPS_REPO:+"LCARS_OPS_REPO=$LCARS_OPS_REPO"} \
  bash "$(product_tree)/services/forge.d/ops-branch.sh" "${1:?usage: 65-ops-branch.sh <check|apply>}"
