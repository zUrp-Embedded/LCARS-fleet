#!/usr/bin/env bats
# bats file_tags=integration
# SOURCE: deploy/tests/installer_gate.bats
# AUTHOR: bob
# STARDATE: 2026-09-12
# STATUS: témoins de deploy/gate.sh — la porte se mesure elle-même : refus nommés, couches, copies qui s'accordent

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

temoin() { # temoin <fichier> <couche> [<corps>] — un témoin du décor, avec son shebang et sa couche déclarée
  printf '#!/usr/bin/env bats\n# bats file_tags=%s\n%s' "$2" "${3-}" > "$DECOR/tests/$1"
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
  [[ "$output" == *"ÉCHEC"* ]]
}

@test "les cas sautés sont comptés dans le verdict — un saut n'est pas un cas joué" {
  temoin x.bats unit $'@test "a" { true; }\n@test "b" { true; }'
  printf '#!/usr/bin/env bash\necho "BATS APPELE: $*"\necho "1..2"\necho "ok 1 a"\necho "ok 2 b # skip pas ici"\nexit 0\n' > "$BIN/bats"
  chmod 0755 "$BIN/bats"
  run bash "$DECOR/gate.sh"
  [ "$status" -eq 0 ]
  [[ "$output" == *"OK (2 cas, 1 sauté(s))"* ]]
}

@test "le chemin nominal passe — sans lui, les refus seraient satisfaits par une porte qui refuse tout" {
  temoin x.bats unit '@test "faux" { true; }'
  stub_bats 0
  run bash "$DECOR/gate.sh"
  [ "$status" -eq 0 ]
  [[ "$output" == *"BATS APPELE"* ]]
  [[ "$output" == *"OK"* ]]
}

@test "l'installeur à la racine du dépôt est dans le plancher shellcheck de la porte" {
  command -v shellcheck >/dev/null || skip "shellcheck absent"
  temoin x.bats unit '@test "a" { true; }'
  printf '#!/usr/bin/env bash\n# SOURCE: install.sh\nset -eu\ninutile=1\n' > "$BATS_TEST_TMPDIR/install.sh"
  stub_bats 0
  run bash "$DECOR/gate.sh"
  [ "$status" -eq 1 ]
  [[ "$output" == *"install.sh"*"SC2034"* ]]
}

@test "l'installeur à la racine du dépôt doit porter son en-tête" {
  command -v shellcheck >/dev/null || skip "shellcheck absent"
  temoin x.bats unit '@test "a" { true; }'
  printf '#!/usr/bin/env bash\nset -eu\necho ok\n' > "$BATS_TEST_TMPDIR/install.sh"
  stub_bats 0
  run bash "$DECOR/gate.sh"
  [ "$status" -eq 1 ]
  [[ "$output" == *"GO-7"*"install.sh"* ]]
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
  printf '#!/usr/bin/env bats\n@test "b" { true; }\n' > "$DECOR/tests/nu.bats"
  stub_bats 0
  run bash "$DECOR/gate.sh"
  [ "$status" -ne 0 ]
  [[ "$output" == *"sans couche déclarée"*"nu.bats"* ]]
  refute_out "BATS APPELE" <<<"$output"
}

@test "la couche se lit en deuxième ligne, jamais dans un décor écrit plus bas" {
  temoin x.bats unit '@test "a" { true; }'
  printf '#!/usr/bin/env bats\n# SOURCE: decor\n@test "b" {\n  cat <<EOF > x\n# bats file_tags=structure\nEOF\n}\n' > "$DECOR/tests/tard.bats"
  stub_bats 0
  run bash "$DECOR/gate.sh"
  [ "$status" -ne 0 ]
  [[ "$output" == *"sans couche déclarée"*"tard.bats"* ]]
}

@test "un témoin sans shebang bats = échec nommé — il sortirait du plancher shellcheck en silence" {
  temoin x.bats unit '@test "a" { true; }'
  printf '# bats file_tags=unit\n@test "b" { true; }\n' > "$DECOR/tests/nu.bats"
  stub_bats 0
  run bash "$DECOR/gate.sh"
  [ "$status" -ne 0 ]
  [[ "$output" == *"sans shebang bats"*"nu.bats"* ]]
  refute_out "BATS APPELE" <<<"$output"
}

@test "un argument de trop est refusé — une faute de frappe ne joue pas autre chose" {
  temoin x.bats unit '@test "a" { true; }'
  stub_bats 0
  run bash "$DECOR/gate.sh" unit poubelle
  [ "$status" -eq 1 ]
  [[ "$output" == *"un seul argument"* ]]
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
  [[ "$output" == *"aucun fichier de tests dans la couche « structure »"* ]]
}

@test "--list-corpora rend le corpus que la découverte joue" {
  run bash "$DECOR/gate.sh" --list-corpora
  [ "$status" -eq 0 ]
  [ "$output" = "decor/tests" ]
}

@test "l'environnement du lanceur est neutralisé, et le dire fait partie du geste" {
  temoin x.bats unit '@test "faux" { true; }'
  stub_bats 0
  run env PROV_FLEET_GROUP=piege LCARS_DECOR_ROOT=/x bash "$DECOR/gate.sh"
  [ "$status" -eq 0 ]
  [[ "$output" == *"neutralisée"* ]]
  [[ "$output" == *"PROV_FLEET_GROUP"* ]]
  [[ "$output" == *"LCARS_DECOR_ROOT"* ]]
}

# bats test_tags=structure
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

# bats test_tags=structure
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
