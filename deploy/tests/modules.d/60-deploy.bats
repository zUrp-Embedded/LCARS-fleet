#!/usr/bin/env bats
# SOURCE: deploy/tests/modules.d/60-deploy.bats
# AUTHOR: bob
# STARDATE: 2026-09-04
# STATUS: bats tests for 60-deploy — le raccourci « rien a batir » lit le VRAI arbre du runtime
#
# Relecture hostile 2026-09-04 : `git diff --quiet HEAD -- fleet` rendait toujours 0 (un pathspec
# vide n'est pas une erreur pour git diff), donc « l'arbre du runtime est propre » etait
# inconditionnellement vrai, et un apply sur un checkout modifie sautait la construction.

load ../refute

setup() { MOD="$BATS_TEST_DIRNAME/../../modules.d/60-deploy.sh"; [ -f "$MOD" ]; }

@test "le pathspec du raccourci est runtime/ — un arbre qui n'existe pas rendrait toujours « propre »" {
  grep -vE '^\s*#' "$MOD" | grep -qE 'diff --quiet HEAD -- runtime'
  refute grep -qE 'diff --quiet HEAD -- fleet' <(grep -vE '^\s*#' "$MOD")
  [ -d "$BATS_TEST_DIRNAME/../../../runtime" ]
}

@test "TEMOIN DU TEMOIN : sur ce depot, un pathspec inexistant rend 0 et le vrai rend un verdict" {
  local repo; repo="$BATS_TEST_DIRNAME/../../.."
  git -C "$repo" diff --quiet HEAD -- nexistepas ; [ "$?" -eq 0 ]
  git -C "$repo" ls-files runtime | grep -q .
}

# ─── S4 : LE DOCTOR VOIT CE QUI EST LA EN TROP, ET NOMME LA GENERATION PRECEDENTE ───────────────
#
# ⚠ RELECTURE HOSTILE DU 2026-09-04. La sonde iterait sur les entrees de `release.manifest`, donc
# elle ne regardait jamais ce que `$PROV_PREFIX/bin` porte EN PLUS : au banc, `fleet_v2` (renomme
# `fleet`) et son symlink `/usr/local/bin/fleet_v2` survivaient, et `60-deploy=OK`. Et `.prev`,
# 31 Mo de rollback poses par `atomic_swap_dir`, n'etait nomme nulle part.
#
# Le module se source SANS son dispatch, dans un decor : le prefixe et le PATH sont des
# repertoires de BATS_TEST_TMPDIR, le manifeste est le VRAI (c'est lui qui dit qui est intrus).

decor() {
  export PROVISION_LIB="$BATS_TEST_DIRNAME/../../lib/provision-lib.sh"
  export PROVISION_MODULE=60-deploy
  export PROV_HUMAN; PROV_HUMAN="$(id -un)"
  export PROV_FLEET_GROUP; PROV_FLEET_GROUP="$(id -gn)"
  export PROV_PREFIX="$BATS_TEST_TMPDIR/prefix"
  export PROV_LINK_DIR="$BATS_TEST_TMPDIR/path"
  export XDG_RUNTIME_DIR="$BATS_TEST_TMPDIR/xdg"; mkdir -p "$XDG_RUNTIME_DIR"; chmod 0700 "$XDG_RUNTIME_DIR"
  mkdir -p "$PROV_PREFIX/bin" "$PROV_PREFIX/rel/lcars_fleet/bin" "$PROV_LINK_DIR"
  printf '#!/bin/sh\nexit 0\n' > "$PROV_PREFIX/rel/lcars_fleet/bin/lcars_fleet"
  chmod +x "$PROV_PREFIX/rel/lcars_fleet/bin/lcars_fleet"
  # tout ce que le manifeste nomme est la : ce qui se mesure ensuite est le SENS INVERSE
  local n
  while read -r n _; do
    [[ -n "$n" && "$n" != \#* ]] || continue
    printf '#!/bin/sh\n' > "$PROV_PREFIX/bin/$n"; chmod +x "$PROV_PREFIX/bin/$n"
  done < "$BATS_TEST_DIRNAME/../../../runtime/etc/release.manifest"
  DECOR_MOD="$BATS_TEST_TMPDIR/mod.sh"
  sed '/^case "${1:?usage/,$d' "$MOD" > "$DECOR_MOD"
}
mod() { run bash -c "set -euo pipefail; source '$DECOR_MOD' >/dev/null 2>&1; $1"; }

@test "S4 : un intrus sous \$PROV_PREFIX/bin est un DRIFT, et le symlink du PATH qui le vise aussi" {
  decor
  : > "$PROV_PREFIX/bin/fleet_v2"
  ln -s "$PROV_PREFIX/bin/fleet_v2" "$PROV_LINK_DIR/fleet_v2"
  mod check
  [ "$status" -ne 0 ]
  [[ "$output" == *"DRIFT"*"intrus $PROV_PREFIX/bin/fleet_v2"* ]]
  [[ "$output" == *"DRIFT"*"symlink intrus $PROV_LINK_DIR/fleet_v2"* ]]
}

@test "S4 : sans intrus, pas de ligne intrus — et un lien du PATH qui vise ailleurs n'est pas a nous" {
  decor
  ln -s /bin/true "$PROV_LINK_DIR/quelconque"
  mod check
  refute grep -q 'intrus' <<<"$output"
}

@test "S4 : la generation precedente (.prev) est NOMMEE, avec sa taille" {
  decor
  mkdir -p "$PROV_PREFIX/rel/lcars_fleet.prev/bin"
  head -c 4096 /dev/zero > "$PROV_PREFIX/rel/lcars_fleet.prev/bin/lcars_fleet"
  mod check
  [[ "$output" == *"génération précédente gardée : $PROV_PREFIX/rel/lcars_fleet.prev ("* ]]
  [[ "$output" == *"rm -rf $PROV_PREFIX/rel/lcars_fleet.prev"* ]]
}

@test "S4 : l'apply retire les intrus des deux cotes, une ligne par retrait, et rien d'autre" {
  decor
  : > "$PROV_PREFIX/bin/fleet_v2"
  ln -s "$PROV_PREFIX/bin/fleet_v2" "$PROV_LINK_DIR/fleet_v2"
  ln -s "$PROV_PREFIX/bin/fleet" "$PROV_LINK_DIR/fleet"
  ln -s /bin/true "$PROV_LINK_DIR/quelconque"
  mod 'prune_intrus; echo "rc=$?"'
  [[ "$output" == *"retiré $PROV_PREFIX/bin/fleet_v2"* ]]
  [[ "$output" == *"retiré symlink $PROV_LINK_DIR/fleet_v2"* ]]
  [[ "$output" == *"rc=0"* ]]
  [ ! -e "$PROV_PREFIX/bin/fleet_v2" ] && [ ! -L "$PROV_LINK_DIR/fleet_v2" ]
  [ -e "$PROV_PREFIX/bin/fleet" ] && [ -L "$PROV_LINK_DIR/fleet" ] && [ -L "$PROV_LINK_DIR/quelconque" ]
}
