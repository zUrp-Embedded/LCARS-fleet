#!/usr/bin/env bats
# SOURCE: runtime/test/services/forge.d/tokens_master_state.bats
# AUTHOR: bob
# STARDATE: 2026-09-15
# STATUS: témoins de forge.d/tokens.sh — l'état du jeton master aux deux sites qui le lisent (autorité de création, runners CI)
#
# POURQUOI CE FICHIER (C3). Les deux sondes testaient `-r` seul et annonçaient « absent » un jeton
# présent que le compte du doctor ne peut pas ouvrir : sur un poste, `forge-master.token` est 0600 à
# lcars-authority, et `deploy/workstation doctor` joué par un humain disait « pas d'autorité de
# création » sur une machine qui l'a. Un fichier vide, lui, passait pour une autorité présente.
#
# CINQ ÉTATS, ET CHACUN SON MOT : présent, vide, illisible (propriétaire et mode mesurés), absent,
# non mesurable (un dossier du chemin n'est pas traversable). Les états illisible et non mesurable se
# construisent sans root — mode 000 dans le dossier du test — et ne veulent rien dire sous root, qui
# ouvre tout : ces témoins se sautent alors en le disant.
#
# ON EXECUTE LE MODULE, on ne le source pas : patron des autres témoins de `forge.d`.

setup() {
  MODULE="$BATS_TEST_DIRNAME/../../../services/forge.d/tokens.sh"
  [ -f "$MODULE" ]

  BIN="$BATS_TEST_TMPDIR/bin"
  mkdir -p "$BIN" "$BATS_TEST_TMPDIR/tokens"

  export LCARS_MODULE_PROTOCOL="$BATS_TEST_DIRNAME/../../../services/lib/module-protocol.sh"
  export LCARS_MODULE_TAG=63-forge-tokens
  printf '%s\n' '#!/usr/bin/env bash' '[[ "$1" == tool ]] && shift' '[[ "$1" == roles-tfvars ]] && echo "{\"roles\":[\"fleet_engineer\"],\"system_roles\":[\"system_architect\"]}"' 'exit 0' > "$BIN/lcars"
  chmod +x "$BIN/lcars"; export LCARS_CLI="$BIN/lcars"
  export FORGE_BASE_URL="http://forge.test"
  export LCARS_LOGIN=""
  export LCARS_PRIVATE_DIR="$BATS_TEST_TMPDIR/tokens"
  export LCARS_CATALOGUES_DIR="$BATS_TEST_TMPDIR/nocat"
  export LCARS_MASTER_TOKEN_FILE="$BATS_TEST_TMPDIR/tokens/forge-master.token"
  export PATH="$BIN:$PATH"

  # La forge ne rend la liste des runners qu'à un appel AUTHENTIFIÉ : un jeton vide part sans en-tête
  # et reçoit un refus, comme sur une vraie forge.
  cat > "$BIN/curl" <<'EOF'
#!/usr/bin/env bash
url="" cfg=""
while [[ $# -gt 0 ]]; do
  case "$1" in -K) [[ "$2" == - ]] && cfg="$(cat)"; shift ;; http*) url="$1" ;; esac
  shift
done
case "$url" in
  */api/v1/version)               printf '{"version":"1.26.1"}' ;;
  */api/v1/admin/actions/runners) [[ "$cfg" == *'Authorization: token '?* ]] || exit 22
                                  printf '{"total_count":1,"runners":[{"name":"r","labels":[{"name":"shell"}]}]}' ;;
  *)                              exit 22 ;;
esac
exit 0
EOF
  chmod +x "$BIN/curl"
}

teardown() {
  # un dossier en 000 ne se nettoie pas sans lui rendre son mode
  chmod -R u+rwx "$BATS_TEST_TMPDIR/tokens" 2>/dev/null || true
}

sans_root() {
  [[ "$EUID" -ne 0 ]] || skip "sous root tout fichier s'ouvre : l'état illisible ne se construit pas"
}

@test "jeton présent et lisible : autorité présente, runners sondés" {
  printf 'MASTERTOK' > "$LCARS_MASTER_TOKEN_FILE"
  run bash "$MODULE" check
  [[ "$output" == *"autorité de création présente ($LCARS_MASTER_TOKEN_FILE)"* ]]
  [[ "$output" == *"1 runner(s) CI"* ]]
}

@test "jeton absent : les deux sites disent absent, et rien d'autre" {
  rm -f "$LCARS_MASTER_TOKEN_FILE"
  run bash "$MODULE" check
  [[ "$output" == *"pas d'autorité de création ($LCARS_MASTER_TOKEN_FILE absent)"* ]]
  [[ "$output" == *"jeton master absent : $LCARS_MASTER_TOKEN_FILE"* ]]
  [[ "$output" != *"illisible"* ]]
  [[ "$output" != *"VIDE"* ]]
}

@test "jeton présent mais illisible : ni absent ni présent — le propriétaire, le mode et le geste sont dits" {
  sans_root
  printf 'MASTERTOK' > "$LCARS_MASTER_TOKEN_FILE"
  chmod 000 "$LCARS_MASTER_TOKEN_FILE"
  run bash "$MODULE" check
  local moi; moi="$(id -un)"
  [[ "$output" == *"autorité de création présent mais illisible pour $moi ($LCARS_MASTER_TOKEN_FILE, $moi:$(id -gn), mode 0)"* ]]
  [[ "$output" == *"runners CI non sondables — jeton master présent mais illisible"* ]]
  [[ "$output" == *"relance la sonde sous sudo"* ]]
  [[ "$output" != *"pas d'autorité de création"* ]]
  [[ "$output" != *"jeton master absent"* ]]
}

@test "jeton vide : ce n'est pas une autorité présente, et les runners ne sont pas sondés sous un en-tête vide" {
  : > "$LCARS_MASTER_TOKEN_FILE"
  run bash "$MODULE" check
  [[ "$output" == *"autorité de création VIDE ($LCARS_MASTER_TOKEN_FILE)"* ]]
  [[ "$output" == *"jeton master VIDE : $LCARS_MASTER_TOKEN_FILE"* ]]
  [[ "$output" != *"autorité de création présente"* ]]
  [[ "$output" != *"l'API admin n'a pas repondu"* ]]
}

@test "dossier non traversable : non mesurable, jamais absent" {
  sans_root
  printf 'MASTERTOK' > "$LCARS_MASTER_TOKEN_FILE"
  chmod 000 "$BATS_TEST_TMPDIR/tokens"
  run bash "$MODULE" check
  [[ "$output" == *"autorité de création NON MESURABLE ici"* ]]
  [[ "$output" == *"runners CI non sondables — jeton master NON MESURABLE ici"* ]]
  [[ "$output" != *"pas d'autorité de création"* ]]
  [[ "$output" != *"jeton master absent"* ]]
}
