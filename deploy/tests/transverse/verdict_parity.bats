#!/usr/bin/env bats
# bats file_tags=unit
# SOURCE: deploy/tests/transverse/verdict_parity.bats
# AUTHOR: bob
# STARDATE: 2026-09-04
# STATUS: bats tests — le protocole du produit et la lib de l'installeur rendent les MEMES codes de verdict

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

@test "3 n'est le verdict d'aucun dialecte : la garde de l'installeur le rend à une mort sous set -e, le protocole seul rend le code brut" {
  run env PROVISION_RUN=1 bash -c "set -e; . '$INSTALLER' >/dev/null 2>&1; false"
  [ "$status" -eq 3 ]
  # le protocole ne pose aucune garde : le lanceur de gestes (prov_geste) la pose pour lui
  run bash -c "set -e; . '$PRODUCT' >/dev/null 2>&1; false"
  [ "$status" -eq 1 ]
}

@test "un mode inconnu est refusé par chaque module qui porte son dispatch, en FATAL avant toute mesure : jamais une fonction de la lib jouée sous son nom" {
  local m
  for m in "$REPO"/deploy/modules.d/*.sh; do
    # les appelants de prov_geste confient le verbe au lanceur de la lib
    ! grep -q '^prov_geste ' "$m" || continue
    m="$(basename "$m" .sh)"
    run env LCARS_DECOR_ROOT="$BATS_TEST_TMPDIR/decor" PROVISION_LIB="$INSTALLER" PROVISION_MODULE="$m" PROVISION_RUN=1 \
        PROV_SUBSTRATE=linux bash "$REPO/deploy/modules.d/$m.sh" p_ok
    [ "$status" -eq 1 ] || { echo "$m : rc=$status — $output" >&2; return 1; }
    [[ "$output" == *"mode inconnu"* ]] || { echo "$m : $output" >&2; return 1; }
    [[ "$output" != *"OK    "* ]] || { echo "$m a mesuré avant de refuser : $output" >&2; return 1; }
  done
}
