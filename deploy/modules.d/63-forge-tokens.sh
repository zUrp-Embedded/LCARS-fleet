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

exec env \
  LCARS_MODULE_PROTOCOL="$(product_tree)/services/lib/module-protocol.sh" \
  LCARS_MODULE_TAG="${PROV_MODULE_TAG:-}" \
  FORGE_BASE_URL="${PROV_FORGE_URL:-}" \
  LCARS_FORGE_ORG="${PROV_FORGE_ORG:-}" \
  LCARS_PRIVATE_DIR="${PROV_TOKENS_DIR:-}" \
  LCARS_MASTER_TOKEN_FILE="${PROV_MASTER_TOKEN_FILE:-}" \
  LCARS_FORGE_SEED_FILE="${PROV_FORGE_SEED_FILE:-}" \
  LCARS_SYSTEM_ACCOUNT="${PROV_SYSTEM_ACCOUNT:-}" \
  LCARS_SYSTEM_TOKEN_FILE="${PROV_SYSTEM_TOKEN_FILE:-}" \
  LCARS_AUTHORITY_USER="${PROV_AUTHORITY_USER:-}" \
  LCARS_CATALOGUES_DIR="${PROV_CATALOGUES_DIR:-}" \
  LCARS_ROLES="${PROV_ROLES:-}" \
  LCARS_LOGIN="${PROV_HUMAN:-}" \
  LCARS_CLI="${PROV_LCARS_CLI:-${PROV_LINK_DIR:+$PROV_LINK_DIR/lcars}}" \
  bash "$(product_tree)/services/forge.d/tokens.sh" "${1:?usage: 63-forge-tokens.sh <check|apply>}"
