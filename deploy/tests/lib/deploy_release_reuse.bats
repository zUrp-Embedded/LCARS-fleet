#!/usr/bin/env bats
# bats file_tags=unit
# SOURCE: deploy/tests/lib/deploy_release_reuse.bats
# AUTHOR: alice
# STARDATE: 2026-08-28
# STATUS: bats tests for deploy/lib/deploy-release.sh — une release n'est reutilisee que si elle ATTESTE la source
#

setup() {
  SUT="$BATS_TEST_DIRNAME/../../lib/deploy-release.sh"
  [ -f "$SUT" ]
  RT="$BATS_TEST_TMPDIR/repo/runtime"        # `runtime_dir` = le runtime/ d un arbre
  REL="$RT/_build/prod/rel/lcars_fleet"
  mkdir -p "$REL/bin" "$REL/lib/lcars_fleet-1.0.0/priv/api"
  printf '#!/bin/sh\nexit 0\n' > "$REL/bin/lcars_fleet"; chmod +x "$REL/bin/lcars_fleet"
}

atteste() { printf 'sha=%s\n' "$1" > "$REL/lib/lcars_fleet-1.0.0/priv/api/build_info.txt"; }

depot() {
  git -C "$RT" init -q 2>/dev/null
  git -C "$RT" config user.email t@t; git -C "$RT" config user.name t
  echo x > "$RT/mix.exs"; git -C "$RT" add -A >/dev/null
  git -C "$RT" -c commit.gpgsign=false commit -qm x >/dev/null
  git -C "$RT" rev-parse --short HEAD
}

appel() { run bash -c ". '$SUT' >/dev/null 2>&1; build_release '$RT' 2>&1"; }

@test "GARDE D'INSTRUMENT : build_release est ATTEIGNABLE par sourcing" {
  run bash -c ". '$SUT' >/dev/null 2>&1; declare -F build_release"
  [ "$status" -eq 0 ]
}

@test "PAQUET : le tampon de révision DIT paquet — réutilisation sans compilation" {
  printf 'abcd1234\n' > "$RT/../$(grep '^PROV_SOURCE_STAMP=' "$BATS_TEST_DIRNAME/../../installer-constants.env" | cut -d= -f2)"
  appel
  [ "$status" -eq 0 ]
  [[ "$output" == *"kit — release bâtie par pack.sh"* ]]
}

@test "CLONE PROPRE, sha qui CORRESPOND : reutilisation, et elle est dite ATTESTEE" {
  local sha; sha="$(depot)"; atteste "$sha"
  appel
  [ "$status" -eq 0 ]
  [[ "$output" == *"attestée"* ]]
}

@test "LE DEFAUT : un vieux _build dans un clone ne se reutilise PAS" {
  depot > /dev/null; atteste "deadbeef"
  appel
  [[ "$output" == *"n'atteste pas cette source"* ]]
  [[ "$output" != *"rien à compiler"* ]]
}

@test "CLONE SALE : le sha correspond mais l'arbre est modifie — pas de reutilisation" {
  local sha; sha="$(depot)"; atteste "$sha"
  echo "modifie" >> "$RT/mix.exs"
  appel
  [[ "$output" == *"n'atteste pas cette source"* ]]
}

@test "NI MARQUEUR NI GIT : provenance inconnue — on rebatit" {
  atteste "abcd1234"
  appel
  [[ "$output" == *"n'atteste pas cette source"* ]]
}

@test "DEUX LIBS dans la release : le sha lu est celui de la version qui DEMARRE (start_erl.data), jamais la premiere du glob" {
  local sha; sha="$(depot)"
  mkdir -p "$REL/lib/lcars_fleet-0.1.0/priv/api" "$REL/releases"
  printf 'sha=deadbeef1\n' > "$REL/lib/lcars_fleet-0.1.0/priv/api/build_info.txt"
  atteste "$sha"
  printf '15.2 1.0.0\n' > "$REL/releases/start_erl.data"
  run bash -c ". '$BATS_TEST_DIRNAME/../../lib/provision-lib.sh'; release_app_dir '$REL'"
  [ "$status" -eq 0 ]
  [[ "$output" == "$REL/lib/lcars_fleet-1.0.0" ]]
  rm -f "$REL/releases/start_erl.data"
  run bash -c ". '$BATS_TEST_DIRNAME/../../lib/provision-lib.sh'; release_app_dir '$REL'"
  [ "$status" -ne 0 ]
  [ -z "$output" ]
}
