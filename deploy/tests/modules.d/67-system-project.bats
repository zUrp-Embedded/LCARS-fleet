#!/usr/bin/env bats
# bats file_tags=integration
# SOURCE: deploy/tests/modules.d/67-system-project.bats
# AUTHOR: bob
# STARDATE: 2026-09-17
# STATUS: témoins de 67-system-project — LCARS publié comme projet de la fleet qu'il installe
#
# CE QUE CE MODULE FAIT, ET CE QU'IL NE FAIT PAS. Il appelle UNE porte du release
# (« lcars project adopt-system ») : l'adoption d'un projet est du runtime — trois faces, des
# labels, une protection —, et la réécrire en shell en ferait une seconde implémentation.
#
# CE QUE CES TÉMOINS TIENNENT :
#   1. la porte est jouée SOUS LE SIÈGE, jamais en root : les faces appartiennent au groupe fleet,
#      et un git joué en root les poserait root:root ;
#   2. `check` MESURE et n'écrit rien — c'est une porte différente, et les quatre états qu'elle
#      rend ont chacun leur mot ;
#   3. ce que la porte imprime est RELAYÉ, pas reformulé : la ligne nomme le projet.

load ../refute
load ../support/decor

setup() {
  local _v
  while read -r _v; do unset "$_v" 2>/dev/null || true; done \
    < <(compgen -v | grep -E '^(LCARS_|PROV_|FORGE_)' || true)
  MOD="$BATS_TEST_DIRNAME/../../modules.d/67-system-project.sh"; [ -f "$MOD" ]
  export PROVISION_LIB="$BATS_TEST_DIRNAME/../../lib/provision-lib.sh"
  export PROVISION_MODULE=67-system-project PROV_SUBSTRATE=linux
  export PROV_HUMAN; PROV_HUMAN="$(id -un)"
  export LCARS_SYSADMIN_UID; LCARS_SYSADMIN_UID="$(id -u)"
  decor_pose
  forge_double_start
  forge_route GET /api/v1/version 200 '{"version":"1.26.1"}'
  export PROV_FORGE_HOST_PORT="${FORGE_DOUBLE_URL##*:}"
  export CALLS="$BATS_TEST_TMPDIR/calls"; : > "$CALLS"
  # la CLI du produit, doublée : elle note son argv et rend ce que le cas veut
  CLI="$LCARS_DECOR_ROOT/usr/local/bin/lcars"
  mkdir -p "$(dirname "$CLI")"
  cat > "$CLI" <<'EOF'
#!/usr/bin/env bash
echo "CLI:$* (uid=$(id -u))" >> "$CALLS"
# la table de transport : ce que l'installeur DECIDE et que le produit lit
echo "ENV:FORGE_BASE_URL=${FORGE_BASE_URL:-<absente>}" >> "$CALLS"
[[ "${3:-}" != "--check" ]] || { printf '%s\n' "${STUB_CHECK:-ABSENT fleet/lcars-fleet}"; exit "${STUB_CHECK_RC:-0}"; }
printf '%s\n' "${STUB_ADOPT:-ADOPTED fleet/lcars-fleet}"
exit "${STUB_ADOPT_RC:-0}"
EOF
  chmod 0755 "$CLI"
}

teardown() { forge_double_stop; }

mod() { run bash "$MOD" "$@"; }

@test "apply : la porte du release est jouée, et son verdict est relayé sans être reformulé" {
  mod apply
  [ "$status" -eq 0 ] || { echo "$output"; return 1; }
  grep -q "^CLI:project adopt-system" "$CALLS"
  [[ "$output" == *"POSÉ  67-system-project: fleet/lcars-fleet publié — la source de cette machine est un projet de sa fleet"* ]]
}

@test "apply comme check passent l'ARBRE dont la machine a été installée — la face de code s'en sème" {
  # `--from` dit D'OÙ vient la source ; OÙ elle va est une décision du layout, jamais du module.
  # Sans lui, le rail POSTE n'a pas de face de code et l'adoption refuse en `no_local_main`.
  local racine; racine="$(cd "$BATS_TEST_DIRNAME/../../.." && pwd)"
  mod apply
  [ "$status" -eq 0 ] || { echo "$output"; return 1; }
  grep -q "^CLI:project adopt-system --from $racine (uid=" "$CALLS" || { cat "$CALLS"; return 1; }

  # la porte PARLE à la forge : sans la table de transport elle refuse en « missing :base_url »
  grep -q "^ENV:FORGE_BASE_URL=http" "$CALLS" || { cat "$CALLS"; return 1; }

  # `check` MESURE : son verdict dépend de l'état, pas de ce témoin — c'est l'argv qui est tenu ici
  : > "$CALLS"
  mod check
  grep -q "^CLI:project adopt-system --check --from $racine (uid=" "$CALLS" || { cat "$CALLS"; return 1; }
}

@test "SEEDED : la face est en place et le module renvoie au poseur du dépôt, sans dérive" {
  # le dépôt est créé et semé par `61-forge-structure`, qui joue le geste avec le jeton master ;
  # ce module tient la FACE LOCALE, et une forge qu'il ne peut pas prouver n'est pas sa panne
  STUB_ADOPT="SEEDED fleet/lcars-fleet" mod apply
  [ "$status" -eq 0 ] || { echo "$output"; return 1; }
  [[ "$output" == *"OK    67-system-project: fleet/lcars-fleet : face de code en place — le dépôt est posé par la structure de la forge (61)"* ]] || { echo "$output"; return 1; }

  STUB_CHECK="SEEDED fleet/lcars-fleet" mod check
  [ "$status" -eq 0 ] || { echo "$output"; return 1; }
  [[ "$output" == *"face de code en place"* ]]
}

@test "apply : un projet DÉJÀ publié est conforme — ce module se rejoue à chaque passe" {
  STUB_ADOPT="ALREADY fleet/lcars-fleet" mod apply
  [ "$status" -eq 0 ] || { echo "$output"; return 1; }
  [[ "$output" == *"OK    67-system-project: fleet/lcars-fleet déjà publié"* ]]
  [[ "$output" != *"POSÉ"* ]]
}

@test "apply : une porte qui refuse est un DRIFT qui relaie sa cause — l'installation continue" {
  STUB_ADOPT="REFUSED fleet/lcars-fleet {:not_adoptable, {:no_local_main, \"/home/projects/lcars-fleet\"}}" \
    STUB_ADOPT_RC=1 mod apply
  [ "$status" -eq 2 ]
  [[ "$output" == *"DRIFT 67-system-project: projet du système NON publié"*"no_local_main"* ]]
}

@test "check : il MESURE et n'écrit rien — la porte appelée n'est pas la même" {
  mod check
  [ "$status" -eq 1 ]
  grep -q -- "^CLI:project adopt-system --check" "$CALLS"
  refute grep -qx "CLI:project adopt-system (uid=$(id -u))" "$CALLS"
  [[ "$output" == *"DRIFT 67-system-project: fleet/lcars-fleet absent de la forge"* ]]
}

@test "check : les quatre états mesurés ont chacun leur mot" {
  STUB_CHECK="ALREADY fleet/lcars-fleet" mod check
  [ "$status" -eq 0 ]
  [[ "$output" == *"OK    67-system-project: fleet/lcars-fleet déjà publié"* ]]

  STUB_CHECK="NOSOURCE fleet/lcars-fleet" mod check
  [[ "$output" == *"WARN  67-system-project: fleet/lcars-fleet : cette machine ne porte pas la source"* ]]

  STUB_CHECK="UNREADABLE fleet/lcars-fleet {:http, 500}" mod check
  [ "$status" -eq 1 ]
  [[ "$output" == *"NON mesurable"*"rien n'est conclu"* ]]
}

@test "sans release posée : drift qui nomme 60, et la porte n'est pas jouée" {
  rm -f "$CLI"
  mod apply
  [ "$status" -eq 2 ]
  [[ "$output" == *"la release n'est pas posée (cf. 60-deploy)"* ]]
  [ ! -s "$CALLS" ]
}

@test "forge muette : drift, et rien n'est publié" {
  PROV_FORGE_HOST_PORT=9 mod apply
  [ "$status" -eq 2 ]
  [[ "$output" == *"forge muette"* ]]
  [ ! -s "$CALLS" ]
}

@test "siège non établi : ÉCHEC nommé — les faces ne se posent pas en root" {
  LCARS_SYSADMIN_UID=4294967000 mod apply
  [ "$status" -eq 1 ]
  [[ "$output" == *"siège non établi"*"elles ne se posent pas en root"* ]]
  [ ! -s "$CALLS" ]
}
