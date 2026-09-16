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

@test "3 n'est le verdict d'aucun dialecte : armées, les deux gardes le rendent à une mort sous set -e" {
  run env PROVISION_RUN=1 bash -c "set -e; . '$INSTALLER' >/dev/null 2>&1; false"
  [ "$status" -eq 3 ]
  [[ "$output" == *"mort avant de rendre son verdict"* ]]
  run env LCARS_MODULE_RUN=1 bash -c "set -e; . '$PRODUCT' >/dev/null 2>&1; false"
  [ "$status" -eq 3 ]
  [[ "$output" == *"mort avant de rendre son verdict"* ]]
}

@test "la garde ne se pose QUE si le lanceur l'arme, et elle ne s'hérite pas" {
  run bash -c "set -e; . '$PRODUCT' >/dev/null 2>&1; false"
  [ "$status" -eq 1 ]
  run bash -c "set -e; . '$INSTALLER' >/dev/null 2>&1; false"
  [ "$status" -eq 1 ]
  # ⚠ ARMÉE PUIS DÉSARMÉE, ET L'ENFANT DOIT SOURCER LE PROTOCOLE POUR QUE ÇA VEUILLE DIRE QUELQUE
  # CHOSE : un enfant qui ne le source pas ne pose aucune garde de toute façon, et le cas serait
  # vert sans rien mesurer. Ici l'enfant le source : s'il héritait de LCARS_MODULE_RUN, son `exit 2`
  # deviendrait 3.
  run env LCARS_MODULE_RUN=1 bash -c "set -e; . '$PRODUCT' >/dev/null 2>&1; LCARS_VERDICT_RENDERED=1; bash -c \". '$PRODUCT' >/dev/null 2>&1; exit 2\""
  [ "$status" -eq 2 ] || { echo "$output" >&2; return 1; }
  refute_out "mort avant de rendre son verdict" <<<"$output"
  # le même pour l'installeur
  run env PROVISION_RUN=1 bash -c "set -e; . '$INSTALLER' >/dev/null 2>&1; PROV_VERDICT_RENDERED=1; bash -c \". '$INSTALLER' >/dev/null 2>&1; exit 2\""
  [ "$status" -eq 2 ] || { echo "$output" >&2; return 1; }
}

@test "un verdict rendu gagne sur la garde, des deux côtés — y compris le FATAL, qui reste 1" {
  run env LCARS_MODULE_RUN=1 bash -c "set -e; . '$PRODUCT' >/dev/null 2>&1; LCARS_DRIFT=1; verdict_apply"
  [ "$status" -eq 2 ]
  run env PROVISION_RUN=1 bash -c "set -e; . '$INSTALLER' >/dev/null 2>&1; PROV_DRIFT=1; verdict_apply"
  [ "$status" -eq 2 ]
  run env LCARS_MODULE_RUN=1 bash -c "set -e; . '$PRODUCT' >/dev/null 2>&1; p_die 'refus'"
  [ "$status" -eq 1 ]
  [[ "$output" == *"FATAL"* ]]
  refute_out "mort avant de rendre son verdict" <<<"$output"
}

# Les gestes du produit portent le MEME dispatch, et ils sont joués sous la garde (LCARS_MODULE_RUN) :
# un `exit 2` nu au lieu du FATAL y deviendrait 3, « mort avant verdict », pour un verbe mal tapé.
@test "un mode inconnu est refusé par chaque GESTE du produit, en FATAL (1) — jamais une mort, jamais un verdict" {
  local g name
  for g in "$REPO"/runtime/services/forge.d/*.sh; do
    name="$(basename "$g" .sh)"
    run env LCARS_MODULE_PROTOCOL="$PRODUCT" LCARS_MODULE_TAG="$name" LCARS_MODULE_RUN=1 \
        LCARS_PRIVATE_DIR="$BATS_TEST_TMPDIR" bash "$g" verbe-qui-n-existe-pas
    [ "$status" -eq 1 ] || { echo "$name : rc=$status — $output" >&2; return 1; }
    [[ "$output" == *"FATAL $name: mode inconnu"* ]] || { echo "$name : $output" >&2; return 1; }
    refute_out "mort avant de rendre son verdict" <<<"$output"
  done
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
