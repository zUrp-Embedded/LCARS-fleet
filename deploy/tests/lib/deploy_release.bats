#!/usr/bin/env bats
# bats file_tags=unit
# SOURCE: deploy/tests/lib/deploy_release.bats
# AUTHOR: consultant (remediation agent, off-fleet session)
# STARDATE: 2026.257
# STATUS: bats tests for deploy/lib/deploy-release.sh sourcé — la bascule atomique, le build, la lib chargée
#

load ../refute

setup() {
  SCRIPT="$BATS_TEST_DIRNAME/../../lib/deploy-release.sh"
  # shellcheck source=../../lib/deploy-release.sh
  source "$SCRIPT"
  TMP="$(mktemp -d)"
}

teardown() { rm -rf "$TMP"; }

@test "atomic_swap_dir: replaces the live tree and keeps the previous as .prev" {
  mkdir -p "$TMP/src/bin"; printf '#!/bin/sh\nnew\n' > "$TMP/src/bin/lcars_fleet"; chmod +x "$TMP/src/bin/lcars_fleet"
  mkdir -p "$TMP/dst/bin"; printf '#!/bin/sh\nold\n' > "$TMP/dst/bin/lcars_fleet"; chmod +x "$TMP/dst/bin/lcars_fleet"

  run atomic_swap_dir "$TMP/src" "$TMP/dst"
  [ "$status" -eq 0 ]
  grep -q new "$TMP/dst/bin/lcars_fleet"
  grep -q old "$TMP/dst.prev/bin/lcars_fleet"
}

@test "atomic_swap_file: renames the new file over the old (atomic, never truncated)" {
  printf 'NEW\n' > "$TMP/src"
  printf 'OLD\n' > "$TMP/dst"

  run atomic_swap_file "$TMP/src" "$TMP/dst"
  [ "$status" -eq 0 ]
  grep -q NEW "$TMP/dst"
  [ ! -e "$TMP/dst.new.$$" ]
}

@test "le build ne joue pas mix gate : dépendances puis release, rien d'autre" {
  mkdir -p "$TMP/binstub"
  printf '#!/usr/bin/env bash\necho "$@" >> "$MIX_CALL_LOG"\n' > "$TMP/binstub/mix"
  chmod +x "$TMP/binstub/mix"
  export MIX_CALL_LOG="$TMP/mix-calls.log"
  PATH="$TMP/binstub:$PATH" run build_release "$TMP"
  [ "$status" -eq 0 ]
  [ "$(cat "$MIX_CALL_LOG")" = "$(printf 'deps.get\nrelease --overwrite')" ]
  refute grep -q gate "$MIX_CALL_LOG"
}

@test "sourcing deploy-release.sh never runs the deploy (source guard)" {
  run bash -c "source '$SCRIPT'; echo sourced-ok"
  [ "$status" -eq 0 ]
  [[ "$output" == *"sourced-ok"* ]]
}

@test "sourcé, il charge la lib : le préfixe est celui des constantes, sous le décor" {
  local constante; constante="$(grep '^PROV_PREFIX=' "$BATS_TEST_DIRNAME/../../installer-constants.env" | cut -d= -f2)"
  run env LCARS_DECOR_ROOT="$TMP/decor" bash -c "source '$SCRIPT'; printf %s \"\$PROV_PREFIX\""
  [ "$status" -eq 0 ]
  [ "$output" = "$TMP/decor$constante" ]
}
