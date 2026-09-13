#!/usr/bin/env bats
# bats file_tags=unit
# SOURCE: deploy/tests/doctor_honnete.bats
# AUTHOR: bob
# STARDATE: 2026-09-01
# STATUS: bats tests — UN VERDICT QUI NE PEUT PAS ETRE VRAI EST PIRE QU'UN VERDICT ABSENT

# shellcheck disable=SC2030,SC2031

load refute

setup() {
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


params() {
  local f="$BATS_TEST_TMPDIR/params.sh"
  { sed -n '/^_journal_params()/,/^}$/p' "$RUNNER"
    echo '_journal_params'
    echo 'printf "%s|%s|%s\n" "${PROV_DECK_PORT:-}" "${PROV_FORGE_BASE:-}" "${PROV_ONLY:-}"'
  } > "$f"
  bash "$f"
}

journal() { printf '%s\n' "$@" > "$BATS_TEST_TMPDIR/journal"; }

@test "MEMOIRE : un port passe a l'apply survit au doctor sans drapeau" {
  journal 'posed_at      2026-09-01' 'params        PROV_DECK_PORT=20997' 'substrate     wsl'
  LCARS_JOURNAL_FILE="$BATS_TEST_TMPDIR/journal" run params
  [[ "$output" == "20997|"* ]]
}

@test "MEMOIRE : un drapeau EXPLICITE gagne toujours sur la memoire" {
  journal 'params        PROV_DECK_PORT=20997'
  LCARS_JOURNAL_FILE="$BATS_TEST_TMPDIR/journal" PROV_DECK_PORT=21001 run params
  [[ "$output" == "21001|"* ]]
}

@test "MEMOIRE : sans journal, rien n'est invente" {
  rm -f "$BATS_TEST_TMPDIR/journal"
  LCARS_JOURNAL_FILE="$BATS_TEST_TMPDIR/journal" run params
  [ "$output" = "||" ]
}

@test "MEMOIRE : la liste est FERMEE — un drapeau du geste n'est pas un fait de la machine" {
  local liste; liste="$(sed -n 's/^PROV_REMEMBERED=(\(.*\))$/\1/p' "$LIB")"
  [ -n "$liste" ]
  [ "$(wc -w <<<"$liste")" -eq 4 ]
  grep -q 'PROV_DECK_PORT'       <<<"$liste"
  grep -q 'PROV_FORGE_HOST_PORT' <<<"$liste"
  grep -q 'PROV_SSH_PORT'        <<<"$liste"
  grep -q 'PROV_FORGE_BASE'      <<<"$liste"
  printf '%s\n' "$liste" | refute_out 'ONLY|VERBOSE|PORCELAIN|HUMAN'
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


@test "63-forge-tokens : un humain pas encore membre de l'org n'est pas un DRIFT" {
  local mod="$BATS_TEST_DIRNAME/../../runtime/services/forge.d/tokens.sh"
  local bloc; bloc="$(sed -n '/case "\$(member_state "\$LCARS_LOGIN")"/,/esac/p' "$mod")"
  [ -n "$bloc" ]
  refute grep -q 'p_drift' <<<"$bloc"
  [ "$(grep -c 'p_warn' <<<"$bloc")" -eq 2 ]
  # et chacun NOMME le geste qui le leve — un warn muet est juste un drift plus poli
  grep -q 'profil forge'      <<<"$bloc"
  grep -q 'proprietaire d.org\|propriétaire d.org' <<<"$bloc"
}

@test "63-forge-tokens : ce que le rail PEUT converger reste un drift" {
  # Le sens qui manquait. `63-forge-tokens` porte de vrais drifts — structure absente, tokens a re-minter —
  # et les passer tous en warn aurait rendu le module incapable de signaler quoi que ce soit.
  local mod="$BATS_TEST_DIRNAME/../../runtime/services/forge.d/tokens.sh"
  [ "$(grep -c 'p_drift' "$mod")" -ge 5 ]
}


