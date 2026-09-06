#!/usr/bin/env bash
# SOURCE: deploy/modules.d/45-catalogues.sh
# AUTHOR: bob
# STARDATE: 2026-09-04
# STATUS: PROTO-V2 — le matériel des catalogues installés : un APPELANT du geste de forge du produit (runtime/services/forge.d/catalogues.sh)
# APPLY-ON: any
# CHECK-ON: any
# NEEDS: root
# AFTER: 25-directories

set -euo pipefail
# shellcheck source=../lib/provision-lib.sh
. "${PROVISION_LIB:?PROVISION_LIB non posé — lance via ./provision, pas le module nu}"

# ⚖ user 2026-09-04 (Q3, lot 6) : le conteneur converge ce cache à chaque boot — en prod. Le geste est
# du PRODUIT ; ce module l'appelle avec l'adresse de la forge et les deux racines du cache.
exec env \
  LCARS_MODULE_PROTOCOL="$(product_tree)/services/lib/module-protocol.sh" \
  LCARS_MODULE_TAG="${PROV_MODULE_TAG:-}" \
  FORGE_BASE_URL="${PROV_FORGE_URL:-}" \
  LCARS_PRIVATE_DIR="${PROV_TOKENS_DIR:-}" \
  LCARS_CATALOGUES_DIR="${PROV_CATALOGUES_DIR:-}" \
  LCARS_LEGACY_CATALOGUES_DIR="${PROV_LEGACY_CATALOGUES_DIR:-}" \
  bash "$(product_tree)/services/forge.d/catalogues.sh" "${1:?usage: 45-catalogues.sh <check|apply>}"
