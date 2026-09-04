#!/usr/bin/env bash
# SOURCE: deploy/modules.d/66-deck-oidc.sh
# AUTHOR: bob
# STARDATE: 2026-09-04
# STATUS: PROTO-V2 — le client OAuth2 du deck : un APPELANT du geste de forge du produit (runtime/services/forge.d/deck-oidc.sh)
# APPLY-ON: any
# CHECK-ON: any
# NEEDS: root
# AFTER: 21-service-accounts 63-forge-tokens

set -euo pipefail
# shellcheck source=../lib/provision-lib.sh
. "${PROVISION_LIB:?PROVISION_LIB non posé — lance via ./provision, pas le module nu}"

# ⚖ user 2026-09-04 (Q3, lot 6) : la boîte pose ce client à l'init de son instance — en prod. Le
# geste est du PRODUIT ; ce module l'appelle avec ce que l'installeur sait de mieux que lui :
# l'adresse ANNONCÉE (le poste connaît WSL et son mode NAT, le geste ne le mesure pas), les deux
# adresses de la forge, le port et les entrées du deck, le fichier de config et son groupe.
advertise_addr "${PROV_DECK_BIND:-0.0.0.0}"
exec env \
  LCARS_MODULE_PROTOCOL="$(product_tree)/services/lib/module-protocol.sh" \
  LCARS_MODULE_TAG="${PROV_MODULE_TAG:-}" \
  FORGE_BASE_URL="${PROV_FORGE_URL:-}" \
  FORGE_PUBLIC_URL="${PROV_FORGE_PUBLIC_URL:-}" \
  LCARS_SYSTEM_TOKEN_FILE="${PROV_SYSTEM_TOKEN_FILE:-}" \
  LCARS_SYSTEM_USER="${PROV_SYSTEM_USER:-lcars-system}" \
  LCARS_SYSTEM_GROUP="${PROV_SYSTEM_GROUP:-${PROV_SYSTEM_USER:-lcars-system}}" \
  LCARS_LANDING_PORT="${PROV_DECK_PORT:-}" \
  LCARS_DECK_BIND="${PROV_DECK_BIND:-0.0.0.0}" \
  LCARS_DECK_ORIGINS="${PROV_DECK_ORIGINS:-}" \
  LCARS_DECK_OIDC_FILE="${PROV_DECK_OIDC_FILE:-}" \
  LCARS_ADVERTISE="${PROV_ADVERTISE:-}" \
  LCARS_ADVERTISE_WHY="${PROV_ADVERTISE_WHY:-}" \
  bash "$(product_tree)/services/forge.d/deck-oidc.sh" "${1:?usage: 66-deck-oidc.sh <check|apply>}"
