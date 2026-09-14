#!/usr/bin/env bats
# bats file_tags=integration
# SOURCE: deploy/tests/lib/door_gen.bats
# AUTHOR: bob
# STARDATE: 2026-09-05
# STATUS: bats tests for deploy/lib/door-gen.sh — la porte d'une version : constantes remplies, table complete, sha juste
#
# shellcheck disable=SC2016

load ../refute
load ../support/minisign_double

setup() {
  local _v
  while read -r _v; do unset "$_v" 2>/dev/null || true; done \
    < <(compgen -v | grep -E '^(LCARS_|PROV_|FORGE_)' || true)
  GEN="$BATS_TEST_DIRNAME/../../lib/door-gen.sh"
  TEMPLATE="$BATS_TEST_DIRNAME/../../../install.sh"
  [ -f "$GEN" ]
  [ -f "$TEMPLATE" ]
  minisign_double "$BATS_TEST_TMPDIR/bin"; export PATH="$BATS_TEST_TMPDIR/bin:$PATH"
  DIST="$BATS_TEST_TMPDIR/dist"; mkdir -p "$DIST"
  KIT="$DIST/lcars-fleet-0.9.0-otp27-x86_64.tar.gz"
  printf 'kit\n'  > "$KIT"
  minisign_cle "$BATS_TEST_TMPDIR/cle-RWQcle" RWQcle
  minisign -S -s "$BATS_TEST_TMPDIR/cle-RWQcle" -m "$KIT"
  printf 'a1\n' > "$DIST/annexe-a.bin"
  printf 'b2\n' > "$DIST/annexe-b.bin"
  printf 'x  y\n' > "$DIST/annexe-a.bin.sha256"
  printf 'sig\n'  > "$DIST/annexe-a.bin.minisig"
}

gen() { run env LCARS_MINISIGN_PUBKEY="${PUB-RWQcle}" LCARS_DOOR_IMAGE="${IMG-ghcr.io/o/r:0.9.0}" bash "$GEN" 0.9.0 https://forge.test/o/r/releases/download/0.9.0 "$DIST"; }
sums_of() { # sums_of <porte> -> la table, telle que la porte la rend
  bash -c "$(sed -n '/^sums() {/,/^}/p' "$1")"$'\nsums'
}

@test "LCARS header: SOURCE/AUTHOR/STARDATE/STATUS present" {
  run head -8 "$GEN"
  [[ "$output" == *"SOURCE:"* ]]; [[ "$output" == *"AUTHOR:"* ]]; [[ "$output" == *"STARDATE:"* ]]; [[ "$output" == *"STATUS:"* ]]
}

@test "il est EXECUTABLE dans l index git" {
  run git -C "$BATS_TEST_DIRNAME/../../.." ls-files -s deploy/lib/door-gen.sh
  [ "$status" -eq 0 ]
  [[ "$output" == 100755* ]]
}

@test "la TABLE couvre TOUS les artefacts du tiroir, avec leur sha256 juste — et rien d'autre" {
  gen; [ "$status" -eq 0 ] || { echo "$output"; return 1; }
  [ -f "$DIST/install.sh" ]
  local table; table="$(sums_of "$DIST/install.sh")"
  ( cd "$DIST" && printf '%s\n' "$table" | sha256sum -c --quiet --strict )
  [ "$(printf '%s\n' "$table" | grep -c .)" -eq 3 ]
  local a; for a in lcars-fleet-0.9.0-otp27-x86_64.tar.gz annexe-a.bin annexe-b.bin; do
    [ "$(grep -c "  $a\$" <<<"$table")" -eq 1 ] || { echo "$a manque a la table"; return 1; }
  done
  refute_out 'sha256|minisig|install\.sh' <<<"$table"
}

@test "les CONSTANTES sont remplies : --version dit le tag (pipee), BASE et la cle sont ecrites sur leurs lignes marquees" {
  gen; [ "$status" -eq 0 ]
  local porte="$DIST/install.sh"
  run bash -c "cat '$porte' | bash -s -- --version"
  [ "$output" = "0.9.0" ]
  grep -qE '^DOOR_BASE="https://forge\.test/o/r/releases/download/0\.9\.0" +# @@DOOR_BASE@@' "$porte"
  grep -qE '^MINISIGN_PUBKEY="RWQcle" +# @@DOOR_PUBKEY@@' "$porte"
  grep -qE '^LCARS_DOOR_VERSION="0\.9\.0" +# @@DOOR_VERSION@@' "$porte"
  grep -qE '^DOOR_IMAGE="ghcr\.io/o/r:0\.9\.0" +# @@DOOR_IMAGE@@' "$porte"
  IMG="" gen; [ "$status" -eq 0 ]
  grep -qE '^DOOR_IMAGE="" +# @@DOOR_IMAGE@@' "$porte"
  local m; for m in DOOR_VERSION DOOR_BASE DOOR_PUBKEY DOOR_IMAGE DOOR_SUMS_BEGIN DOOR_SUMS_END; do
    [ "$(grep -c "@@$m@@" "$porte")" -eq 1 ]
  done
  [ -x "$porte" ]
}

@test "install.sh.sha256 est JUSTE — c'est ce que quelqu'un compare a ce qui lui est servi" {
  gen; [ "$status" -eq 0 ]
  [ -f "$DIST/install.sh.sha256" ]
  ( cd "$DIST" && sha256sum -c --quiet --strict install.sh.sha256 )
  [[ "$output" == *"sha256 de l'installeur : $(cut -d' ' -f1 < "$DIST/install.sh.sha256")"* ]]
  local avant; avant="$(cat "$DIST/install.sh.sha256")"
  gen; [ "$status" -eq 0 ]
  [ "$(cat "$DIST/install.sh.sha256")" = "$avant" ]
}

@test "SANS cle publique : la porte est generee AVEC une cle vide, et le generateur le DIT — jamais en silence" {
  PUB="" gen; [ "$status" -eq 0 ]
  [[ "$output" == *"aucune clé publique"*"NON vérifiée"* ]]
  grep -qE '^MINISIGN_PUBKEY="" +# @@DOOR_PUBKEY@@' "$DIST/install.sh"
  printf 'untrusted comment: minisign public key\nRWQdepuisfichier\n' > "$DIST/minisign.pub"
  minisign_cle "$BATS_TEST_TMPDIR/cle-fichier" RWQdepuisfichier
  minisign -S -s "$BATS_TEST_TMPDIR/cle-fichier" -m "$KIT"
  PUB="" gen; [ "$status" -eq 0 ]
  grep -qE '^MINISIGN_PUBKEY="RWQdepuisfichier"' "$DIST/install.sh"
  refute_out 'aucune clé' <<<"$output"
  refute_out 'minisign\.pub' <<<"$(sums_of "$DIST/install.sh")"
}

@test "un tiroir vide est un refus, rien n'est écrit" {
  rm -f "$DIST"/*
  gen
  [ "$status" -eq 1 ]
  [[ "$output" == *"aucun artefact"* ]]
  [ ! -f "$DIST/install.sh" ]
}

@test "un tiroir absent rend « aucun artefact », et rien n'est créé" {
  rm -rf "$DIST"
  gen
  [ "$status" -eq 1 ]
  [[ "$output" == *"aucun artefact dans $DIST"* ]]
  [ ! -e "$DIST" ]
}

@test "un gabarit sans marqueur est un refus qui compte le marqueur, rien n'est écrit" {
  local mutile="$BATS_TEST_TMPDIR/gabarit-mutile.sh"
  grep -v '@@DOOR_PUBKEY@@' "$TEMPLATE" > "$mutile"
  run env LCARS_DOOR_TEMPLATE="$mutile" bash "$GEN" 0.9.0 https://f/x "$DIST"
  [ "$status" -eq 1 ]
  [[ "$output" == *"0 fois @@DOOR_PUBKEY@@"* ]]
  [ ! -f "$DIST/install.sh" ]
}

@test "une base qui n'est pas une URL http(s) est un refus, rien n'est écrit" {
  run bash "$GEN" 0.9.0 ftp://f/x "$DIST"
  [ "$status" -eq 1 ]
  [[ "$output" == *"http(s)"* ]]
  [ ! -f "$DIST/install.sh" ]
}

@test "le generateur ne SUBSTITUE pas, il rebatit : une base qui porte & ou \\ est recopiee telle quelle" {
  run env LCARS_MINISIGN_PUBKEY="" bash "$GEN" 0.9.0 'https://f/x?a=1&b=2\tc' "$DIST"
  [ "$status" -eq 0 ]
  grep -qF 'DOOR_BASE="https://f/x?a=1&b=2\tc"' "$DIST/install.sh"
}

@test "une clé publique sans la signature du kit dans le tiroir est un refus : l'installeur refuserait son propre kit" {
  rm -f "$DIST/lcars-fleet-0.9.0-otp27-x86_64.tar.gz.minisig"
  gen
  [ "$status" -eq 1 ]
  [[ "$output" == *"lcars-fleet-0.9.0-otp27-x86_64.tar.gz.minisig manque"* ]]
  [ ! -f "$DIST/install.sh" ]
}

@test "un kit signé d'une autre clé, ou modifié après sa signature, est un refus : l'installeur le refuserait ; signé de la clé fournie, l'installeur est écrit" {
  minisign_cle "$BATS_TEST_TMPDIR/cle-autre" RWQautre
  minisign -S -s "$BATS_TEST_TMPDIR/cle-autre" -m "$KIT"
  gen
  [ "$status" -eq 1 ]
  [[ "$output" == *"la signature de lcars-fleet-0.9.0-otp27-x86_64.tar.gz ne se vérifie pas avec la clé publique fournie"* ]]
  [ ! -f "$DIST/install.sh" ]
  minisign -S -s "$BATS_TEST_TMPDIR/cle-RWQcle" -m "$KIT"
  printf 'kit altéré\n' > "$KIT"
  gen
  [ "$status" -eq 1 ]
  [[ "$output" == *"ne se vérifie pas"* ]]
  [ ! -f "$DIST/install.sh" ]
  printf 'kit\n' > "$KIT"
  gen
  [ "$status" -eq 0 ] || { echo "$output"; return 1; }
  grep -qE '^MINISIGN_PUBKEY="RWQcle" +# @@DOOR_PUBKEY@@' "$DIST/install.sh"
}

@test "une clé publique sans minisign pour vérifier les kits est un refus qui le nomme, rien n'est écrit" {
  local sans="$BATS_TEST_TMPDIR/sans-minisign" d f
  mkdir -p "$sans"
  while IFS= read -r d; do
    [ -d "$d" ] || continue
    for f in "$d"/*; do
      [ -x "$f" ] || continue
      [ "$(basename "$f")" != minisign ] || continue
      [ -e "$sans/$(basename "$f")" ] || ln -s "$f" "$sans/$(basename "$f")"
    done
  done < <(tr ':' '\n' <<<"$PATH")
  [ ! -e "$sans/minisign" ]
  run env PATH="$sans" LCARS_MINISIGN_PUBKEY=RWQcle bash "$GEN" 0.9.0 https://forge.test/o/r/releases/download/0.9.0 "$DIST"
  [ "$status" -eq 1 ]
  [[ "$output" == *"une clé publique est fournie et minisign est absent"* ]]
  [ ! -f "$DIST/install.sh" ]
}
