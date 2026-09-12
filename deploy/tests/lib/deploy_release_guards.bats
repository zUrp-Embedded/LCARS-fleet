#!/usr/bin/env bats
# bats file_tags=unit
# SOURCE: deploy/tests/lib/deploy_release_guards.bats
# AUTHOR: consultant
# STARDATE: 2026-07-30
# STATUS: bats tests for deploy/lib/deploy-release.sh config guards — prefix depth + manifest validation
#

setup() {
  SANDBOX="$BATS_TEST_TMPDIR/rt"
  mkdir -p "$SANDBOX/etc"
  cp "$BATS_TEST_DIRNAME/../../lib/deploy-release.sh" "$SANDBOX/etc/deploy-release.sh"
  cp "$BATS_TEST_DIRNAME/../../../runtime/etc/release.manifest" "$SANDBOX/etc/release.manifest"
  export LCARS_RUNTIME_DIR="$SANDBOX"
}

@test "guard: PREFIX=/ dies before anything else" {
  run env LCARS_INSTALL_PREFIX=/ bash "$SANDBOX/etc/deploy-release.sh"
  [ "$status" -eq 1 ]
  [[ "$output" == *"profondeur >= 2"* ]]
}

@test "guard: PREFIX=/local (depth 1) dies" {
  run env LCARS_INSTALL_PREFIX=/local bash "$SANDBOX/etc/deploy-release.sh"
  [ "$status" -eq 1 ]
  [[ "$output" == *"profondeur >= 2"* ]]
}

@test "guard: relative PREFIX dies" {
  run env LCARS_INSTALL_PREFIX=foo/bar bash "$SANDBOX/etc/deploy-release.sh"
  [ "$status" -eq 1 ]
  [[ "$output" == *"profondeur >= 2"* ]]
}

@test "guard: trailing slash is normalized, /local/x/ passes the guard" {
  run env LCARS_INSTALL_PREFIX="$BATS_TEST_TMPDIR/x/" bash "$SANDBOX/etc/deploy-release.sh"
  [[ "$output" != *"profondeur >= 2"* ]]
  [[ "$output" == *"mix.exs absent"* ]]
}

@test "manifest: missing file dies with its path" {
  rm "$SANDBOX/etc/release.manifest"
  run env LCARS_INSTALL_PREFIX=/local/ok bash "$SANDBOX/etc/deploy-release.sh"
  [ "$status" -eq 1 ]
  [[ "$output" == *"manifest absent"* ]]
}

@test "manifest: unknown mode token dies naming the entry" {
  printf 'goodfile exec\nbadfile wat\n' > "$SANDBOX/etc/release.manifest"
  run env LCARS_INSTALL_PREFIX=/local/ok bash "$SANDBOX/etc/deploy-release.sh"
  [ "$status" -eq 1 ]
  [[ "$output" == *"mode inconnu"* ]]
  [[ "$output" == *"badfile"* ]]
}

@test "manifest: unknown flag dies naming the entry" {
  printf 'somefile exec copy\n' > "$SANDBOX/etc/release.manifest"
  run env LCARS_INSTALL_PREFIX=/local/ok bash "$SANDBOX/etc/deploy-release.sh"
  [ "$status" -eq 1 ]
  [[ "$output" == *"flag inconnu"* ]]
}

@test "manifest: extra token dies (strict format, no silent skip)" {
  printf 'somefile exec link whatever\n' > "$SANDBOX/etc/release.manifest"
  run env LCARS_INSTALL_PREFIX=/local/ok bash "$SANDBOX/etc/deploy-release.sh"
  [ "$status" -eq 1 ]
  [[ "$output" == *"token en trop"* ]]
}

@test "manifest: comments-only file is an empty manifest, dies" {
  printf '# just comments\n\n' > "$SANDBOX/etc/release.manifest"
  run env LCARS_INSTALL_PREFIX=/local/ok bash "$SANDBOX/etc/deploy-release.sh"
  [ "$status" -eq 1 ]
  [[ "$output" == *"manifest vide"* ]]
}

@test "manifest: the REAL shipped manifest parses clean" {
  run env LCARS_INSTALL_PREFIX="$BATS_TEST_TMPDIR/x/y" bash "$SANDBOX/etc/deploy-release.sh"
  [[ "$output" != *"manifest"* ]]
  [[ "$output" == *"mix.exs absent"* ]]
}
