#!/usr/bin/env bats
# SOURCE: runtime/test/services/admiral/skills/system-issues/list.bats
# AUTHOR: bob
# STARDATE: 2026-09-12
# STATUS: témoins de runtime/services/admiral/skills/system-issues/list.sh, la lecture de la boîte de réception d'admiral

load ../../../../support/refute

setup() {
  LIST="$BATS_TEST_DIRNAME/../../../../../services/admiral/skills/system-issues/list.sh"; [ -x "$LIST" ]
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
  [[ "$output" == *"client d'autorité absent"* ]]
}

# ─── L'ADRESSE DE LA FORGE, SANS LA VARIABLE DU TÉMOIN ─────────────────────────────────────────
# La session du siège ne porte pas LCARS_FORGE_URL : les cas ci-dessous jouent les défauts. Le défaut
# d'origine lisait /home/lcars/tokens/forge.url, un chemin qu'aucun rail ne pose.

@test "sans variable : l'adresse vient de forge.url du répertoire des jetons (le poste)" {
  unset LCARS_FORGE_URL FORGE_BASE_URL
  export LCARS_PRIVATE_DIR="$BATS_TEST_TMPDIR/tokens"; mkdir -p "$LCARS_PRIVATE_DIR"
  printf 'http://forge.poste:3000\n' > "$LCARS_PRIVATE_DIR/forge.url"
  run "$LIST"
  [ "$status" -eq 0 ] || { echo "$output"; return 1; }
  [ "$(grep -c 'http://forge.poste:3000/api/v1/repos/fleet/lcars/' "$CALLS")" -eq 2 ]
}

@test "FORGE_BASE_URL de l'environnement (le conteneur) passe avant le fichier" {
  unset LCARS_FORGE_URL
  export FORGE_BASE_URL="http://gitea:3000"
  export LCARS_PRIVATE_DIR="$BATS_TEST_TMPDIR/tokens"; mkdir -p "$LCARS_PRIVATE_DIR"
  printf 'http://forge.poste:3000\n' > "$LCARS_PRIVATE_DIR/forge.url"
  run "$LIST"
  [ "$status" -eq 0 ] || { echo "$output"; return 1; }
  [ "$(grep -c 'http://gitea:3000/api/v1/' "$CALLS")" -eq 2 ]
}

@test "aucune adresse : le refus nomme le fichier par défaut du poste et la variable du conteneur, curl n'est pas appelé" {
  [[ ! -e /opt/lcars/var/tokens/forge.url ]] || skip "cette machine porte /opt/lcars/var/tokens/forge.url : le défaut y trouverait une adresse"
  unset LCARS_FORGE_URL FORGE_BASE_URL LCARS_PRIVATE_DIR
  run "$LIST"
  [ "$status" -ne 0 ]
  [[ "$output" == *"/opt/lcars/var/tokens/forge.url"* ]]
  [[ "$output" == *"FORGE_BASE_URL"* ]]
  [ ! -s "$CALLS" ]
}
