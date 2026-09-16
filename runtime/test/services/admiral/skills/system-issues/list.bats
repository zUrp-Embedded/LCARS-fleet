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
# une lecture sans configuration est anonyme : servie seulement si la doublure dit le dépôt public
if [[ -z "$cfg" ]]; then
  [[ "${STUB_DEPOT_PUBLIC:-}" == 1 ]] || { echo "curl: (22) The requested URL returned error: 404" >&2; exit 22; }
else
  [[ "$cfg" == *'Authorization: token TOK-SYSTEME'* ]] || { echo "curl: pas de jeton système dans la configuration" >&2; exit 22; }
fi
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

@test "l'autorité refuse le jeton (le siège, hors de la team humans) : la lecture se fait en anonyme, et le script le dit" {
  printf '#!/usr/bin/env bash\necho "autorité : refus" >&2\nexit 1\n' > "$LCARS_AUTHORITY_ASK_BIN"
  STUB_DEPOT_PUBLIC=1 run "$LIST"
  [ "$status" -eq 0 ] || { echo "$output"; return 1; }
  [[ "$output" == *"pas de jeton de forge pour ce compte"*"lecture anonyme de lcars/_ops"* ]]
  [[ "$output" == *"#12"*"pod en échec"* ]]
  [[ "$output" == *"!7"*"[toolchain] python"* ]]
  refute grep -q -- ' -K ' "$CALLS"
}

@test "sans jeton, un dépôt qui ne se lit pas en anonyme : refus nommé et code non nul, jamais une liste vide" {
  printf '#!/usr/bin/env bash\necho "autorité : refus" >&2\nexit 1\n' > "$LCARS_AUTHORITY_ASK_BIN"
  run "$LIST"
  [ "$status" -eq 1 ]
  [[ "$output" == *"lecture anonyme refusée : lcars/_ops ne se lit pas sans jeton"* ]]
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
  [ "$(grep -c 'http://forge.poste:3000/api/v1/repos/lcars/_ops/' "$CALLS")" -eq 2 ]
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

@test "aucune adresse : le refus nomme le fichier cherché, le geste de chaque rail, et curl n'est pas appelé" {
  # La racine privée pointe sur un dossier VIDE : le cas se joue aussi sur un poste posé, dont
  # /opt/lcars/var/tokens/forge.url donnerait une adresse au défaut.
  unset LCARS_FORGE_URL FORGE_BASE_URL
  export LCARS_PRIVATE_DIR="$BATS_TEST_TMPDIR/tokens-vide"; mkdir -p "$LCARS_PRIVATE_DIR"
  run "$LIST"
  [ "$status" -ne 0 ]
  [[ "$output" == *"ni $LCARS_PRIVATE_DIR/forge.url lisible"* ]]
  [[ "$output" == *"Sur un poste, « deploy/workstation up » écrit ce fichier ; dans un conteneur, son démarrage l'écrit depuis FORGE_BASE_URL"* ]]
  [ ! -s "$CALLS" ]
}

@test "le défaut du fichier est le répertoire des jetons de l'installation, celui que l'init du conteneur écrit" {
  # Une session ssh ne porte pas LCARS_PRIVATE_DIR : le défaut de list.sh et celui du protocole des
  # modules (que l'init applique) doivent désigner le même dossier.
  local defaut_list defaut_protocole
  defaut_list="$(sed -n 's|^FORGE_URL_FILE="\${LCARS_PRIVATE_DIR:-\([^}]*\)}/forge.url"$|\1|p' "$LIST")"
  defaut_protocole="$(sed -n 's|^: "\${LCARS_PRIVATE_DIR:=\([^}]*\)}"$|\1|p' "$BATS_TEST_DIRNAME/../../../../../services/lib/module-protocol.sh")"
  [ -n "$defaut_list" ]
  [ "$defaut_list" = "$defaut_protocole" ]
}
