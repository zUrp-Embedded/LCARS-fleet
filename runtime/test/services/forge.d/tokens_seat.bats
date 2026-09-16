#!/usr/bin/env bats
# SOURCE: runtime/test/services/forge.d/tokens_seat.bats
# AUTHOR: bob
# STARDATE: 2026-09-15
# STATUS: témoins de forge.d/tokens.sh — le compte que nomme LCARS_LOGIN : le siège s'il l'est, une personne de fleet sinon
#
# POURQUOI CE FICHIER. `LCARS_LOGIN` est l'humain de la passe : sur un poste `PROV_HUMAN`, donc le
# compte qui installe OU celui que `--human` nomme ; dans le conteneur, le siège que le boot lit dans
# `/run/lcars-seat.login`. Le geste ne peut donc pas le prendre pour le siège par construction : il
# lit le siège à sa source (l'uid du siège sur un poste, le fichier de l'init dans le conteneur) et
# ne parle du siège que si le login L'EST.
#
# CE QUE LES TÉMOINS TIENNENT, sur les deux rails :
#   - le siège : son compte se sonde, son adhésion jamais, aucune phrase ne le rapproche de la team
#     humans ; absent, c'est un WARN qui nomme le geste qui le crée — ce geste ne le crée pas ;
#   - une personne de fleet : son compte et son adhésion à l'org se sondent, et rien de ce qui la
#     concerne n'est un DRIFT, puisqu'aucun apply ne pose une personne.
#
# Le décor : `id` est doublé pour deux comptes, `admiral` (uid 1000) et `zoe` (uid 1003) ; tout autre
# appel part au vrai `id`. Les fichiers du siège pointent dans le dossier du test : un poste posé ne
# prête pas les siens.

setup() {
  MODULE="$BATS_TEST_DIRNAME/../../../services/forge.d/tokens.sh"
  [ -f "$MODULE" ]

  BIN="$BATS_TEST_TMPDIR/bin"
  mkdir -p "$BIN" "$BATS_TEST_TMPDIR/tokens"

  export LCARS_MODULE_PROTOCOL="$BATS_TEST_DIRNAME/../../../services/lib/module-protocol.sh"
  export LCARS_MODULE_TAG=63-forge-tokens
  printf '%s\n' '#!/usr/bin/env bash' '[[ "$1" == tool ]] && shift' '[[ "$1" == roles-tfvars ]] && echo "{\"org\":\"fleet\",\"roles\":[\"fleet_engineer\"],\"system_roles\":[\"system_architect\"]}"' 'exit 0' > "$BIN/lcars"
  chmod +x "$BIN/lcars"; export LCARS_CLI="$BIN/lcars"
  VRAI_ID="$(command -v id)"
  cat > "$BIN/id" <<EOF
#!/usr/bin/env bash
if [[ "\$1" == -u && "\$2" == -- ]]; then
  case "\$3" in admiral) echo 1000 ;; zoe) echo 1003 ;; *) exit 1 ;; esac
  exit 0
fi
exec '$VRAI_ID' "\$@"
EOF
  chmod +x "$BIN/id"
  export FORGE_BASE_URL="http://forge.test"
  export LCARS_PRIVATE_DIR="$BATS_TEST_TMPDIR/tokens"
  export LCARS_CATALOGUES_DIR="$BATS_TEST_TMPDIR/nocat"
  export LCARS_SEAT_UID_FILE="$BATS_TEST_TMPDIR/seat.uid"
  export LCARS_SEAT_LOGIN_FILE="$BATS_TEST_TMPDIR/lcars-seat.login"
  unset LCARS_SYSADMIN_UID
  # le jeton système lisible : sans lui les adhésions ne se sondent pas, et le témoin ne mesurerait rien
  printf 'SYSTOK' > "$BATS_TEST_TMPDIR/tokens/system_starfleet.gitea_token"
  export LCARS_ROLE_TOKENS_SCRIPT="$BATS_TEST_TMPDIR/a4.sh"
  printf '#!/usr/bin/env bash\nexit 0\n' > "$LCARS_ROLE_TOKENS_SCRIPT"; chmod +x "$LCARS_ROLE_TOKENS_SCRIPT"
  export PATH="$BIN:$PATH"
}

poste() { # poste <login> — le siège est le compte d'uid 1000, celui qui a lancé l'installation
  export LCARS_SYSADMIN_UID=1000 LCARS_LOGIN="$1"
}
conteneur() { # conteneur <login> — l'init a écrit « admiral » ; aucun uid du siège n'est lisible
  printf 'admiral\n' > "$LCARS_SEAT_LOGIN_FILE"
  export LCARS_LOGIN="$1"
}

# stub_forge <login> <existe : oui|non> <adhésion : absent|hidden|visible>
# Les comptes machine existent et sont membres visibles : seule la place du login nommé varie.
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
  */api/v1/users/$1)             [[ '$2' == oui ]] || exit 22; [[ \$o -eq 1 ]] || printf '{"login":"$1","restricted":false}' ;;
  */api/v1/users/*)              [[ \$o -eq 1 ]] || printf '{}' ;;
  */orgs/lcars/members/$1)       case '$3' in absent) code 404 ;; *) code 204 ;; esac ;;
  */orgs/lcars/public_members/$1) case '$3' in visible) code 204 ;; *) code 404 ;; esac ;;
  # un role n'est JAMAIS membre de l'org systeme ; dans l'org de son catalogue, il l'est sauf mise en scene
  */orgs/lcars/members/fleet_engineer|*/orgs/lcars/members/system_architect) code 404 ;;
  */orgs/fleet/members/fleet_engineer) [[ -z "\${ROLE_HORS_ORG:-}" ]] && code 204 || code 404 ;;
  */orgs/*/members/*|*/orgs/*/public_members/*) code 204 ;;
  *)                             exit 22 ;;
esac
exit 0
EOF
  chmod +x "$BIN/curl"
}

pas_de_team_promise() {
  [[ "$output" != *"team humans"* ]]
  [[ "$output" != *"n'est membre d'aucune team"* ]]
  [[ "$output" != *"n'est pas membre de l'org"* ]]
  [[ "$output" != *"une personne de fleet"* ]]
}

# ─── le siège ───────────────────────────────────────────────────────────────────────────────────

@test "poste, siège présent hors de l'org : son compte est dit, aucune team ne lui est promise" {
  poste admiral; stub_forge admiral oui absent
  run bash "$MODULE" check
  [[ "$output" == *"OK    63-forge-tokens: compte forge du siège « admiral », l'admin du système"* ]]
  [[ "$output" == *"adhésions org visibles (comptes machine)"* ]]
  pas_de_team_promise
}

@test "poste, siège membre caché : aucune consigne de publier son adhésion" {
  poste admiral; stub_forge admiral oui hidden
  run bash "$MODULE" check
  [[ "$output" == *"compte forge du siège « admiral »"* ]]
  [[ "$output" != *"privée"* ]]
  pas_de_team_promise
}

@test "poste, siège absent de la forge : WARN qui nomme deploy/workstation up (48-forge-host), ni DRIFT ni inscription" {
  poste admiral; stub_forge admiral non absent
  run bash "$MODULE" check
  [[ "$output" == *"WARN  63-forge-tokens: compte forge absent pour « admiral », le siège (l'admin du système) — ce geste ne le crée pas. Sur un poste dont la forge est montée, « deploy/workstation up » le crée (module 48-forge-host) ; sur une forge fournie, et dans un conteneur, c'est le compte n°1 de la forge, posé par son opérateur"* ]]
  [[ "$output" != *"DRIFT 63-forge-tokens: compte forge absent"* ]]
  [[ "$output" != *"human_not_provisioned"* ]]
  [[ "$output" != *"s'inscrit"* ]]
  [[ "$output" != *"onboarding"* ]]
  pas_de_team_promise
}

@test "poste, l'uid du siège se lit d'abord dans son fichier : un doctor lancé par zoe sans sudo ne fait pas d'elle le siège" {
  # `deploy/provision` pose LCARS_SYSADMIN_UID à l'uid de l'appelant quand SUDO_USER manque ; le
  # fichier posé par l'installation, lui, garde le siège.
  printf '1000\n' > "$LCARS_SEAT_UID_FILE"
  export LCARS_SYSADMIN_UID=1003 LCARS_LOGIN=zoe
  stub_forge zoe oui visible
  run bash "$MODULE" check
  [[ "$output" == *"compte forge de « zoe », une personne de fleet"* ]]
  [[ "$output" != *"siège « zoe »"* ]]
}

@test "conteneur, siège lu dans /run/lcars-seat.login, présent : son compte est dit, aucune team ne lui est promise" {
  conteneur admiral; stub_forge admiral oui absent
  run bash "$MODULE" check
  [[ "$output" == *"OK    63-forge-tokens: compte forge du siège « admiral », l'admin du système"* ]]
  pas_de_team_promise
}

@test "conteneur, siège absent de la forge : WARN qui nomme le compte n°1 de la forge" {
  conteneur admiral; stub_forge admiral non absent
  run bash "$MODULE" check
  [[ "$output" == *"WARN  63-forge-tokens: compte forge absent pour « admiral », le siège (l'admin du système)"*"c'est le compte n°1 de la forge, posé par son opérateur"* ]]
  [[ "$output" != *"DRIFT 63-forge-tokens: compte forge absent"* ]]
  pas_de_team_promise
}

# ─── les comptes de role, dans l'org de LEUR catalogue ──────────────────────────────────────────

@test "les roles se sondent dans l'org de leur catalogue, le compte systeme dans l'org systeme : un role absent de l'org systeme n'est PAS un drift" {
  poste zoe; stub_forge zoe oui visible
  run bash "$MODULE" check
  [[ "$output" == *"adhésions org visibles (comptes machine)"* ]]
  [[ "$output" != *"SANS adhésion"* ]]
  [ "$(grep -c '^DRIFT' <<<"$output")" -eq 0 ] || { echo "$output"; return 1; }
}

@test "un role absent de l'org de son catalogue est un drift qui nomme l'org, le role et le geste qui le repose" {
  poste zoe; stub_forge zoe oui visible
  ROLE_HORS_ORG=1 run bash "$MODULE" check
  [[ "$output" == *"DRIFT 63-forge-tokens: comptes SANS adhésion à l'org fleet : fleet_engineer — jeton valide, zéro droit d'écriture."*"« lcars catalogue install fleet » la rejoue"* ]]
  [[ "$output" != *"à l'org lcars : fleet_engineer"* ]]
}

# ─── une personne de fleet ──────────────────────────────────────────────────────────────────────

@test "poste, --human zoe : une personne de fleet, jamais « le siège » ni « l'admin du système »" {
  poste zoe; stub_forge zoe oui visible
  run bash "$MODULE" check
  [[ "$output" == *"OK    63-forge-tokens: compte forge de « zoe », une personne de fleet"* ]]
  [[ "$output" == *"OK    63-forge-tokens: « zoe » membre de l'org lcars, adhésion visible"* ]]
  [[ "$output" != *"siège « zoe »"* ]]
  [[ "$output" != *"l'admin du système"* ]]
}

@test "poste, --human zoe absente de la forge : WARN, l'apply ne crée pas le compte d'une personne" {
  poste zoe; stub_forge zoe non absent
  run bash "$MODULE" check
  [[ "$output" == *"WARN  63-forge-tokens: compte forge absent pour « zoe », une personne de fleet — l'apply ne crée pas le compte d'une personne : elle s'inscrit sur la forge sous ce nom, puis un propriétaire de l'org lcars l'ajoute à la team humans"* ]]
  [[ "$output" != *"DRIFT 63-forge-tokens: compte forge absent"* ]]
  [[ "$output" != *"le siège"* ]]
}

@test "poste, --human zoe hors de l'org : WARN, l'apply ne pose pas les personnes" {
  poste zoe; stub_forge zoe oui absent
  run bash "$MODULE" check
  [[ "$output" == *"WARN  63-forge-tokens: « zoe » n'est pas membre de l'org lcars — état normal tant qu'un propriétaire de l'org n'a pas ajouté ce compte à la team humans ; l'apply ne pose pas les personnes"* ]]
  [[ "$output" != *"DRIFT 63-forge-tokens: « zoe »"* ]]
}

@test "poste, --human zoe membre caché : WARN, un geste de la personne" {
  poste zoe; stub_forge zoe oui hidden
  run bash "$MODULE" check
  [[ "$output" == *"WARN  63-forge-tokens: adhésion de « zoe » à l'org lcars privée — un geste de la personne, hors de portée de l'apply"* ]]
}

@test "conteneur, zoe n'est pas le siège écrit par l'init : une personne de fleet" {
  conteneur zoe; export LCARS_SYSADMIN_UID=1000
  stub_forge zoe oui absent
  run bash "$MODULE" check
  [[ "$output" == *"compte forge de « zoe », une personne de fleet"* ]]
  [[ "$output" == *"« zoe » n'est pas membre de l'org lcars"* ]]
  [[ "$output" != *"siège « zoe »"* ]]
}

@test "aucun humain nommé : dit comme tel, rien ne se sonde" {
  poste ""; stub_forge zoe oui absent
  run bash "$MODULE" check
  [[ "$output" == *"aucun humain nommé (LCARS_LOGIN) — aucun compte forge ne se sonde ici"* ]]
  [[ "$output" != *"siège"* ]]
}
