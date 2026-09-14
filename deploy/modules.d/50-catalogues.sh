#!/usr/bin/env bash
# SOURCE: deploy/modules.d/50-catalogues.sh
# AUTHOR: bob
# STARDATE: 2026-09-04
# STATUS: le matériel des catalogues installés, convergé depuis la forge — un appelant du geste du produit (runtime/services/forge.d/catalogues.sh)
# APPLY-ON: any
# CHECK-ON: any
# NEEDS: root
# AFTER: 25-directories 48-forge-host

set -euo pipefail
# shellcheck source=../lib/provision-lib.sh
. "${PROVISION_LIB:?PROVISION_LIB non posé — ce module se joue par ./provision, pas nu}"

exec env \
  LCARS_MODULE_PROTOCOL="$(product_tree)/services/lib/module-protocol.sh" \
  LCARS_MODULE_TAG="${PROV_MODULE_TAG:-}" \
  FORGE_BASE_URL="${PROV_FORGE_URL:-}" \
  LCARS_PRIVATE_DIR="${PROV_TOKENS_DIR:-}" \
  LCARS_CATALOGUES_DIR="${PROV_CATALOGUES_DIR:-}" \
  bash "$(product_tree)/services/forge.d/catalogues.sh" "${1:?usage: 50-catalogues.sh <check|apply>}"
