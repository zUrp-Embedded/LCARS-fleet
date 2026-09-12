#!/usr/bin/env bats
# bats file_tags=integration
# SOURCE: deploy/tests/admiral_skill.bats
# AUTHOR: bob
# STARDATE: 2026-09-12
# STATUS: témoins de runtime/services/admiral/skills/system-issues/list.sh, la lecture de la boîte de réception d'admiral
#
# La cible est hors de deploy/ ; le module 45-seat-skill la pose chez le siège. curl et le client
# d'autorité sont des doublures.

setup() {
  LIST="$BATS_TEST_DIRNAME/../../runtime/services/admiral/skills/system-issues/list.sh"; [ -x "$LIST" ]
  BIN="$BATS_TEST_TMPDIR/bin"; mkdir -p "$BIN"; export PATH="$BIN:$PATH"
  cat > "$BIN/curl" <<'EOS'
#!/usr/bin/env bash
for a in "$@"; do case "$a" in
  *issues*) echo '[{"number":12,"created_at":"2026-08-19T00:00:00Z","title":"pod en échec"}]'; exit 0;;
  *pulls*)  echo '[{"number":7,"created_at":"2026-08-19T00:00:00Z","title":"[toolchain] python","base":{"ref":"tool_request"}}]'; exit 0;;
esac; done
exit 1
EOS
  chmod +x "$BIN/curl"
  export LCARS_FORGE_URL="http://forge.test"
  export LCARS_AUTHORITY_ASK_BIN="$BATS_TEST_TMPDIR/ask"
  printf '#!/usr/bin/env bash\nprintf "TOK\\n"\n' > "$LCARS_AUTHORITY_ASK_BIN"; chmod +x "$LCARS_AUTHORITY_ASK_BIN"
}

@test "les issues et les demandes d'outillage sont listées avec leur numéro et leur titre" {
  run "$LIST"
  [ "$status" -eq 0 ]
  [[ "$output" == *"#12"*"pod en échec"* ]]
  [[ "$output" == *"!7"*"[toolchain] python"* ]]
}

@test "sans jeton de forge : refus nommé, pas une liste vide" {
  printf '#!/usr/bin/env bash\necho "autorité : refus" >&2\nexit 1\n' > "$LCARS_AUTHORITY_ASK_BIN"
  run "$LIST"
  [ "$status" -ne 0 ]
  [[ "$output" == *"pas de jeton de forge"* ]]
}

@test "client d'autorité absent : le refus le nomme" {
  export LCARS_AUTHORITY_ASK_BIN="$BATS_TEST_TMPDIR/jamais-posé"
  run "$LIST"
  [ "$status" -ne 0 ]
  [[ "$output" == *"client d'autorite absent"* ]]
}
