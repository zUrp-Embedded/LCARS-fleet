#!/usr/bin/env bats
# SOURCE: test/install/install_guards.bats
# AUTHOR: consultant
# STARDATE: 2026-07-30
# STATUS: bats tests for etc/install.sh config guards — prefix depth + manifest validation
#
# Scope: ONLY the section-0 guards (they run before any environment check or build, so a
# sandboxed copy of etc/ is enough — no mix, no runtime tree). The build/pose path has its
# empirical proof elsewhere (docker image build runs the real install.sh end to end).
#
# Why the prefix guard exists (ring0-substrat finding): install.sh later runs
# `rm -rf $PREFIX/rel` and recursive chgrp/chmod on $PREFIX — with PREFIX=/ that is a
# system-wide disaster. Absolute, depth >= 2, no exception.

setup() {
  SANDBOX="$BATS_TEST_TMPDIR/rt"
  mkdir -p "$SANDBOX/etc"
  cp "$BATS_TEST_DIRNAME/../../etc/install.sh" "$SANDBOX/etc/install.sh"
  cp "$BATS_TEST_DIRNAME/../../etc/install.manifest" "$SANDBOX/etc/install.manifest"
}

@test "guard: PREFIX=/ dies before anything else" {
  run env LCARS_INSTALL_PREFIX=/ bash "$SANDBOX/etc/install.sh"
  [ "$status" -eq 1 ]
  [[ "$output" == *"profondeur >= 2"* ]]
}

@test "guard: PREFIX=/local (depth 1) dies" {
  run env LCARS_INSTALL_PREFIX=/local bash "$SANDBOX/etc/install.sh"
  [ "$status" -eq 1 ]
  [[ "$output" == *"profondeur >= 2"* ]]
}

@test "guard: relative PREFIX dies" {
  run env LCARS_INSTALL_PREFIX=foo/bar bash "$SANDBOX/etc/install.sh"
  [ "$status" -eq 1 ]
  [[ "$output" == *"profondeur >= 2"* ]]
}

@test "guard: trailing slash is normalized, /local/x/ passes the guard" {
  run env LCARS_INSTALL_PREFIX="$BATS_TEST_TMPDIR/x/" bash "$SANDBOX/etc/install.sh"
  # passes the guard, then dies on the missing runtime root (sandbox has no mix.exs) —
  # which also proves config guards run BEFORE environment checks
  [[ "$output" != *"profondeur >= 2"* ]]
  [[ "$output" == *"mix.exs absent"* ]]
}

@test "manifest: missing file dies with its path" {
  rm "$SANDBOX/etc/install.manifest"
  run env LCARS_INSTALL_PREFIX=/local/ok bash "$SANDBOX/etc/install.sh"
  [ "$status" -eq 1 ]
  [[ "$output" == *"manifest absent"* ]]
}

@test "manifest: unknown mode token dies naming the entry" {
  printf 'goodfile exec\nbadfile wat\n' > "$SANDBOX/etc/install.manifest"
  run env LCARS_INSTALL_PREFIX=/local/ok bash "$SANDBOX/etc/install.sh"
  [ "$status" -eq 1 ]
  [[ "$output" == *"mode inconnu"* ]]
  [[ "$output" == *"badfile"* ]]
}

@test "manifest: unknown flag dies naming the entry" {
  printf 'somefile exec copy\n' > "$SANDBOX/etc/install.manifest"
  run env LCARS_INSTALL_PREFIX=/local/ok bash "$SANDBOX/etc/install.sh"
  [ "$status" -eq 1 ]
  [[ "$output" == *"flag inconnu"* ]]
}

@test "manifest: extra token dies (strict format, no silent skip)" {
  printf 'somefile exec link whatever\n' > "$SANDBOX/etc/install.manifest"
  run env LCARS_INSTALL_PREFIX=/local/ok bash "$SANDBOX/etc/install.sh"
  [ "$status" -eq 1 ]
  [[ "$output" == *"token en trop"* ]]
}

@test "manifest: comments-only file is an empty manifest, dies" {
  printf '# just comments\n\n' > "$SANDBOX/etc/install.manifest"
  run env LCARS_INSTALL_PREFIX=/local/ok bash "$SANDBOX/etc/install.sh"
  [ "$status" -eq 1 ]
  [[ "$output" == *"manifest vide"* ]]
}

@test "manifest: the REAL shipped manifest parses clean" {
  run env LCARS_INSTALL_PREFIX="$BATS_TEST_TMPDIR/x/y" bash "$SANDBOX/etc/install.sh"
  [[ "$output" != *"manifest"* ]]
  [[ "$output" == *"mix.exs absent"* ]]
}
