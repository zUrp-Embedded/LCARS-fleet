#!/usr/bin/env bats
# bats file_tags=integration
# SOURCE: deploy/tests/lib/deploy_release_guards.bats
# AUTHOR: consultant
# STARDATE: 2026-07-30
# STATUS: deploy/lib/deploy-release.sh joué entier sous un décor — la pose sous le préfixe, le refus de root, le manifeste strict
#

load ../refute

setup() {
  SCRIPT="$BATS_TEST_DIRNAME/../../lib/deploy-release.sh"
  export LCARS_DECOR_ROOT="$BATS_TEST_TMPDIR/decor"
  PREFIX="$LCARS_DECOR_ROOT$(grep '^PROV_PREFIX=' "$BATS_TEST_DIRNAME/../../installer-constants.env" | cut -d= -f2)"
  LINK_DIR="$LCARS_DECOR_ROOT$(grep '^PROV_LINK_DIR=' "$BATS_TEST_DIRNAME/../../installer-constants.env" | cut -d= -f2)"
  local stamp; stamp="$(grep '^PROV_SOURCE_STAMP=' "$BATS_TEST_DIRNAME/../../installer-constants.env" | cut -d= -f2)"
  # un kit : la release est déjà bâtie, le tampon à la racine dit de ne rien compiler
  KIT="$BATS_TEST_TMPDIR/kit"
  export LCARS_RUNTIME_DIR="$KIT/runtime"
  mkdir -p "$LCARS_RUNTIME_DIR/etc" "$LCARS_RUNTIME_DIR/bin" "$LCARS_RUNTIME_DIR/_build/prod/rel/lcars_fleet/bin"
  printf 'abcd1234\n' > "$KIT/$stamp"
  printf '#!/bin/sh\nexit 0\n' > "$LCARS_RUNTIME_DIR/_build/prod/rel/lcars_fleet/bin/lcars_fleet"
  chmod +x "$LCARS_RUNTIME_DIR/_build/prod/rel/lcars_fleet/bin/lcars_fleet"
  printf 'fleet exec link\nnote.txt noexec\n' > "$LCARS_RUNTIME_DIR/etc/release.manifest"
  printf '#!/bin/sh\n' > "$LCARS_RUNTIME_DIR/bin/fleet"
  printf 'note\n' > "$LCARS_RUNTIME_DIR/bin/note.txt"
  printf 'LCARS_X=1\n' > "$LCARS_RUNTIME_DIR/etc/fleet.env.template"
}

joue() { run bash "$SCRIPT"; }

@test "la pose sous le préfixe : la release sous rel/, les entrées du manifeste sous bin/, le gabarit sous etc/" {
  joue
  [ "$status" -eq 0 ]
  [ -x "$PREFIX/rel/lcars_fleet/bin/lcars_fleet" ]
  [ -x "$PREFIX/bin/fleet" ]
  [ -f "$PREFIX/bin/note.txt" ]
  [ ! -x "$PREFIX/bin/note.txt" ]
  [ "$(cat "$PREFIX/etc/fleet.env.template")" = "LCARS_X=1" ]
}

@test "la pose ne crée aucun lien et ne retire rien de ce qui est déjà là" {
  mkdir -p "$PREFIX/bin" "$LINK_DIR"
  printf 'vieux\n' > "$PREFIX/bin/vieux"
  ln -s "$PREFIX/bin/vieux" "$LINK_DIR/vieux"
  joue
  [ "$status" -eq 0 ]
  [ -f "$PREFIX/bin/vieux" ]
  [ "$(readlink "$LINK_DIR/vieux")" = "$PREFIX/bin/vieux" ]
  [ ! -L "$LINK_DIR/fleet" ]   # une entrée « link » : 60-deploy la câble, pas ce script
  [ "$(find "$LCARS_DECOR_ROOT" -type l | wc -l)" -eq 1 ]
}

@test "lancé en root, il refuse avant toute pose" {
  run unshare -Ur bash "$SCRIPT"
  [ "$status" -eq 1 ]
  [[ "$output" == *"lancé en root — le build laisserait des artefacts root dans l'arbre source"* ]]
  [ ! -e "$PREFIX" ]
}

@test "manifest: unknown mode token dies naming the entry" {
  printf 'goodfile exec\nbadfile wat\n' > "$LCARS_RUNTIME_DIR/etc/release.manifest"
  joue
  [ "$status" -eq 1 ]
  [[ "$output" == *"mode inconnu « wat » pour « badfile »"* ]]
  [ ! -e "$PREFIX" ]
}

@test "manifest: unknown flag dies naming the entry" {
  printf 'somefile exec copy\n' > "$LCARS_RUNTIME_DIR/etc/release.manifest"
  joue
  [ "$status" -eq 1 ]
  [[ "$output" == *"flag inconnu « copy » pour « somefile »"* ]]
}

@test "manifest: extra token dies (strict format, no silent skip)" {
  printf 'somefile exec link whatever\n' > "$LCARS_RUNTIME_DIR/etc/release.manifest"
  joue
  [ "$status" -eq 1 ]
  [[ "$output" == *"token en trop « whatever »"* ]]
}

@test "manifest: comments-only file is an empty manifest, dies" {
  printf '# just comments\n\n' > "$LCARS_RUNTIME_DIR/etc/release.manifest"
  joue
  [ "$status" -eq 1 ]
  [[ "$output" == *"manifest vide"* ]]
}

@test "le manifeste livré se lit : chacune de ses entrées est posée" {
  cp "$BATS_TEST_DIRNAME/../../../runtime/etc/release.manifest" "$LCARS_RUNTIME_DIR/etc/release.manifest"
  local n
  while read -r n _; do
    [[ -n "$n" && "$n" != \#* ]] || continue
    printf 'x\n' > "$LCARS_RUNTIME_DIR/bin/$n"
  done < "$LCARS_RUNTIME_DIR/etc/release.manifest"
  joue
  [ "$status" -eq 0 ]
  refute_out 'manifest' <<<"$output"
  [ -x "$PREFIX/bin/fleet" ]
}
