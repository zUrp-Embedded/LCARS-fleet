#!/usr/bin/env bats
# SOURCE: test/install/install.bats
# AUTHOR: consultant (remediation agent, off-fleet session)
# STARDATE: 2026.202
# STATUS: bats tests for etc/install.sh atomic-swap helpers (crash-safe deploy)
#
# The old install did `rm -rf $PREFIX/rel` then a slow `cp -a`, and overwrote each launcher in place:
# a failure mid-copy lost the last good build, a reader mid-copy saw a mixed assembly. These drive the
# extracted atomic_swap_dir / atomic_swap_file directly (source guard = no mix build) and prove the
# live target is never destroyed before the new one is verified, and the previous is kept.

setup() {
  SCRIPT="$BATS_TEST_DIRNAME/../../etc/install.sh"
  source "$SCRIPT"
  TMP="$(mktemp -d)"
}

teardown() { rm -rf "$TMP"; }

@test "atomic_swap_dir: replaces the live tree and keeps the previous as .prev" {
  mkdir -p "$TMP/src/bin"; printf '#!/bin/sh\nnew\n' > "$TMP/src/bin/fleet_umbrella"; chmod +x "$TMP/src/bin/fleet_umbrella"
  mkdir -p "$TMP/dst/bin"; printf '#!/bin/sh\nold\n' > "$TMP/dst/bin/fleet_umbrella"; chmod +x "$TMP/dst/bin/fleet_umbrella"

  run atomic_swap_dir "$TMP/src" "$TMP/dst" "bin/fleet_umbrella"
  [ "$status" -eq 0 ]
  grep -q new "$TMP/dst/bin/fleet_umbrella"
  grep -q old "$TMP/dst.prev/bin/fleet_umbrella"
}

@test "atomic_swap_dir: a build missing its probe FAILS and leaves the live tree untouched" {
  mkdir -p "$TMP/src/bin"    # no fleet_umbrella probe inside
  mkdir -p "$TMP/dst/bin"; printf '#!/bin/sh\nold\n' > "$TMP/dst/bin/fleet_umbrella"; chmod +x "$TMP/dst/bin/fleet_umbrella"

  run atomic_swap_dir "$TMP/src" "$TMP/dst" "bin/fleet_umbrella"
  [ "$status" -ne 0 ]
  [[ "$output" == *"build stage invalide"* ]]
  # The live install survived a bad build — the exact loss the old rm -rf caused.
  grep -q old "$TMP/dst/bin/fleet_umbrella"
  [ ! -e "$TMP/dst.staging.$$" ]
}

@test "atomic_swap_file: renames the new file over the old (atomic, never truncated)" {
  printf 'NEW\n' > "$TMP/src"
  printf 'OLD\n' > "$TMP/dst"

  run atomic_swap_file "$TMP/src" "$TMP/dst"
  [ "$status" -eq 0 ]
  grep -q NEW "$TMP/dst"
  [ ! -e "$TMP/dst.new.$$" ]
}

@test "sourcing install.sh never runs the deploy (source guard)" {
  run bash -c "source '$SCRIPT'; echo sourced-ok"
  [ "$status" -eq 0 ]
  [[ "$output" == *"sourced-ok"* ]]
}
