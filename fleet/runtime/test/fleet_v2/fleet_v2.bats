#!/usr/bin/env bats
# SOURCE: test/fleet_v2/fleet_v2.bats
# AUTHOR: consultant (remediation agent, off-fleet session)
# STARDATE: 2026.202
# STATUS: bats tests for bin/fleet_v2 env semantics (maintenance override)
#
# The launcher used to clobber LCARS_BOOT_PERMANENT_AT_START with an unconditional
# export: an operator booting in maintenance (=false) got the permanent pods anyway
# (real spend, forge effects). setup_env must PRESERVE the operator's intent; the
# asymmetry with LCARS_PILOT_STEP (already override-preserving) was the tell.

setup() {
  SCRIPT="$BATS_TEST_DIRNAME/../../bin/fleet_v2"
  TMP_BASE="$(mktemp -d)"
  export HOME="$TMP_BASE"
  mkdir -p "$HOME/.lcars"
  # setup_env fail-louds on a missing forge URL (legitimate guard) — satisfied here.
  export FORGE_BASE_URL="http://forge.test"
}

teardown() { rm -rf "$TMP_BASE"; }

@test "maintenance override SURVIVES setup_env (LCARS_BOOT_PERMANENT_AT_START=false)" {
  run bash -c "export LCARS_BOOT_PERMANENT_AT_START=false; source '$SCRIPT'; setup_env; echo \"flag=\$LCARS_BOOT_PERMANENT_AT_START\""
  [ "$status" -eq 0 ]
  [[ "$output" == *"flag=false"* ]]
}

@test "nominal default stays ON (flag unset -> true)" {
  run bash -c "unset LCARS_BOOT_PERMANENT_AT_START; source '$SCRIPT'; setup_env; echo \"flag=\$LCARS_BOOT_PERMANENT_AT_START\""
  [ "$status" -eq 0 ]
  [[ "$output" == *"flag=true"* ]]
}

@test "the env file's own false is honoured too (operator intent from fleet_v2.env)" {
  echo 'LCARS_BOOT_PERMANENT_AT_START=false' > "$HOME/.lcars/fleet_v2.env"
  run bash -c "source '$SCRIPT'; setup_env; echo \"flag=\$LCARS_BOOT_PERMANENT_AT_START\""
  [ "$status" -eq 0 ]
  [[ "$output" == *"flag=false"* ]]
}

@test "sourcing the launcher never runs the dispatcher (source guard)" {
  run bash -c "source '$SCRIPT'; echo sourced-ok"
  [ "$status" -eq 0 ]
  [[ "$output" == *"sourced-ok"* ]]
}
