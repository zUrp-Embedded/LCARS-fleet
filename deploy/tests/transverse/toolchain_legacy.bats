#!/usr/bin/env bats
# bats file_tags=unit
# SOURCE: deploy/tests/transverse/toolchain_legacy.bats
# AUTHOR: alice
# STARDATE: 2026-08-28
# STATUS: bats tests for 15-toolchain — le geste destructif du module (la SELECTION), et ce qu'il refuse de toucher

# ⚠ SC2016 : CE TEMOIN LIT DU CODE. Ses motifs `grep` portent des `${VAR:-defaut}` qui doivent
# atteindre l'outil TELS QUELS — les developper chercherait la valeur dans CE shell.
# shellcheck disable=SC2016

setup() {
  local _v
  while read -r _v; do unset "$_v" 2>/dev/null || true; done \
    < <(compgen -v | grep -E '^(LCARS_|PROV_)' || true)

  MOD="$BATS_TEST_DIRNAME/../../modules.d/15-toolchain.sh"
  [ -f "$MOD" ]

  export PROVISION_LIB="$BATS_TEST_DIRNAME/../../lib/provision-lib.sh"
  export PROVISION_MODULE=15-toolchain

  # LES DEUX COUTURES, ET SANS ELLES CE FICHIER MESURERAIT LE POSTE QUI LE JOUE.
  export PROV_LINK_DIR="$BATS_TEST_TMPDIR/bin"
  export LCARS_ELIXIR_PREFIX="$BATS_TEST_TMPDIR/opt/elixir-"
  mkdir -p "$PROV_LINK_DIR" "$BATS_TEST_TMPDIR/opt"
}

sourced() { # sourced <code bash>
  bash -c "
    set -euo pipefail
    check() { :; }; apply() { :; }
    # shellcheck disable=SC1090
    . '$PROVISION_LIB'
    ELIXIR_BINS=(elixir elixirc mix iex)
    : \"\${LCARS_ELIXIR_PREFIX:=/opt/elixir-}\"
    $(sed -n '/^elixir_links_ours()/,/^}/p' "$MOD")
    $(sed -n '/^elixir_trees()/,/^}/p' "$MOD")
    $1
  "
}

@test "un symlink vers NOTRE ancien arbre est selectionne" {
  mkdir -p "${LCARS_ELIXIR_PREFIX}1.18.4/bin"
  : > "${LCARS_ELIXIR_PREFIX}1.18.4/bin/elixir"
  ln -s "${LCARS_ELIXIR_PREFIX}1.18.4/bin/elixir" "$PROV_LINK_DIR/elixir"

  run sourced 'elixir_links_ours'
  [ "$status" -eq 0 ]
  [[ "$output" == *"$PROV_LINK_DIR/elixir"* ]]
}

@test "un symlink de l'OPERATEUR, sous le meme nom, n'est PAS touche — la cible decide" {
  mkdir -p "$BATS_TEST_TMPDIR/ailleurs/bin"
  : > "$BATS_TEST_TMPDIR/ailleurs/bin/elixir"
  ln -s "$BATS_TEST_TMPDIR/ailleurs/bin/elixir" "$PROV_LINK_DIR/elixir"

  run sourced 'elixir_links_ours'
  [ "$status" -eq 0 ]
  # ⚠ ON EXIGE LE VIDE, pas l'absence d'un nom : le lien PORTE le nom `elixir`, donc un
  # `refute_output --partial elixir` serait vert pour la mauvaise raison.
  [ -z "$output" ] || { echo "un lien qui ne pointe pas chez nous a ete selectionne : $output" >&2; return 1; }
}

@test "un FICHIER ordinaire au nom d'un binaire n'est pas un symlink, et n'entre pas" {
  : > "$PROV_LINK_DIR/mix"
  run sourced 'elixir_links_ours'
  [ "$status" -eq 0 ]
  [ -z "$output" ]
}

@test "un lien MORT vers notre arbre est selectionne — c'est ce qu'un retrait interrompu laisse" {
  # `readlink -f` rend le VIDE sur un lien casse : un `-f` ici laisserait sur la machine exactement
  # les liens qu'un `rm -rf` a demi joue a produits, et personne ne les nommerait jamais plus.
  ln -s "${LCARS_ELIXIR_PREFIX}1.18.4/bin/iex" "$PROV_LINK_DIR/iex"
  [ ! -e "$PROV_LINK_DIR/iex" ]

  run sourced 'elixir_links_ours'
  [ "$status" -eq 0 ]
  [[ "$output" == *"$PROV_LINK_DIR/iex"* ]]
}

@test "les quatre noms sont couverts, pas seulement le premier" {
  mkdir -p "${LCARS_ELIXIR_PREFIX}1.18.4/bin"
  local b
  for b in elixir elixirc mix iex; do
    : > "${LCARS_ELIXIR_PREFIX}1.18.4/bin/$b"
    ln -s "${LCARS_ELIXIR_PREFIX}1.18.4/bin/$b" "$PROV_LINK_DIR/$b"
  done

  run sourced 'elixir_links_ours'
  [ "$status" -eq 0 ]
  [ "$(printf '%s\n' "$output" | grep -c .)" -eq 4 ]
}

@test "un arbre present est selectionne, et deux versions cote a cote le sont toutes les deux" {
  mkdir -p "${LCARS_ELIXIR_PREFIX}1.18.4" "${LCARS_ELIXIR_PREFIX}1.17.3"
  run sourced 'elixir_trees'
  [ "$status" -eq 0 ]
  [ "$(printf '%s\n' "$output" | grep -c .)" -eq 2 ]
}

@test "AUCUN arbre : la selection est VIDE, elle ne rend pas son propre motif" {
  # Un glob qui ne matche rien rend la chaine litterale `<prefixe>*` ; sans la garde `-d`, c'est
  # elle que l'appelant passerait a `rm -rf`. Le cas nominal d'une machine neuve, donc.
  run sourced 'elixir_trees'
  [ "$status" -eq 0 ]
  [ -z "$output" ] || { echo "selection non vide sur une machine sans ancien arbre : $output" >&2; return 1; }
}

@test "un FICHIER au prefixe de l'arbre n'est pas un arbre" {
  # `pack.sh` et l'ancien module laissaient un `/opt/.elixir-<ver>.zip` ; un motif trop large
  # emporterait des fichiers voisins que personne n'a decide de detruire.
  : > "${LCARS_ELIXIR_PREFIX}1.18.4.zip"
  run sourced 'elixir_trees'
  [ "$status" -eq 0 ]
  [ -z "$output" ]
}

@test "le module ne demande plus ELIXIR a apt — erlang seul ; le precompile est le pin de la lib, jamais un zip libre" {
  # Garde d'instrument : on lit le bon module (erlang par apt y est).
  grep -qE 'apt_ensure erlang( \|\|| *$)' "$MOD" \
    || { echo "ce temoin ne lit pas 15-toolchain, ou erlang n'entre plus par apt"; return 1; }
  ! grep -qE 'apt_ensure erlang elixir' "$MOD" \
    || { echo "elixir est de retour dans la liste apt de $MOD : la distro LTS sert 1.18, le plancher est 1.20"; return 1; }
  grep -q 'fetch_verify "\$ELIXIR_ZIP_URL" "\$PROV_ELIXIR_PIN_SHA256"' "$MOD" \
    || { echo "le zip n'est pas telecharge par fetch_verify avec le sha256 du pin"; return 1; }
  ! grep -qE 'curl .*elixir' "$MOD" \
    || { echo "un curl a la main dans $MOD : le telechargement passe par fetch_verify"; return 1; }
}

@test "les cinq objets sont de RETOUR dans la table, a cote de node" {
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
