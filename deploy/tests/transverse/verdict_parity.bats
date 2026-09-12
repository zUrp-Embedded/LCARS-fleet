#!/usr/bin/env bats
# bats file_tags=unit
# SOURCE: deploy/tests/transverse/verdict_parity.bats
# AUTHOR: bob
# STARDATE: 2026-09-04
# STATUS: bats tests — le protocole du produit et la lib de l'installeur rendent les MEMES codes de verdict
#
# DI-09 (lot 11). Deux libs, deux dialectes (`PROV_*` chez l'installeur, `LCARS_*` chez le produit),
# et UN contrat de codes : apply 0 converge · 2 drift residuel · 1 echec ; check 0 conforme · 1 drift
# · 2 echec. `provision` lit ces codes sans savoir qui les a rendus (un module natif ou un appelant
# mince qui relaie un geste du produit) : un ecart d'une unite ferait lire un echec comme un drift.

load ../refute

setup() {
  REPO="$(cd "$BATS_TEST_DIRNAME/../../.." && pwd)"
  INSTALLER="$REPO/deploy/lib/provision-lib.sh"
  PRODUCT="$REPO/runtime/services/lib/module-protocol.sh"
  [ -f "$INSTALLER" ]
  [ -f "$PRODUCT" ]
}

# verdict <lib> <verbe> <failed> <drift> -> le code rendu
verdict_installer() { bash -c "set +e; . '$INSTALLER' >/dev/null 2>&1; PROV_FAILED=$2; PROV_DRIFT=$3; verdict_$1" 2>/dev/null; echo $?; }
verdict_product()   { bash -c "set +e; . '$PRODUCT' >/dev/null 2>&1; LCARS_FAILED=$2; LCARS_DRIFT=$3; verdict_$1" 2>/dev/null; echo $?; }

@test "apply : 0 converge · 2 drift · 1 echec — identiques des deux cotes, l'echec gagne sur le drift" {
  local f d i p
  for f in 0 1; do for d in 0 1; do
    i="$(verdict_installer apply $f $d)"; p="$(verdict_product apply $f $d)"
    [ "$i" = "$p" ] || { echo "apply failed=$f drift=$d : installeur=$i produit=$p" >&2; return 1; }
  done; done
  [ "$(verdict_product apply 0 0)" = 0 ]
  [ "$(verdict_product apply 0 1)" = 2 ]
  [ "$(verdict_product apply 1 0)" = 1 ]
  [ "$(verdict_product apply 1 1)" = 1 ]
}

@test "check : 0 conforme · 1 drift · 2 echec — identiques des deux cotes, l'echec gagne sur le drift" {
  local f d i p
  for f in 0 1; do for d in 0 1; do
    i="$(verdict_installer check $f $d)"; p="$(verdict_product check $f $d)"
    [ "$i" = "$p" ] || { echo "check failed=$f drift=$d : installeur=$i produit=$p" >&2; return 1; }
  done; done
  [ "$(verdict_product check 0 1)" = 1 ]
  [ "$(verdict_product check 1 0)" = 2 ]
  [ "$(verdict_product check 1 1)" = 2 ]
}

@test "les compteurs sont bien ceux que p_drift et p_fail incrementent, dans les deux dialectes" {
  grep -qE 'p_drift\(\).*PROV_DRIFT=\$\(\(PROV_DRIFT \+ 1\)\)' "$INSTALLER"
  grep -qE 'p_fail\(\).*PROV_FAILED=\$\(\(PROV_FAILED \+ 1\)\)' "$INSTALLER"
  grep -qE 'p_drift\(\).*LCARS_DRIFT=\$\(\(LCARS_DRIFT \+ 1\)\)' "$PRODUCT"
  grep -qE 'p_fail\(\).*LCARS_FAILED=\$\(\(LCARS_FAILED \+ 1\)\)' "$PRODUCT"
}
