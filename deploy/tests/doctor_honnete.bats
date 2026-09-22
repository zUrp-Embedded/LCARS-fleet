#!/usr/bin/env bats
# bats file_tags=unit
# SOURCE: deploy/tests/doctor_honnete.bats
# AUTHOR: bob
# STARDATE: 2026-09-01
# STATUS: bats tests — UN VERDICT QUI NE PEUT PAS ETRE VRAI EST PIRE QU'UN VERDICT ABSENT

# shellcheck disable=SC2030,SC2031

load refute
load support/decor

setup() {
  local _v
  while read -r _v; do unset "$_v" 2>/dev/null || true; done \
    < <(compgen -v | grep -E '^(LCARS_|PROV_)' || true)
  decor_pose
  DEPLOY="$BATS_TEST_DIRNAME/.."
  LIB="$DEPLOY/lib/provision-lib.sh"
  RUNNER="$DEPLOY/provision"
  [ -f "$LIB" ]
  [ -f "$RUNNER" ]
  export PROVISION_LIB="$LIB"
}


@test "66-deck-oidc : un fichier PRESENT et illisible n'est plus annonce « absent »" {
  local mod="$DEPLOY/../runtime/services/forge.d/deck-oidc.sh"
  mkdir -p "$BATS_TEST_TMPDIR/etc"
  echo '{}' > "$BATS_TEST_TMPDIR/etc/deck-oidc.json"
  chmod 0000 "$BATS_TEST_TMPDIR/etc/deck-oidc.json"
  run env LCARS_MODULE_PROTOCOL="$DEPLOY/../runtime/services/lib/module-protocol.sh" LCARS_MODULE_TAG=66-deck-oidc \
          LCARS_DECK_OIDC_FILE="$BATS_TEST_TMPDIR/etc/deck-oidc.json" \
          FORGE_BASE_URL="http://forge.invalid" \
      bash "$mod" check
  chmod 0644 "$BATS_TEST_TMPDIR/etc/deck-oidc.json"
  printf '%s\n' "$output" | refute_out 'deck-oidc\.json absent'
  [[ "$output" == *"illisible"* ]]
}

@test "66-deck-oidc : un fichier VRAIMENT absent reste un DRIFT" {
  # Le sens qui manquait : sans lui, un module qui repondrait « non mesurable » a tout passerait le
  # temoin ci-dessus en ayant cesse de signaler quoi que ce soit.
  local mod="$DEPLOY/../runtime/services/forge.d/deck-oidc.sh"
  run env LCARS_MODULE_PROTOCOL="$DEPLOY/../runtime/services/lib/module-protocol.sh" LCARS_MODULE_TAG=66-deck-oidc \
          LCARS_DECK_OIDC_FILE="$BATS_TEST_TMPDIR/pas-la.json" \
          FORGE_BASE_URL="http://forge.invalid" \
      bash "$mod" check
  [[ "$output" == *"absent"* ]]
  [[ "$output" == *"DRIFT"* ]]
}


params() { # _journal_params du runner, joué seul, sur le journal du décor
  local f="$BATS_TEST_TMPDIR/params.sh"
  { printf 'DEPLOY_DIR=%q\n' "$DEPLOY"
    sed -n '/^_journal_params()/,/^}$/p' "$RUNNER"
    echo '_journal_params'
    echo 'printf "%s|%s|%s\n" "${PROV_DECK_PORT:-}" "${PROV_FORGE_BASE:-}" "${PROV_ONLY:-}"'
  } > "$f"
  bash "$f"
}

JOURNAL_DECOR=opt/lcars/var/install.journal
journal() { mkdir -p "$(dirname "$LCARS_DECOR_ROOT/$JOURNAL_DECOR")"; printf '%s\n' "$@" > "$LCARS_DECOR_ROOT/$JOURNAL_DECOR"; }

@test "MEMOIRE : un port passe a l'apply survit au doctor sans drapeau" {
  journal 'posed_at      2026-09-01' 'params        PROV_DECK_PORT=20997' 'substrate     wsl'
  run params
  [[ "$output" == "20997|"* ]]
}

@test "MEMOIRE : un drapeau EXPLICITE gagne toujours sur la memoire" {
  journal 'params        PROV_DECK_PORT=20997'
  PROV_DECK_PORT=21001 run params
  [[ "$output" == "21001|"* ]]
}

@test "MEMOIRE : sans journal, rien n'est invente" {
  run params
  [ "$output" = "||" ]
}

@test "MEMOIRE : sans choix de l'opérateur, la ligne params est vide" {
  run bash -c '. "$1" >/dev/null 2>&1; prov_params_line' _ "$LIB"
  [ "$status" -eq 0 ]
  [ "$output" = "" ]
}

@test "MEMOIRE : un choix hors défaut s'écrit seul, un choix égal à son défaut ne s'écrit pas" {
  # un défaut écrit au journal deviendrait un choix, relu comme tel à la passe suivante
  run env PROV_DECK_PORT=3000 bash -c '. "$1" >/dev/null 2>&1; prov_params_line' _ "$LIB"
  [ "$output" = "PROV_DECK_PORT=3000" ]
  run env PROV_DECK_PORT="$(sed -n 's/^PROV_DECK_PORT_DEFAULT=//p' "$DEPLOY/installer-constants.env")" \
      bash -c '. "$1" >/dev/null 2>&1; prov_params_line' _ "$LIB"
  [ "$output" = "" ]
}

@test "MEMOIRE : la liste est fermée — les trois ports, la base et l'humain de démonstration, jamais un drapeau du geste" {
  run env PROV_DECK_PORT=20901 PROV_FORGE_HOST_PORT=20902 PROV_SSH_PORT=20903 PROV_FORGE_BASE=zoe PROV_BUILTIN_HUMAN=demo \
      PROV_ONLY=60 PROV_VERBOSE=1 PROV_PORCELAIN=1 PROV_HUMAN=quelquun PROV_SUBSTRATE=linux \
      bash -c '. "$1" >/dev/null 2>&1; prov_params_line' _ "$LIB"
  [ "$status" -eq 0 ]
  [ "$(tr ' ' '\n' <<<"$output" | sort | paste -sd' ')" = "PROV_BUILTIN_HUMAN=demo PROV_DECK_PORT=20901 PROV_FORGE_BASE=zoe PROV_FORGE_HOST_PORT=20902 PROV_SSH_PORT=20903" ]
}

@test "MEMOIRE : ce que le journal ecrit est ce que la liste fermee autorise" {
  # Les deux bouts du meme contrat : `prov_params_line` ECRIT, `_journal_params` LIT. S'ils
  # divergeaient, la machine se rappellerait de choses que personne n'a decide de lui confier.
  run env PROV_DECK_PORT=20997 PROV_FORGE_BASE=zoe PROV_VERBOSE=1 PROV_HUMAN=quelquun \
      bash -c '. "$1" >/dev/null 2>&1; prov_params_line' _ "$LIB"
  [[ "$output" == *"PROV_DECK_PORT=20997"* ]]
  [[ "$output" == *"PROV_FORGE_BASE=zoe"* ]]
  printf '%s\n' "$output" | refute_out 'PROV_VERBOSE|PROV_HUMAN'
}

