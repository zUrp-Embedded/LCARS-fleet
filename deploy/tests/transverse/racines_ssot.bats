#!/usr/bin/env bats
# bats file_tags=structure
# SOURCE: deploy/tests/transverse/racines_ssot.bats
# AUTHOR: alice
# STARDATE: 2026-08-28
# STATUS: bats tests — une racine se DEMANDE, elle ne se recopie pas

# ⚠ SC2016 : ce temoin LIT DU CODE, ses motifs doivent atteindre `grep` tels quels.
# shellcheck disable=SC2016

load ../refute

setup() {
  DEPLOY="$BATS_TEST_DIRNAME/../.."
  RACINES='/opt/lcars/runtime|/home/private|/var/lib/lcars|/usr/share/lcars|/etc/lcars|/home/catalogues|/opt/lcars/var/catalogues'
}

# Le perimetre : ce qui DECIDE. Le Dockerfile et l'entrypoint portent le layout de l'image.
sources() { printf '%s\n' "$DEPLOY"/modules.d/*.sh "$DEPLOY"/lib/*.sh "$DEPLOY"/provision "$DEPLOY"/container; }

code_seul() {
  grep -vE '^[[:space:]]*#' "$1" 2>/dev/null \
    | grep -vE ':=|:-' \
    | grep -vE '(^|[[:space:]])(echo|printf|say|p_ok|p_chg|p_warn|p_drift|p_fail|p_step|p_die|die)([[:space:]]|$)'
}

@test "GARDE D'INSTRUMENT : les sources existent et sont nombreuses" {
  # Sans ce garde, un glob casse rendrait zero fichier, donc VERT en n'ayant rien lu — la forme
  # d'echec la plus chere, celle qui certifie.
  [ "$(sources | wc -l)" -ge 25 ]
  local f; while read -r f; do [ -f "$f" ]; done < <(sources)
}

@test "AUCUNE racine n'est AFFECTEE en dur — elle se demande a sa couture" {
  local f bad=0 hit
  while read -r f; do
    hit="$(code_seul "$f" | grep -nE "^[^=]*=[\"']?($RACINES)" || true)"
    [[ -z "$hit" ]] || { echo "$(basename "$f") : racine AFFECTEE en dur"; echo "$hit"; bad=1; }
  done < <(sources)
  [ "$bad" -eq 0 ]
}

@test "AUCUNE racine n'est TESTEE en dur — un test qui la connait la decide" {
  # `[[ -d /home/private ]]` fige la racine aussi surement qu'une affectation : le jour ou elle
  # bouge, le test rend faux et la branche saute, en silence.
  local f bad=0 hit
  while read -r f; do
    hit="$(code_seul "$f" | grep -nE "\[\[? +-[a-z] +($RACINES)" || true)"
    [[ -z "$hit" ]] || { echo "$(basename "$f") : racine TESTEE en dur"; echo "$hit"; bad=1; }
  done < <(sources)
  [ "$bad" -eq 0 ]
}


@test "RACINE : \`PROV_ROOT\` est declaree UNE fois, dans la lib" {
  local lib="$DEPLOY/lib/provision-lib.sh"
  [ "$(grep -c '^: "\${PROV_ROOT:=' "$lib")" -eq 1 ]
}

@test "RACINE : aucun module ne redefinit \`/opt/lcars\` en dur — il derive" {
  # Trois modules portaient leur propre `${LCARS_…:-/opt/lcars}`. Trois defauts pour une racine, ce
  # sont trois endroits a corriger le jour ou elle bouge — et deux qu'on oubliera.
  local f bad=0 hit
  while read -r f; do
    hit="$(grep -vE '^[[:space:]]*#' "$f" | grep -nE '^[A-Z_]+="\$\{[A-Z_]+:-/opt/lcars' || true)"
    [[ -z "$hit" ]] || { echo "$(basename "$f") : racine du produit redefinie"; echo "$hit"; bad=1; }
  done < <(printf '%s\n' "$DEPLOY"/modules.d/*.sh)
  [ "$bad" -eq 0 ]
}

@test "un MESSAGE a le droit de nommer une racine — c'est son metier" {
  # Contre-temoin des deux precedents. Sans lui, quelqu'un « reparerait » le mur en interdisant le
  # litteral partout, et les messages cesseraient de dire OU ca casse.
  local n
  n="$(grep -rhE "(p_drift|p_fail|say|echo)[^|]*($RACINES)" "$DEPLOY"/modules.d/*.sh 2>/dev/null | grep -c . || true)"
  [ "$n" -ge 1 ]
}


consommateurs() { printf '%s\n' "$DEPLOY/provision" "$DEPLOY"/modules.d/*.sh; }

# Les noms que la lib DECLARE avec un defaut.
noms_lib() { sed -n 's/^: "${\([A-Z_][A-Z0-9_]*\):[=-].*/\1/p' "$DEPLOY/lib/provision-lib.sh" | sort -u; }

@test "GARDE D'INSTRUMENT : la lib declare des defauts, et des fichiers la sourcent" {
  [ "$(noms_lib | wc -l)" -ge 20 ]
  [ "$(consommateurs | wc -l)" -ge 10 ]
}

@test "RACINE : nul ne pose un nom de la lib AVANT de la sourcer" {
  local f n src bad=()
  while read -r f; do
    [[ -f "$f" ]] || continue
    # La ligne qui source la lib. Sans elle, le fichier n'est pas un consommateur : rien a verifier.
    src="$(grep -nE '^[[:space:]]*(\.|source)[[:space:]].*(PROVISION_LIB|provision-lib\.sh)' "$f" \
           | head -1 | cut -d: -f1)"
    [[ -n "$src" ]] || continue
    while read -r n; do
      [[ -n "$n" ]] || continue
      awk -v n="$n" -v lim="$src" 'NR<lim && $0 ~ "^(export[ \t]+)?" n "=" { print NR; exit }' "$f" \
        | while read -r l; do echo "${f##*/}:$l: $n"; done
    done < <(noms_lib)
  done < <(consommateurs) > "$BATS_TEST_TMPDIR/hits"
  mapfile -t bad < "$BATS_TEST_TMPDIR/hits"
  [ "${#bad[@]}" -eq 0 ] || {
    echo "MASQUAGE — ces noms sont poses AVANT le source, donc le defaut de la lib ne tire pas :" >&2
    printf '  %s\n' "${bad[@]}" >&2
    echo "  renomme la variable locale : le nom appartient au contrat de la lib." >&2
    return 1
  }
}
