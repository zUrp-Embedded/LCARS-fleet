#!/usr/bin/env bats
# SOURCE: fleet/deploy/tests/provision_runner.bats
# AUTHOR: consultant
# STARDATE: 2026-07-30
# STATUS: bats tests for the runner's D6 substrate model (APPLY-ON / CHECK-ON)
#
# D6 (ADR install/compile/release §7) splits two axes the old single `# SUBSTRATE:` header
# conflated: WHERE mutations run (APPLY-ON) vs WHERE the target state must hold (CHECK-ON).
# Consequence under test: on docker, a module built by the image (APPLY-ON: wsl linux,
# CHECK-ON: any) is CHECKED by doctor AND by apply — and its drift is an apply FAILURE
# (nothing on this substrate can converge it), never a silent skip.
#
# Harness: the runner resolves its module dir from its own path, so each test builds a
# sandbox tree (provision + lib + stub modules) in BATS_TEST_TMPDIR and runs the real
# runner as a real process. Stubs log "<name>:<mode>" to RUN_LOG and exit STUB_RC.

setup() {
  SRC="$BATS_TEST_DIRNAME/.."
  SANDBOX="$BATS_TEST_TMPDIR/prov"
  mkdir -p "$SANDBOX/lib" "$SANDBOX/modules.d"
  cp "$SRC/provision" "$SANDBOX/provision"
  cp "$SRC/lib/provision-lib.sh" "$SANDBOX/lib/provision-lib.sh"
  export RUN_LOG="$BATS_TEST_TMPDIR/run.log"
  : > "$RUN_LOG"
}

# stub <NN-name> <apply-on> <check-on> <needs> [rc-var-name]
stub_module() {
  local name="$1" apply_on="$2" check_on="$3" needs="$4" rcvar="${5:-STUB_RC_UNSET}"
  cat > "$SANDBOX/modules.d/$name.sh" <<EOF
#!/usr/bin/env bash
# APPLY-ON: $apply_on
# CHECK-ON: $check_on
# NEEDS: $needs
set -euo pipefail
echo "$name:\$1" >> "\$RUN_LOG"
exit "\${$rcvar:-0}"
EOF
}

@test "D6: doctor on docker CHECKS an image-built module (APPLY-ON wsl linux, CHECK-ON any)" {
  stub_module 10-pkgstub "wsl linux" any human
  run "$SANDBOX/provision" doctor --substrate docker
  [ "$status" -eq 0 ]
  grep -q "10-pkgstub:check" "$RUN_LOG"
}

@test "D6: apply on docker runs CHECK (not apply) for an image-built module" {
  stub_module 60-deploystub "wsl linux" any human
  run "$SANDBOX/provision" apply --substrate docker
  [ "$status" -eq 0 ]
  grep -q "60-deploystub:check" "$RUN_LOG"
  ! grep -q "60-deploystub:apply" "$RUN_LOG"
  [[ "$output" == *"APPLY-ON=wsl linux"* ]]
}

@test "D6: image-built module DRIFT during apply is a FAILURE, not a silent skip" {
  stub_module 60-deploystub "wsl linux" any human STUB_RC_DRIFT
  export STUB_RC_DRIFT=1
  run "$SANDBOX/provision" apply --substrate docker
  [ "$status" -eq 1 ]
  [[ "$output" == *"inapplicable"* ]]
  [[ "$output" == *"rebuild"* ]]
}

@test "D6: apply on a matching substrate runs the real apply" {
  stub_module 60-deploystub "wsl linux" any human
  run "$SANDBOX/provision" apply --substrate wsl
  [ "$status" -eq 0 ]
  grep -q "60-deploystub:apply" "$RUN_LOG"
}

@test "D6: module outside CHECK-ON is not selected at all" {
  stub_module 15-toolstub "wsl linux" "wsl linux" human
  stub_module 20-anystub any any human
  run "$SANDBOX/provision" doctor --substrate docker
  [ "$status" -eq 0 ]
  ! grep -q "15-toolstub" "$RUN_LOG"
  grep -q "20-anystub:check" "$RUN_LOG"
}

@test "D6: missing CHECK-ON header is a build error (fail-loud)" {
  cat > "$SANDBOX/modules.d/10-broken.sh" <<'EOF'
#!/usr/bin/env bash
# APPLY-ON: any
# NEEDS: human
exit 0
EOF
  run "$SANDBOX/provision" doctor --substrate docker
  [ "$status" -eq 1 ]
  [[ "$output" == *"CHECK-ON"* ]]
}

@test "D6: APPLY-ON substrate outside CHECK-ON is incoherent (fail-loud)" {
  stub_module 10-incoherent "docker" "wsl" human
  run "$SANDBOX/provision" doctor --substrate wsl
  [ "$status" -eq 1 ]
  [[ "$output" == *"hors de CHECK-ON"* ]]
}

@test "D6: non-root apply is allowed when every NEEDS:root module is check-only here" {
  [ "$(id -u)" -ne 0 ] || skip "must run unprivileged"
  stub_module 60-rootstub "wsl linux" any root
  run "$SANDBOX/provision" apply --substrate docker
  [ "$status" -eq 0 ]
  grep -q "60-rootstub:check" "$RUN_LOG"
}

@test "D6: non-root apply still dies when a NEEDS:root module would really apply" {
  [ "$(id -u)" -ne 0 ] || skip "must run unprivileged"
  stub_module 60-rootstub "wsl linux" any root
  run "$SANDBOX/provision" apply --substrate wsl
  [ "$status" -eq 1 ]
  [[ "$output" == *"exige root"* ]]
}

@test "doctor --porcelain stays machine-readable across the D6 model" {
  stub_module 10-okstub any any human
  stub_module 60-driftstub "wsl linux" any human STUB_RC_DRIFT
  export STUB_RC_DRIFT=1
  run "$SANDBOX/provision" doctor --substrate docker --porcelain
  [ "$status" -eq 1 ]
  [[ "$output" == *"10-okstub=OK"* ]]
  [[ "$output" == *"60-driftstub=DRIFT"* ]]
}

@test "list shows both axes" {
  stub_module 10-pkgstub "wsl linux" any root
  run "$SANDBOX/provision" list --substrate docker
  [ "$status" -eq 0 ]
  [[ "$output" == *"APPLY-ON=wsl linux"* ]]
  [[ "$output" == *"CHECK-ON=any"* ]]
}
