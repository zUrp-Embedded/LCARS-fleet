#!/usr/bin/env bash
# SOURCE: deploy/modules.d/45-catalogues.sh
# AUTHOR: bob
# STARDATE: 2026-09-04
# STATUS: PROTO-V2 — le matériel des catalogues installés : un APPELANT du geste de forge du produit (fleet/services/forge.d/catalogues.sh)
# APPLY-ON: any
# CHECK-ON: any
# NEEDS: root
# AFTER: 25-directories

set -euo pipefail
# shellcheck source=../lib/provision-lib.sh
. "${PROVISION_LIB:?PROVISION_LIB non posé — lance via ./provision, pas le module nu}"

# ⚖ user 2026-09-04 (Q3, lot 6) : la boîte converge ce cache à chaque boot — en prod. Le geste est
# du PRODUIT ; ce module l'appelle avec l'adresse de la forge et les deux racines du cache.
exec env \
  LCARS_MODULE_PROTOCOL="$(repo_root)/fleet/services/lib/module-protocol.sh" \
  PROV_MODULE_TAG="$PROV_MODULE_TAG" \
  PROV_FORGE_URL="$PROV_FORGE_URL" \
  PROV_TOKENS_DIR="$PROV_TOKENS_DIR" \
  PROV_CATALOGUES_DIR="$PROV_CATALOGUES_DIR" \
  PROV_LEGACY_CATALOGUES_DIR="$PROV_LEGACY_CATALOGUES_DIR" \
  bash "$(repo_root)/fleet/services/forge.d/catalogues.sh" "${1:?usage: 45-catalogues.sh <check|apply>}"
