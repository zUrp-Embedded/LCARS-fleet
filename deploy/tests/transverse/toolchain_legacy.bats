#!/usr/bin/env bats
# bats file_tags=unit
# SOURCE: deploy/tests/transverse/toolchain_legacy.bats
# AUTHOR: alice
# STARDATE: 2026-08-28
# STATUS: bats tests for 15-toolchain — le geste destructif du module (la SELECTION), et ce qu'il refuse de toucher

load ../refute
load ../support/decor

setup() {
  local _v
  while read -r _v; do unset "$_v" 2>/dev/null || true; done \
    < <(compgen -v | grep -E '^(LCARS_|PROV_)' || true)

  MOD="$BATS_TEST_DIRNAME/../../modules.d/15-toolchain.sh"
  [ -f "$MOD" ]

  export PROVISION_LIB="$BATS_TEST_DIRNAME/../../lib/provision-lib.sh"
  export PROVISION_MODULE=15-toolchain PROV_SUBSTRATE=linux

  # le décor porte les liens et les arbres : sans lui, ce fichier mesurerait le poste qui le joue
  decor_pose
  LINKS="$LCARS_DECOR_ROOT/usr/local/bin"
  PREFIXE="$LCARS_DECOR_ROOT/opt/elixir-"
  mkdir -p "$LCARS_DECOR_ROOT/opt"
}

sourced() { # sourced <code bash> — le module sans son dispatch, puis le code
  bash -c "set -euo pipefail; source <(sed '\$d' '$MOD'); $1"
}

@test "un symlink vers NOTRE ancien arbre est selectionne" {
  mkdir -p "${PREFIXE}1.18.4/bin"
  : > "${PREFIXE}1.18.4/bin/elixir"
  ln -s "${PREFIXE}1.18.4/bin/elixir" "$LINKS/elixir"

  run sourced 'elixir_links_stale'
  [ "$status" -eq 0 ]
  [[ "$output" == *"$LINKS/elixir"* ]]
}

@test "un symlink de l'OPERATEUR, sous le meme nom, n'est PAS touche — la cible decide" {
  mkdir -p "$BATS_TEST_TMPDIR/ailleurs/bin"
  : > "$BATS_TEST_TMPDIR/ailleurs/bin/elixir"
  ln -s "$BATS_TEST_TMPDIR/ailleurs/bin/elixir" "$LINKS/elixir"

  run sourced 'elixir_links_stale'
  [ "$status" -eq 0 ]
  # le vide est exigé, pas l'absence d'un nom : le lien porte le nom `elixir`
  [ -z "$output" ] || { echo "un lien qui ne pointe pas chez nous a ete selectionne : $output" >&2; return 1; }
}

@test "un FICHIER ordinaire au nom d'un binaire n'est pas un symlink, et n'entre pas" {
  : > "$LINKS/mix"
  run sourced 'elixir_links_stale'
  [ "$status" -eq 0 ]
  [ -z "$output" ]
}

@test "un lien MORT vers notre arbre est selectionne — c'est ce qu'un retrait interrompu laisse" {
  # `readlink -f` rend le VIDE sur un lien casse : un `-f` ici laisserait sur la machine exactement
  # les liens qu'un `rm -rf` a demi joue a produits, et personne ne les nommerait jamais plus.
  ln -s "${PREFIXE}1.18.4/bin/iex" "$LINKS/iex"
  [ ! -e "$LINKS/iex" ]

  run sourced 'elixir_links_stale'
  [ "$status" -eq 0 ]
  [[ "$output" == *"$LINKS/iex"* ]]
}

@test "les quatre noms sont couverts, pas seulement le premier" {
  mkdir -p "${PREFIXE}1.18.4/bin"
  local b
  for b in elixir elixirc mix iex; do
    : > "${PREFIXE}1.18.4/bin/$b"
    ln -s "${PREFIXE}1.18.4/bin/$b" "$LINKS/$b"
  done

  run sourced 'elixir_links_stale'
  [ "$status" -eq 0 ]
  [ "$(printf '%s\n' "$output" | grep -c .)" -eq 4 ]
}

@test "un arbre marque present est selectionne, et deux versions cote a cote le sont toutes les deux" {
  mkdir -p "${PREFIXE}1.18.4" "${PREFIXE}1.17.3"
  : > "${PREFIXE}1.18.4/.lcars-pose"
  : > "${PREFIXE}1.17.3/.lcars-pose"
  run sourced 'elixir_trees_other'
  [ "$status" -eq 0 ]
  [ "$(printf '%s\n' "$output" | grep -c .)" -eq 2 ]
}

@test "AUCUN arbre : la selection est VIDE, elle ne rend pas son propre motif" {
  # Un glob qui ne matche rien rend la chaine litterale `<prefixe>*` ; sans la garde `-d`, c'est
  # elle que l'appelant passerait a `rm -rf`. Le cas nominal d'une machine neuve, donc.
  run sourced 'elixir_trees_other'
  [ "$status" -eq 0 ]
  [ -z "$output" ] || { echo "selection non vide sur une machine sans ancien arbre : $output" >&2; return 1; }
}

@test "un FICHIER au prefixe de l'arbre n'est pas un arbre" {
  # un zip laissé à côté des arbres ne s'emporte pas avec eux
  : > "${PREFIXE}1.18.4.zip"
  run sourced 'elixir_trees_other'
  [ "$status" -eq 0 ]
  [ -z "$output" ]
}

@test "le module ne demande pas ELIXIR a apt — erlang seul ; le precompile est le pin des constantes, jamais un zip libre" {
  # Garde d'instrument : on lit le bon module (erlang par apt y est).
  grep -qE 'apt_ensure erlang( \|\|| *$)' "$MOD" \
    || { echo "ce temoin ne lit pas 15-toolchain, ou erlang n'entre plus par apt"; return 1; }
  refute grep -qE 'apt_ensure erlang elixir' "$MOD"
  grep -q 'fetch_verify "\$ELIXIR_ZIP_URL" "\$PROV_ELIXIR_PIN_SHA256"' "$MOD" \
    || { echo "le zip n'est pas telecharge par fetch_verify avec le sha256 du pin"; return 1; }
  refute grep -qE 'curl .*elixir' "$MOD"
}

@test "les cinq objets de la toolchain sont dans la table, à côté de node" {
  local manifest="$BATS_TEST_DIRNAME/../../system.manifest"
  [ -f "$manifest" ]
  grep -qE '^dir[[:space:]]+/opt/node-<version>' "$manifest" \
    || { echo "ce temoin ne lit pas la table, ou /opt/node-<version> en a disparu"; return 1; }
  grep -qE '^dir[[:space:]]+/opt/elixir-<version>[[:space:]]+0755[[:space:]]+root:root[[:space:]]+wsl\+linux' "$manifest" \
    || { echo "/opt/elixir-<version> n'est pas declare (0755 root:root wsl+linux) alors que 15 le pose"; return 1; }
  local b
  for b in elixir elixirc iex mix; do
    grep -qE "^link[[:space:]]+/usr/local/bin/${b}[[:space:]]" "$manifest" \
      || { echo "link /usr/local/bin/$b n'est pas declare alors que 15 le pose"; return 1; }
  done
}
