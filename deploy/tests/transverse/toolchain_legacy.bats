#!/usr/bin/env bats
# SOURCE: deploy/tests/toolchain_legacy.bats
# AUTHOR: alice
# STARDATE: 2026-08-28
# STATUS: bats tests for 15-toolchain — le SEUL geste destructif du module, et ce qu'il refuse de toucher
#
# `15-toolchain` posait un precompile Elixir telecharge (`/opt/elixir-<version>` + quatre symlinks
# dans `PROV_LINK_DIR`). La cible sert la paire par apt, donc le module ne pose plus rien de tout
# ca — et `system.manifest` a perdu les cinq lignes correspondantes.
#
# ⚠ RETIRER UNE LIGNE DE LA TABLE N'A JAMAIS RETIRE UN OBJET D'UNE MACHINE, et c'est ce trou que ces
# temoins gardent. La ou l'ancien mecanisme a tourne les cinq objets sont toujours la ; le symlink
# est le pire des deux, parce qu'il GAGNE : `PROV_LINK_DIR` passe avant `/usr/bin` dans le PATH,
# donc la machine continuerait de compiler avec l'ancien binaire pendant que le paquet apt est pose,
# sonde vert et jamais appele.
#
# ⚠ LE SUJET DE CE GESTE EST UN POSTE DE DEV, PAS UN PARC. Aucun systeme LCARS n'est deploye a ce
# jour (⚖ user 2026-08-28) : les machines concernees sont celles ou le rail a ete joue en partie,
# a commencer par celle qui a ecrit ce fichier.
#
# ⚠ ET UN GESTE QUI SUPPRIME SE MESURE D'ABORD SUR CE QU'IL NE SUPPRIME PAS. Le rang 4 du chantier
# empreinte nomme la faute : detruire le bien d'autrui. Un operateur a le droit d'avoir SON elixir
# dans `PROV_LINK_DIR` — c'est la CIBLE du lien qui decide, jamais son nom.

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
  export LCARS_LEGACY_ELIXIR_PREFIX="$BATS_TEST_TMPDIR/opt/elixir-"
  mkdir -p "$PROV_LINK_DIR" "$BATS_TEST_TMPDIR/opt"
}

# Les deux fonctions se sondent SOURCEES : `apply` exige root et joue apt, ce qu'un temoin n'a ni le
# droit ni les moyens de faire. Ce qui est mesure ici est la SELECTION — la seule moitie du geste
# qui decide quoi detruire.
sourced() { # sourced <code bash>
  bash -c "
    set -euo pipefail
    check() { :; }; apply() { :; }
    # shellcheck disable=SC1090
    . '$PROVISION_LIB'
    LEGACY_ELIXIR_BINS=(elixir elixirc mix iex)
    : \"\${LCARS_LEGACY_ELIXIR_PREFIX:=/opt/elixir-}\"
    $(sed -n '/^legacy_elixir_links()/,/^}/p' "$MOD")
    $(sed -n '/^legacy_elixir_trees()/,/^}/p' "$MOD")
    $1
  "
}

@test "un symlink vers NOTRE ancien arbre est selectionne" {
  mkdir -p "${LCARS_LEGACY_ELIXIR_PREFIX}1.18.4/bin"
  : > "${LCARS_LEGACY_ELIXIR_PREFIX}1.18.4/bin/elixir"
  ln -s "${LCARS_LEGACY_ELIXIR_PREFIX}1.18.4/bin/elixir" "$PROV_LINK_DIR/elixir"

  run sourced 'legacy_elixir_links'
  [ "$status" -eq 0 ]
  [[ "$output" == *"$PROV_LINK_DIR/elixir"* ]]
}

@test "un symlink de l'OPERATEUR, sous le meme nom, n'est PAS touche — la cible decide" {
  mkdir -p "$BATS_TEST_TMPDIR/ailleurs/bin"
  : > "$BATS_TEST_TMPDIR/ailleurs/bin/elixir"
  ln -s "$BATS_TEST_TMPDIR/ailleurs/bin/elixir" "$PROV_LINK_DIR/elixir"

  run sourced 'legacy_elixir_links'
  [ "$status" -eq 0 ]
  # ⚠ ON EXIGE LE VIDE, pas l'absence d'un nom : le lien PORTE le nom `elixir`, donc un
  # `refute_output --partial elixir` serait vert pour la mauvaise raison.
  [ -z "$output" ] || { echo "un lien qui ne pointe pas chez nous a ete selectionne : $output" >&2; return 1; }
}

@test "un FICHIER ordinaire au nom d'un binaire n'est pas un symlink, et n'entre pas" {
  : > "$PROV_LINK_DIR/mix"
  run sourced 'legacy_elixir_links'
  [ "$status" -eq 0 ]
  [ -z "$output" ]
}

@test "un lien MORT vers notre arbre est selectionne — c'est ce qu'un retrait interrompu laisse" {
  # `readlink -f` rend le VIDE sur un lien casse : un `-f` ici laisserait sur la machine exactement
  # les liens qu'un `rm -rf` a demi joue a produits, et personne ne les nommerait jamais plus.
  ln -s "${LCARS_LEGACY_ELIXIR_PREFIX}1.18.4/bin/iex" "$PROV_LINK_DIR/iex"
  [ ! -e "$PROV_LINK_DIR/iex" ]

  run sourced 'legacy_elixir_links'
  [ "$status" -eq 0 ]
  [[ "$output" == *"$PROV_LINK_DIR/iex"* ]]
}

@test "les quatre noms sont couverts, pas seulement le premier" {
  mkdir -p "${LCARS_LEGACY_ELIXIR_PREFIX}1.18.4/bin"
  local b
  for b in elixir elixirc mix iex; do
    : > "${LCARS_LEGACY_ELIXIR_PREFIX}1.18.4/bin/$b"
    ln -s "${LCARS_LEGACY_ELIXIR_PREFIX}1.18.4/bin/$b" "$PROV_LINK_DIR/$b"
  done

  run sourced 'legacy_elixir_links'
  [ "$status" -eq 0 ]
  [ "$(printf '%s\n' "$output" | grep -c .)" -eq 4 ]
}

@test "un arbre present est selectionne, et deux versions cote a cote le sont toutes les deux" {
  mkdir -p "${LCARS_LEGACY_ELIXIR_PREFIX}1.18.4" "${LCARS_LEGACY_ELIXIR_PREFIX}1.17.3"
  run sourced 'legacy_elixir_trees'
  [ "$status" -eq 0 ]
  [ "$(printf '%s\n' "$output" | grep -c .)" -eq 2 ]
}

@test "AUCUN arbre : la selection est VIDE, elle ne rend pas son propre motif" {
  # Un glob qui ne matche rien rend la chaine litterale `<prefixe>*` ; sans la garde `-d`, c'est
  # elle que l'appelant passerait a `rm -rf`. Le cas nominal d'une machine neuve, donc.
  run sourced 'legacy_elixir_trees'
  [ "$status" -eq 0 ]
  [ -z "$output" ] || { echo "selection non vide sur une machine sans ancien arbre : $output" >&2; return 1; }
}

@test "un FICHIER au prefixe de l'arbre n'est pas un arbre" {
  # `pack.sh` et l'ancien module laissaient un `/opt/.elixir-<ver>.zip` ; un motif trop large
  # emporterait des fichiers voisins que personne n'a decide de detruire.
  : > "${LCARS_LEGACY_ELIXIR_PREFIX}1.18.4.zip"
  run sourced 'legacy_elixir_trees'
  [ "$status" -eq 0 ]
  [ -z "$output" ]
}

@test "le module ne pose plus AUCUN precompile — le cliquet du retour au zip" {
  # ⚠ GARDE D'INSTRUMENT INVERSEE : un temoin d'absence est vert quand le fichier a disparu. On
  # prouve d'abord qu'on lit le bon module.
  grep -q 'apt_ensure erlang elixir' "$MOD" \
    || { echo "ce temoin ne lit pas 15-toolchain, ou le module ne demande plus la paire a apt"; return 1; }

  ! grep -qE 'fetch_verify|unzip|ELIXIR_URL|PROV_ELIXIR_ZIP_SHA256' "$MOD" \
    || { echo "le precompile telecharge est de retour dans $MOD"; return 1; }
  ! grep -qE 'ensure_symlink' "$MOD" \
    || { echo "$MOD repose des symlinks : ils ont quitte system.manifest, les deux doivent s'accorder"; return 1; }
}

@test "les cinq objets de l'ancien mecanisme ont quitte la table" {
  local manifest="$BATS_TEST_DIRNAME/../../system.manifest"
  [ -f "$manifest" ]
  # Garde d'instrument : la table est bien lue (node, lui, y reste).
  grep -qE '^dir[[:space:]]+/opt/node-<version>' "$manifest" \
    || { echo "ce temoin ne lit pas la table, ou /opt/node-<version> en a disparu aussi"; return 1; }

  ! grep -qE '^dir[[:space:]]+/opt/elixir-<version>' "$manifest" \
    || { echo "/opt/elixir-<version> est declare, mais plus aucun module ne le pose"; return 1; }
  local b
  for b in elixir elixirc iex mix; do
    ! grep -qE "^link[[:space:]]+/usr/local/bin/${b}[[:space:]]" "$manifest" \
      || { echo "link /usr/local/bin/$b est declare, mais plus aucun module ne le pose"; return 1; }
  done
}
