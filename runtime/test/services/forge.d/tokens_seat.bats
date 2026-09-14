#!/usr/bin/env bats
# SOURCE: runtime/test/services/forge.d/tokens_seat.bats
# AUTHOR: bob
# STARDATE: 2026-09-15
# STATUS: témoins de forge.d/tokens.sh — le compte que nomme LCARS_LOGIN est le siège, pas une personne de fleet
#
# POURQUOI CE FICHIER. Les deux rails posent `LCARS_LOGIN` au nom du siège — l'admin du système : le
# compte qui installe sur un poste (`PROV_HUMAN`), le siège résolu par l'init dans le conteneur
# (`/run/lcars-seat.login`). La fleet lui est fermée (GUARD B), le convergeur ne le matérialise pas
# (GUARD A). Le geste le sondait pourtant comme une personne à placer : « n'est membre d'aucune team —
# un propriétaire d'org l'ajoutera (team humans) », « l'onboarding projet le refusera d'ici là », et
# « rends ton adhésion visible » quand il en avait une. Trois consignes qui envoyaient l'opérateur
# mettre l'admin du système dans la team des humains de fleet.
#
# CE QUE LES TÉMOINS TIENNENT : son compte se sonde, son adhésion jamais, et aucune phrase ne le
# rapproche de la team humans.

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
  export LCARS_LOGIN="zoe"
  export LCARS_PRIVATE_DIR="$BATS_TEST_TMPDIR/tokens"
  export LCARS_CATALOGUES_DIR="$BATS_TEST_TMPDIR/nocat"
  # le jeton système lisible : sans lui les adhésions ne se sondent pas, et le témoin ne mesurerait rien
  printf 'SYSTOK' > "$BATS_TEST_TMPDIR/tokens/system_starfleet.gitea_token"
  export LCARS_ROLE_TOKENS_SCRIPT="$BATS_TEST_TMPDIR/a4.sh"
  printf '#!/usr/bin/env bash\nexit 0\n' > "$LCARS_ROLE_TOKENS_SCRIPT"; chmod +x "$LCARS_ROLE_TOKENS_SCRIPT"
  export PATH="$BIN:$PATH"
}

# stub_forge <zoe existe : oui|non> <adhésion de zoe : absent|hidden|visible>
# Les comptes machine existent et sont membres visibles : seule la place du siège varie.
stub_forge() {
  cat > "$BIN/curl" <<EOF
#!/usr/bin/env bash
url="" w=0 o=0
while [[ \$# -gt 0 ]]; do
  case "\$1" in -K) [[ "\$2" == - ]] && cat >/dev/null; shift ;; -w) w=1; shift ;; -o) o=1; shift ;; http*) url="\$1" ;; esac
  shift
done
code() { [[ \$w -eq 1 ]] && printf '%s' "\$1"; return 0; }
case "\$url" in
  */api/v1/version)              printf '{"version":"1.26.1"}' ;;
  */user/sign_up)                printf '<form><input name="user_name"></form>' ;;
  */api/v1/users/zoe)            [[ '$1' == oui ]] || exit 22; [[ \$o -eq 1 ]] || printf '{"login":"zoe","restricted":false}' ;;
  */api/v1/users/*)              [[ \$o -eq 1 ]] || printf '{}' ;;
  */orgs/fleet/members/zoe)      case '$2' in absent) code 404 ;; *) code 204 ;; esac ;;
  */orgs/fleet/public_members/zoe) case '$2' in visible) code 204 ;; *) code 404 ;; esac ;;
  */orgs/fleet/members/*|*/orgs/fleet/public_members/*) code 204 ;;
  *)                             exit 22 ;;
esac
exit 0
EOF
  chmod +x "$BIN/curl"
}

@test "siège présent sur la forge, hors de l'org : son compte est dit, aucune team ne lui est promise" {
  stub_forge oui absent
  run bash "$MODULE" check
  [[ "$output" == *"compte forge du siège « zoe », l'admin du système"* ]]
  [[ "$output" == *"adhésions org visibles (comptes machine)"* ]]
  [[ "$output" != *"team humans"* ]]
  [[ "$output" != *"n'est membre d'aucune team"* ]]
  [[ "$output" != *"n'est pas membre de l'org"* ]]
  [[ "$output" != *"onboarding projet le refusera"* ]]
}

@test "siège membre caché : aucune consigne de publier son adhésion" {
  stub_forge oui hidden
  run bash "$MODULE" check
  [[ "$output" == *"compte forge du siège « zoe »"* ]]
  [[ "$output" != *"adhésion org de zoe privée"* ]]
  [[ "$output" != *"geste UTILISATEUR"* ]]
}

@test "aucun siège nommé : dit comme tel, pas comme un humain" {
  stub_forge oui absent
  export LCARS_LOGIN=""
  run bash "$MODULE" check
  [[ "$output" == *"aucun siège nommé (LCARS_LOGIN)"* ]]
  [[ "$output" != *"humain nomme"* ]]
}

@test "compte forge du siège absent : drift adressé à l'admin du système" {
  stub_forge non absent
  run bash "$MODULE" check
  [[ "$output" == *"DRIFT 63-forge-tokens: compte forge absent pour « zoe », l'admin du système"* ]]
  [[ "$output" != *"team humans"* ]]
}
