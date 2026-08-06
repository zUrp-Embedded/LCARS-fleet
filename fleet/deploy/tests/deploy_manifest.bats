#!/usr/bin/env bats
# SOURCE: fleet/deploy/tests/deploy_manifest.bats
# AUTHOR: consultant
# STARDATE: 2026-07-30
# STATUS: bats tests for 60-deploy check — manifest-driven, source-independent
#
# Contract under test: the doctor side of 60-deploy is as BLIND to content as the installer —
# what it probes under $PREFIX/bin comes from etc/install.manifest, and it needs NO source
# checkout beyond etc/ (first real container boot proved the old mix.exs guard broke the probe
# exactly where it matters most). The RO-lock probe (root:fleet) inevitably drifts in an
# unprivileged sandbox — assertions therefore target the bin/link lines, not the exit code,
# except where the exit code is the contract (missing manifest = probe ERROR = rc 2).

setup() {
  SRC="$BATS_TEST_DIRNAME/.."
  ROOT="$BATS_TEST_TMPDIR/repo"
  mkdir -p "$ROOT/fleet/deploy/lib" "$ROOT/fleet/runtime/etc"
  cp "$SRC/lib/provision-lib.sh" "$ROOT/fleet/deploy/lib/"
  cp "$SRC/modules.d/60-deploy.sh" "$BATS_TEST_TMPDIR/60-deploy.sh"

  cat > "$ROOT/fleet/runtime/etc/install.manifest" <<'EOF'
# test manifest
fleet_v2         exec   link
bwrap_launch.sh  exec
bridge.py        noexec
EOF

  export PROV_PREFIX="$BATS_TEST_TMPDIR/prefix"
  export PROV_LINK_DIR="$BATS_TEST_TMPDIR/linkdir"
  export PROVISION_LIB="$ROOT/fleet/deploy/lib/provision-lib.sh"
  export PROVISION_MODULE=60-deploy

  # a "deployed" prefix: release marker + every manifest entry posed correctly
  mkdir -p "$PROV_PREFIX/rel/fleet_umbrella/bin" "$PROV_PREFIX/bin" "$PROV_LINK_DIR"
  printf '#!/bin/sh\n' > "$PROV_PREFIX/rel/fleet_umbrella/bin/fleet_umbrella"
  chmod +x "$PROV_PREFIX/rel/fleet_umbrella/bin/fleet_umbrella"
  printf 'x\n' > "$PROV_PREFIX/bin/fleet_v2";        chmod +x "$PROV_PREFIX/bin/fleet_v2"
  printf 'x\n' > "$PROV_PREFIX/bin/bwrap_launch.sh"; chmod +x "$PROV_PREFIX/bin/bwrap_launch.sh"
  printf 'x\n' > "$PROV_PREFIX/bin/bridge.py"
  ln -s "$PROV_PREFIX/bin/fleet_v2" "$PROV_LINK_DIR/fleet_v2"
}

run_check() { run bash "$BATS_TEST_TMPDIR/60-deploy.sh" check; }

@test "manifest-driven check: fully posed prefix has zero bin/link drift" {
  run_check
  [[ "$output" == *"bin/fleet_v2"* ]]
  [[ "$output" == *"bin/bridge.py"* ]]
  [[ "$output" == *"symlink $PROV_LINK_DIR/fleet_v2"* ]]
  [[ "$output" != *"DRIFT 60-deploy: bin/"* ]]
  [[ "$output" != *"symlink vers"* ]]
}

@test "manifest-driven check: a missing exec entry drifts by name" {
  rm "$PROV_PREFIX/bin/bwrap_launch.sh"
  run_check
  [[ "$output" == *"DRIFT"* ]]
  [[ "$output" == *"bin/bwrap_launch.sh absent"* ]]
}

@test "manifest-driven check: a noexec entry only needs to be readable" {
  chmod -x "$PROV_PREFIX/bin/bridge.py"
  run_check
  [[ "$output" != *"bridge.py absent"* ]]
}

@test "manifest-driven check: a wrong link target drifts" {
  ln -sfn /somewhere/else "$PROV_LINK_DIR/fleet_v2"
  run_check
  [[ "$output" == *"$PROV_LINK_DIR/fleet_v2 ≠ symlink vers"* ]]
}

@test "manifest-driven check: a dead copy of a non-link entry warns (D3)" {
  printf 'x\n' > "$PROV_LINK_DIR/bwrap_launch.sh"
  run_check
  [[ "$output" == *"copie morte $PROV_LINK_DIR/bwrap_launch.sh"* ]]
}

@test "source-independence: check runs WITHOUT mix.exs (only etc/ ships in the image)" {
  # setup() never created mix.exs — a green-path check proves no source-tree dependency
  run_check
  [[ "$output" != *"introuvable"* ]]
}

@test "missing manifest is a probe ERROR (rc 2), not a silent pass" {
  rm "$BATS_TEST_TMPDIR/repo/fleet/runtime/etc/install.manifest"
  run_check
  [ "$status" -eq 2 ]
  [[ "$output" == *"manifest introuvable"* ]]
}
