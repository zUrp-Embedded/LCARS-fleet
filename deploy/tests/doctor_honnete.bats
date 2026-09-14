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
  export FERME="$BATS_TEST_TMPDIR/ferme"
}

# Joue une fonction de la lib, sans rien d'autre.
lib() { bash -c '. "$1" >/dev/null 2>&1; shift; eval "$@"' _ "$LIB" "$@"; }

teardown() { [ -d "$FERME" ] && chmod 0755 "$FERME" 2>/dev/null || true; }


@test "ETAT : un fichier lisible est « present »" {
  echo x > "$BATS_TEST_TMPDIR/f"
  run lib 'prov_file_state "$BATS_TEST_TMPDIR/f"'
  [ "$output" = present ]
}

@test "ETAT : un fichier qui n'est pas la est « absent » — et l'absence se MERITE" {
  run lib 'prov_file_state "$BATS_TEST_TMPDIR/pas-la"'
  [ "$output" = absent ]
}

@test "ETAT : un fichier PRESENT mais non lisible n'est pas « absent »" {
  echo x > "$BATS_TEST_TMPDIR/secret"
  chmod 0000 "$BATS_TEST_TMPDIR/secret"
  run lib 'prov_file_state "$BATS_TEST_TMPDIR/secret"'
  chmod 0644 "$BATS_TEST_TMPDIR/secret"
  [ "$output" = unreadable ]
}

@test "ETAT : sous un repertoire NON TRAVERSABLE, rien n'est conclu" {
  # Un `-e` faux ne prouve l'absence que si l'on peut traverser le parent. Sous un repertoire ferme
  # TOUT parait absent — c'est la facon la plus economique de fabriquer un inventaire faux.
  mkdir -p "$FERME/dedans"
  chmod 0000 "$FERME"
  run lib 'prov_file_state "$FERME/dedans/x"'
  chmod 0755 "$FERME"
  [ "$output" = unmeasurable ]
}

@test "ETAT : les deux etats non concluants DISENT POURQUOI" {
  # « non mesurable » sans le motif est un troisieme verdict aussi opaque que les deux qu'il
  # remplace : l'operateur sait qu'il ne sait pas, et rien de plus.
  echo x > "$BATS_TEST_TMPDIR/secret"; chmod 0000 "$BATS_TEST_TMPDIR/secret"
  run lib 'prov_state_why unreadable "$BATS_TEST_TMPDIR/secret"'
  chmod 0644 "$BATS_TEST_TMPDIR/secret"
  [[ "$output" == *"illisible"* ]]
  [[ "$output" == *"sudo"* ]]                       # et il dit le geste qui leve l'ignorance

  run lib 'prov_state_why unmeasurable /a/b/c'
  [[ "$output" == *"NON MESURABLE"* ]]
  [[ "$output" == *"/a/b"* ]]                       # et il NOMME le repertoire qui bloque
}

@test "ETAT : un chemin dont un ANCETRE lointain est ferme n'est pas dit absent" {
  mkdir -p "$FERME"
  chmod 0000 "$FERME"
  run lib 'prov_file_state "$FERME/a/b/c/d"'
  chmod 0755 "$FERME"
  [ "$output" = unmeasurable ]
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

