#!/usr/bin/env bats
# SOURCE: fleet/test/shell_gate.bats
# AUTHOR: consultant
# STARDATE: 2026-08-30
# STATUS: temoins du filet hors-mix lui-meme — ce qu'il fait d'une machine qui n'a pas ses outils

setup() {
  GATE="$BATS_TEST_DIRNAME/shell_gate.sh"
  [ -f "$GATE" ]
  mkdir -p "$BATS_TEST_TMPDIR/vide"
}

@test "le shell_gate SURVIT a l'absence de shellcheck — il l'annonce, il ne meurt pas en silence" {
  # Sous `set -e`, `SC_VERSION="$(command -v shellcheck … && …)"` tuait le script quand shellcheck
  # manque : la substitution rend non-zero, l'affectation en herite, et le gate mourait apres
  # « bats : OK » sans une ligne — avant meme d'annoncer « HORS GATE ». Banc .63 (Ubuntu neuf,
  # 2026-08-30) : trois runs rouges de 60-deploy, tests tous verts, aucun diagnostic.
  # On rejoue la sonde EXTRAITE du script, sous errexit, avec un PATH sans shellcheck.
  local snippet
  snippet="$(sed -n '/^SC_VERSION=""$/,/^command -v shellcheck >\/dev\/null 2>&1 && SC_VERSION=/p' "$GATE")"
  [ -n "$snippet" ]
  [ "$(printf '%s\n' "$snippet" | wc -l)" -eq 2 ]
  run env -i PATH="$BATS_TEST_TMPDIR/vide" /bin/bash -c "set -euo pipefail; $snippet; printf 'survecu:[%s]\n' \"\$SC_VERSION\""
  [ "$status" -eq 0 ]
  [[ "$output" == *"survecu:[]"* ]]
}

@test "shellcheck absent et LCARS_SHELL_LINT vide : le pas se declare HORS GATE, et rien ne rougit" {
  # Le pas est desactive par defaut (dette connue, ⚖ user 2026-08-29) ; absent ou present, il doit le
  # DIRE. On lit la branche telle qu'elle est ecrite : la condition sur la variable vient en premier.
  run sed -n '/^if \[\[ -z "\${LCARS_SHELL_LINT:-}" \]\]; then$/,/^elif/p' "$GATE"
  [ "$status" -eq 0 ]
  [[ "$output" == *"HORS GATE"* ]]
}
