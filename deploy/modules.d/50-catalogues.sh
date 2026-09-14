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

prov_geste catalogues "${1:?usage: 50-catalogues.sh <check|apply>}"
