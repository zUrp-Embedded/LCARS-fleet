#!/usr/bin/env bats
# SOURCE: runtime/test/shell_gate.bats
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

@test "shellcheck absent est un ECHEC NOMME, plus une dette toleree" {
  # ⚠ CE TEMOIN A CHANGE DE SUJET PARCE QUE LE SUJET A CHANGE. Il epinglait « le pas se declare
  # HORS GATE, et rien ne rougit » — vrai tant que shellcheck etait hors du gate (⚖ user
  # 2026-08-29). Le plancher l y a fait rentrer : un binaire absent ne laisse plus des fichiers
  # NON audites derriere un message tranquille, il arrete la porte. Garder l ancienne assertion
  # aurait verrouille l etat d avant contre celui d apres — un temoin defendant la dette qu on
  # venait de payer, et vert pour cela.
  #
  # On lit la branche telle qu elle est ecrite : c est l ABSENCE du binaire qui decide, et elle
  # decide AVANT toute question de severite ou de perimetre.
  run sed -n '/^if \[\[ -z "\$SC_VERSION" \]\]; then$/,/^elif/p' "$GATE"
  [ "$status" -eq 0 ]
  [[ "$output" == *"ECHEC: shellcheck absent"* ]]
  [[ "$output" == *"GATE_FAIL=1"* ]]
}
