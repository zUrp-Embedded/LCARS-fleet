#!/usr/bin/env bats
# bats file_tags=integration
# SOURCE: deploy/tests/admiral_skill.bats
# AUTHOR: bob
# STARDATE: 2026-09-12
# STATUS: témoins de runtime/services/admiral/skills/system-issues/list.sh, la lecture de la boîte de réception d'admiral
#
# La cible est hors de deploy/ ; le module 45-seat-skill la pose chez le siège. Le client d'autorité
# rend le jeton système ; curl est une doublure qui n'accepte que la configuration sur stdin (-K -)
# portant ce jeton, et note son argv.

load refute

setup() {
  LIST="$BATS_TEST_DIRNAME/../../runtime/services/admiral/skills/system-issues/list.sh"; [ -x "$LIST" ]
  BIN="$BATS_TEST_TMPDIR/bin"; mkdir -p "$BIN"; export PATH="$BIN:$PATH"
  export CALLS="$BATS_TEST_TMPDIR/calls"; : > "$CALLS"
  cat > "$BIN/curl" <<'EOF'
#!/usr/bin/env bash
echo "CURL $*" >> "$CALLS"
cfg=""; url=""
while [[ $# -gt 0 ]]; do
  case "$1" in -K) [[ "$2" == - ]] && cfg="$(cat)"; shift ;; http*) url="$1" ;; esac
  shift
done
[[ "$cfg" == *'Authorization: token TOK-SYSTEME'* ]] || { echo "curl: pas de jeton système dans la configuration" >&2; exit 22; }
case "$url" in
  *issues*) echo '[{"number":12,"created_at":"2026-08-19T00:00:00Z","title":"pod en échec"}]' ;;
  *pulls*)  echo '[{"number":7,"created_at":"2026-08-19T00:00:00Z","title":"[toolchain] python","base":{"ref":"tool_request"}}]' ;;
  *) exit 22 ;;
esac
EOF
  chmod +x "$BIN/curl"
  export LCARS_FORGE_URL="http://forge.test"
  export LCARS_AUTHORITY_ASK_BIN="$BATS_TEST_TMPDIR/ask"
  printf '#!/usr/bin/env bash\nprintf "TOK-SYSTEME\\n"\n' > "$LCARS_AUTHORITY_ASK_BIN"; chmod +x "$LCARS_AUTHORITY_ASK_BIN"
}

@test "les issues et les demandes d'outillage sont listées avec leur numéro et leur titre, sous le jeton système" {
  run "$LIST"
  [ "$status" -eq 0 ] || { echo "$output"; return 1; }
  [[ "$output" == *"#12"*"pod en échec"* ]]
  [[ "$output" == *"!7"*"[toolchain] python"* ]]
  [ "$(grep -c '^CURL ' "$CALLS")" -eq 2 ]
}

@test "le jeton ne passe jamais par l'argv de curl : configuration sur stdin, aucun -H Authorization" {
  run "$LIST"
  [ "$status" -eq 0 ]
  refute grep -q 'TOK-SYSTEME' "$CALLS"
  refute grep -qi 'Authorization' "$CALLS"
  [ "$(grep -c -- ' -K - ' "$CALLS")" -eq 2 ]
}

@test "sans jeton de forge : refus nommé, pas une liste vide, curl n'est pas appelé" {
  printf '#!/usr/bin/env bash\necho "autorité : refus" >&2\nexit 1\n' > "$LCARS_AUTHORITY_ASK_BIN"
  run "$LIST"
  [ "$status" -ne 0 ]
  [[ "$output" == *"pas de jeton de forge"* ]]
  [ ! -s "$CALLS" ]
}

@test "client d'autorité absent : le refus le nomme" {
  export LCARS_AUTHORITY_ASK_BIN="$BATS_TEST_TMPDIR/jamais-posé"
  run "$LIST"
  [ "$status" -ne 0 ]
  [[ "$output" == *"client d'autorite absent"* ]]
}
