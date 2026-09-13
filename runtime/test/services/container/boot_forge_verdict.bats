#!/usr/bin/env bats
# SOURCE: runtime/test/services/container/boot_forge_verdict.bats
# AUTHOR: bob
# STARDATE: 2026-09-14
# STATUS: bats tests for container/boot.sh — le verdict des gestes de forge publié dans lcars-forge.rc

setup() {
  SRC="$BATS_TEST_DIRNAME/../../../services/container/boot.sh"
  [ -f "$SRC" ]
  export LCARS_FORGE_D="$BATS_TEST_TMPDIR/forge.d"; mkdir -p "$LCARS_FORGE_D"
  export LCARS_FORGE_RC_FILE="$BATS_TEST_TMPDIR/forge.rc"
  BLOC="$BATS_TEST_TMPDIR/bloc.sh"
  {
    printf '%s\n' 'say() { echo "[boot] $*"; }' 'MODULE_PROTOCOL=/dev/null' 'LCARS_ADMIRAL=admiral'
    sed -n '/^RC_FILE=/,/^done$/p' "$SRC"
    sed -n '/^publier_verdicts() {/,/^}/p' "$SRC"
    printf '%s\n' 'publier_verdicts'
  } > "$BLOC"
}

gestes() { # gestes <rc tokens> <rc catalogues> <rc ops-branch> <rc deck-oidc>
  local g rc i=1
  for g in tokens catalogues ops-branch deck-oidc; do
    rc="${!i}"; i=$((i + 1))
    printf '#!/usr/bin/env bash\nexit %s\n' "$rc" > "$LCARS_FORGE_D/$g.sh"
  done
}

@test "le bloc s'extrait, et il porte la boucle et la publication" {
  grep -q 'for gesture in' "$BLOC"
  grep -q 'publier_verdicts' "$BLOC"
}

@test "tous les gestes convergés : le verdict publié est 0" {
  gestes 0 0 0 0
  run bash -c "set -euo pipefail; init_rc=0; . '$BLOC'"
  [ "$(cat "$LCARS_FORGE_RC_FILE")" = 0 ]
}

@test "un geste en drift : le verdict publié est 2, pas 0" {
  gestes 0 2 0 0
  run bash -c "set -euo pipefail; init_rc=0; . '$BLOC'"
  [ "$(cat "$LCARS_FORGE_RC_FILE")" = 2 ]
}

@test "un init en drift, gestes convergés : le verdict publié est 2" {
  gestes 0 0 0 0
  run bash -c "set -euo pipefail; init_rc=2; . '$BLOC'"
  [ "$(cat "$LCARS_FORGE_RC_FILE")" = 2 ]
}

@test "un échec l'emporte sur un drift rencontré après lui comme avant lui" {
  gestes 2 1 2 0
  run bash -c "set -euo pipefail; init_rc=0; . '$BLOC'"
  [ "$(cat "$LCARS_FORGE_RC_FILE")" = 1 ]
}
