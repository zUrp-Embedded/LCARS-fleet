#!/usr/bin/env bash
# SOURCE: deploy/modules.d/63-forge-tokens.sh
# AUTHOR: bob
# STARDATE: 2026-09-04
# STATUS: PROTO-V2 — les jetons de rôle : un APPELANT du geste de forge du produit (fleet/services/forge.d/tokens.sh)
# APPLY-ON: any
# CHECK-ON: any
# NEEDS: root
# AFTER: 45-catalogues 48-forge-host 61-forge-structure

set -euo pipefail
# shellcheck source=../lib/provision-lib.sh
. "${PROVISION_LIB:?PROVISION_LIB non posé — lance via ./provision, pas le module nu}"

# ⚖ user 2026-09-04 (Q3, lot 6) : la boîte minte ses jetons à l'init de son instance — en prod. Le
# geste (sondes de la forge, modes de l'autorité, roster, mint par le minteur voisin) est du
# PRODUIT ; ce module l'appelle avec ce que l'installeur sait : la forge, le siège, le plancher de
# rôles de la lib (`PROV_ROLES`, que le geste fusionne avec ce que le release déclare), et la CLI.
: "${PROV_PASSWORDS_FILE:=$PROV_TOKENS_DIR/forge-role-passwords.json}"
exec env \
  LCARS_MODULE_PROTOCOL="$(repo_root)/fleet/services/lib/module-protocol.sh" \
  PROV_MODULE_TAG="$PROV_MODULE_TAG" \
  PROV_FORGE_URL="$PROV_FORGE_URL" \
  PROV_FORGE_ORG="$PROV_FORGE_ORG" \
  PROV_TOKENS_DIR="$PROV_TOKENS_DIR" \
  PROV_MASTER_TOKEN_FILE="$PROV_MASTER_TOKEN_FILE" \
  PROV_FORGE_SEED_FILE="$PROV_FORGE_SEED_FILE" \
  PROV_PASSWORDS_FILE="$PROV_PASSWORDS_FILE" \
  PROV_SYSTEM_ACCOUNT="$PROV_SYSTEM_ACCOUNT" \
  PROV_SYSTEM_TOKEN_FILE="$PROV_SYSTEM_TOKEN_FILE" \
  PROV_AUTHORITY_USER="$PROV_AUTHORITY_USER" \
  PROV_CATALOGUES_DIR="$PROV_CATALOGUES_DIR" \
  PROV_ROLES="$PROV_ROLES" \
  PROV_HUMAN="$PROV_HUMAN" \
  LCARS_CLI="${PROV_LCARS_CLI:-$PROV_LINK_DIR/lcars}" \
  bash "$(repo_root)/fleet/services/forge.d/tokens.sh" "${1:?usage: 63-forge-tokens.sh <check|apply>}"
