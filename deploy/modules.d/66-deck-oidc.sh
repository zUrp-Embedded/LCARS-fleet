#!/usr/bin/env bash
# SOURCE: deploy/modules.d/66-deck-oidc.sh
# AUTHOR: bob
# STARDATE: 2026-09-04
# STATUS: le client OAuth2 du deck : un APPELANT du geste de forge du produit (runtime/services/forge.d/deck-oidc.sh)
# APPLY-ON: wsl linux
# CHECK-ON: wsl linux
# NEEDS: root
# AFTER: 21-service-accounts 63-forge-tokens

set -euo pipefail
# shellcheck source=../lib/provision-lib.sh
. "${PROVISION_LIB:?PROVISION_LIB non posé — ce module se joue par ./provision, pas nu}"

advertise_addr
prov_geste deck-oidc "${1:?usage: 66-deck-oidc.sh <check|apply>}"
