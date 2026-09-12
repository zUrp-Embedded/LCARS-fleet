#!/usr/bin/env bats
# bats file_tags=integration
# SOURCE: deploy/tests/installer_gate.bats
# AUTHOR: bob
# STARDATE: 2026-09-12
# STATUS: témoins de deploy/gate.sh — la porte se mesure elle-même : refus nommés, couches, copies qui s'accordent
#
# Le décor copie la porte dans un arbre à part avec un tests/ fabriqué : ce qui se mesure est le
# comportement de la porte, pas le contenu de la suite. bats est une doublure qui note son argv.

load refute

setup() {
  PORTE_SRC="$BATS_TEST_DIRNAME/../gate.sh"
  [ -f "$PORTE_SRC" ]
  SHELL_GATE="$BATS_TEST_DIRNAME/../../runtime/test/shell_gate.sh"

  DECOR="$BATS_TEST_TMPDIR/decor"
  mkdir -p "$DECOR/tests"
  cp "$PORTE_SRC" "$DECOR/gate.sh"
  chmod 0755 "$DECOR/gate.sh"

  BIN="$BATS_TEST_TMPDIR/bin"; mkdir -p "$BIN"
  export PATH="$BIN:$PATH"
}

stub_bats() { # stub_bats <rc rendu>
  printf '#!/usr/bin/env bash\necho "BATS APPELE: $*"\nexit %s\n' "$1" > "$BIN/bats"
  chmod 0755 "$BIN/bats"
}

temoin() { # temoin <fichier> <couche> [<corps>] — un témoin du décor, avec sa couche déclarée
  printf '# bats file_tags=%s\n%s' "$2" "${3-}" > "$DECOR/tests/$1"
}

# un PATH qui porte tout sauf UN outil : un PATH vide tuerait bash lui-même, et une liste d'outils
# écrite à la main dérive au premier outil ajouté
path_sans() { # path_sans <outil> → un dossier
  local sans="$BATS_TEST_TMPDIR/sans-$1"; mkdir -p "$sans"
  local d f n; local -a dirs; IFS=: read -ra dirs <<< "$PATH"
  for d in "${dirs[@]}"; do
    [ -d "$d" ] || continue
    for f in "$d"/*; do
      [ -x "$f" ] || continue
      n="$(basename "$f")"
      [ "$n" = "$1" ] && continue
      [ -e "$sans/$n" ] || ln -sf "$f" "$sans/$n"
    done
  done
  [ ! -e "$sans/$1" ]
  [ -x "$sans/bash" ]
  printf '%s' "$sans"
}

@test "LCARS header: SOURCE/AUTHOR/STARDATE/STATUS present" {
  grep -q "^# SOURCE:" "$PORTE_SRC"
  grep -q "^# AUTHOR:" "$PORTE_SRC"
  grep -q "^# STARDATE:" "$PORTE_SRC"
  grep -q "^# STATUS:" "$PORTE_SRC"
}

@test "corpus vide = échec — zéro test joué ne se lit pas comme zéro test rouge" {
  stub_bats 0
  run bash "$DECOR/gate.sh"
  [ "$status" -ne 0 ]
  [[ "$output" == *"ne mesure rien"* ]]
  refute_out "BATS APPELE" <<<"$output"
}

@test "bats absent = échec nommé — jamais un saut silencieux" {
  temoin x.bats unit
  local nobats; nobats="$(path_sans bats)"
  run env PATH="$nobats" "$nobats/bash" "$DECOR/gate.sh"
  [ "$status" -ne 0 ]
  [[ "$output" == *"bats absent"* ]]
  [[ "$output" == *"non joués"* ]]
}

@test "le verdict suit bats — un corpus rouge rend rouge" {
  temoin x.bats unit '@test "faux" { true; }'
  stub_bats 1
  run bash "$DECOR/gate.sh"
  [ "$status" -eq 1 ]
  [[ "$output" == *"ECHEC"* ]]
}

@test "le chemin nominal passe — sans lui, les refus seraient satisfaits par une porte qui refuse tout" {
  temoin x.bats unit '@test "faux" { true; }'
  stub_bats 0
  run bash "$DECOR/gate.sh"
  [ "$status" -eq 0 ]
  [[ "$output" == *"BATS APPELE"* ]]
  [[ "$output" == *"OK"* ]]
}

@test "le compte de cas est réel, pas le nombre de fichiers" {
  temoin x.bats unit $'@test "a" { true; }\n@test "b" { true; }'
  temoin y.bats unit '@test "c" { true; }'
  stub_bats 0
  run bash "$DECOR/gate.sh"
  [ "$status" -eq 0 ]
  [[ "$output" == *"2 fichier(s), 3 cas"* ]]
}

@test "un témoin sans couche déclarée = échec nommé, et bats n'est pas lancé" {
  temoin x.bats unit '@test "a" { true; }'
  printf '@test "b" { true; }\n' > "$DECOR/tests/nu.bats"
  stub_bats 0
  run bash "$DECOR/gate.sh"
  [ "$status" -ne 0 ]
  [[ "$output" == *"sans couche déclarée"*"nu.bats"* ]]
  refute_out "BATS APPELE" <<<"$output"
}

@test "une couche ne joue que ses témoins, et compte leurs cas" {
  temoin x.bats unit $'@test "a" { true; }\n@test "b" { true; }'
  temoin y.bats integration '@test "c" { true; }'
  temoin z.bats structure '@test "d" { true; }'
  stub_bats 0
  run bash "$DECOR/gate.sh" unit
  [ "$status" -eq 0 ]
  [[ "$output" == *"BATS APPELE: $DECOR/tests/x.bats"* ]]
  refute_out "y.bats" <<<"$output"
  refute_out "z.bats" <<<"$output"
  [[ "$output" == *"(couche unit) : 1 fichier(s), 2 cas"* ]]
}

@test "une couche inconnue est refusée, une couche vide aussi" {
  temoin x.bats unit '@test "a" { true; }'
  stub_bats 0
  run bash "$DECOR/gate.sh" fumee
  [ "$status" -eq 1 ]
  [[ "$output" == *"couche inconnue « fumee »"* ]]
  run bash "$DECOR/gate.sh" structure
  [ "$status" -eq 1 ]
  [[ "$output" == *"aucun témoin dans la couche « structure »"* ]]
}

@test "--list-corpora rend le corpus que la découverte joue" {
  run bash "$DECOR/gate.sh" --list-corpora
  [ "$status" -eq 0 ]
  [ "$output" = "decor/tests" ]
}

@test "l'environnement du lanceur est neutralisé, et le dire fait partie du geste" {
  temoin x.bats unit '@test "faux" { true; }'
  stub_bats 0
  run env PROV_FLEET_GROUP=piege LCARS_SEAT_UID_FILE=/x bash "$DECOR/gate.sh"
  [ "$status" -eq 0 ]
  [[ "$output" == *"neutralisée"* ]]
  [[ "$output" == *"PROV_FLEET_GROUP"* ]]
  [[ "$output" == *"LCARS_SEAT_UID_FILE"* ]]
}

@test "la seconde copie du bloc de neutralisation s'accorde avec celle de shell_gate.sh" {
  [ -f "$SHELL_GATE" ] || skip "shell_gate.sh absent de cet arbre (contexte installeur seul)"
  local a b
  a="$(grep -oE "\\^\\(LCARS_\\|PROV_\\|FORGE_\\)" "$PORTE_SRC" | head -1)"
  b="$(grep -oE "\\^\\(LCARS_\\|PROV_\\|FORGE_\\)" "$SHELL_GATE" | head -1)"
  [ -n "$a" ]
  [ -n "$b" ]
  [ "$a" = "$b" ]
}

go7_shape() { # go7_shape <fichier> <fonction> — la forme d'un prédicat : fenêtre lue, drapeaux triés, motifs
  local line flags pat
  sed -n "/^$2()/,/^}/p" "$1" \
    | grep -oE "head -[0-9]+|grep -[A-Za-z]+[[:space:]]+('[^']*'|\"[^\"]*\")" \
    | while IFS= read -r line; do
        case "$line" in
          head*) printf '%s\n' "$line" ;;
          *) flags="${line#grep -}"; flags="${flags%%[[:space:]]*}"; flags="${flags//q/}"
             pat="${line#grep -*[[:space:]]}"; pat="${pat#"${pat%%[![:space:]]*}"}"; pat="${pat:1:${#pat}-2}"
             printf 'grep -%s %s\n' "$(printf '%s' "$flags" | fold -w1 | sort | tr -d '\n')" "$pat" ;;
        esac
      done
}

@test "les deux prédicats GO-7 s'accordent avec leurs originaux du pre-commit" {
  local hook="$BATS_TEST_DIRNAME/../../runtime/git-hooks/pre-commit"
  [ -f "$hook" ] || skip "pre-commit absent de cet arbre (contexte installeur seul)"
  local pair a b
  for pair in go7_md_header:check_md_header go7_source_header:check_source_header; do
    a="$(go7_shape "$PORTE_SRC" "${pair%%:*}")"
    b="$(go7_shape "$hook" "${pair##*:}")"
    [ -n "$a" ]
    [ -n "$b" ]
    [ "$a" = "$b" ]
  done
  a="$(go7_shape "$PORTE_SRC" go7_md_header)"
  [[ "$a" == *'head -15'* ]]
  [[ "$a" == *'**Date**'* ]]
  [[ "$a" == *'^\s+date:'* ]]
  [[ "$a" == *'<!--\s*Date\s*:'* ]]
  a="$(go7_shape "$PORTE_SRC" go7_source_header)"
  [[ "$a" == *'head -20'* ]]
  [[ "$a" == *'SOURCE:|AUTHOR:|STARDATE:'* ]]
}

@test "shellcheck absent = échec nommé — la porte ne joue pas un plancher qu'elle ne peut pas mesurer" {
  stub_bats 0
  temoin un.bats unit '@test "un" { true; }'
  local nosc; nosc="$(path_sans shellcheck)"
  run env PATH="$nosc" "$nosc/bash" "$DECOR/gate.sh"
  [ "$status" -ne 0 ]
  [[ "$output" == *"shellcheck absent"* ]]
}

@test "décor sans aucun fichier shell = échec nommé — la découverte est cassée, pas l'installeur" {
  # la copie de la porte est elle-même un fichier shell par les règles de sa découverte : pour un
  # décor sans fichier shell, elle perd son shebang et se joue par « bash <fichier> »
  stub_bats 0
  temoin un.bats unit '@test "un" { true; }'
  tail -n +2 "$PORTE_SRC" > "$DECOR/porte"; chmod 0755 "$DECOR/porte"
  rm -f "$DECOR/gate.sh"
  refute grep -qE '^#!' "$DECOR/porte"
  run bash "$DECOR/porte"
  [ "$status" -ne 0 ]
  [[ "$output" == *"aucun fichier shell"* ]]
  [[ "$output" == *"découverte est cassée"* ]]
  refute_out "BATS APPELE" <<<"$output"
  refute_out "shellcheck plancher" <<<"$output"
}

@test "le plancher shellcheck refuse un avertissement dans un script du corpus" {
  stub_bats 0
  temoin un.bats unit '@test "un" { true; }'
  printf '%s\n' '#!/usr/bin/env bash' '# SOURCE: deploy/tests/warn.sh' 'echo $(ls)' > "$DECOR/tests/warn.sh"
  run bash "$DECOR/gate.sh"
  [ "$status" -ne 0 ]
  [[ "$output" == *"shellcheck plancher"* ]]
  [[ "$output" == *"warn.sh"* ]]
}

@test "GO-7 refuse un script sans en-tête déclaratif, et le nomme" {
  stub_bats 0
  temoin un.bats unit '@test "un" { true; }'
  printf '%s\n' '#!/usr/bin/env bash' 'echo ok' > "$DECOR/tests/nohead.sh"
  run bash "$DECOR/gate.sh"
  [ "$status" -ne 0 ]
  [[ "$output" == *"GO-7"* ]]
  [[ "$output" == *"nohead.sh"* ]]
}
