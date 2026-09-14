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

prov_geste ops-branch "${1:?usage: 65-ops-branch.sh <check|apply>}"
