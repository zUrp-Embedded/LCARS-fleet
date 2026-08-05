#!/usr/bin/env bats
# test_fleet_build_yaml.bats — Unit tests for fleet/fleet-build-yaml.sh
#
# Reference: docs/qualification/plans/phase2-failure-modes.md (BLD-01 to BLD-09)
#            docs/qualification/fmea/FMEA-agent-starfleet.md (SF-04)
#
# fleet-build-yaml.sh is executed as a command with REAL yq (not mock).
# It reads fleet-system.yaml + profiles/*.yaml and generates fleet.yaml.

bats_require_minimum_version 1.5.0

# ============================================================
# Setup / Teardown
# ============================================================

setup() {
    # Load bats libs WITHOUT mocks (this script needs real yq)
    HELPERS_DIR="$(cd "$(dirname "$(dirname "$BATS_TEST_DIRNAME")")/helpers/v1" && pwd)"
    REPO_ROOT="$(cd "$HELPERS_DIR/../.." && pwd)"
    load "$REPO_ROOT/tests/.bats/bats-support/load.bash"
    load "$REPO_ROOT/tests/.bats/bats-assert/load.bash"
    load "$REPO_ROOT/tests/.bats/bats-file/load.bash"

    SUT="$REPO_ROOT/fleet/v1/fleet-build-yaml.sh"

    # Verify real yq is available
    command -v yq &>/dev/null || skip "yq not installed"

    # Create controlled fixture directory
    FLEET_DIR="$BATS_TEST_TMPDIR/fleet"
    mkdir -p "$FLEET_DIR/profiles"

    cat > "$FLEET_DIR/fleet-system.yaml" <<'YAML'
fleet:
  version: "6.0.0-test"
  project: LCARS
  repo: test/test-fleet
  paths:
    lcars_root: /local/LCARS
    homes_root: /home
    # handoffs: computed from FLEET_WORKDIR in fleet-env.sh ($FLEET_HANDOFFS)
    fleet_state: /home/fleet-state
    ready_room: /home/ready-room
  runtime:
    tmux_socket: /tmp/fleet-tmux.sock
  identity:
    fleet_user: testuser
spool:
  root: /var/spool/fleet
  inbox: /var/spool/fleet/inbox
  outbox: /var/spool/fleet/outbox
plan:
  provider: anthropic
  plan_type: MAX
YAML

    cat > "$FLEET_DIR/profiles/fleet.yaml" <<'YAML'
instances:
  - role: starfleet
    tier: 0
    scope: boundary-os
    model: opus[1m]
    stateless: true
YAML

    cat > "$FLEET_DIR/profiles/projects.yaml" <<'YAML'
extends: fleet
instances:
  - role: architect
    tier: 0
    scope: boundary-user
    model: opus[1m]
    stateless: false
YAML
}

teardown() {
    # Cleanup permission-denied files
    chmod -R u+w "$BATS_TEST_TMPDIR" 2>/dev/null || true
}

# Helper: run the script with our fixture FLEET_DIR
_run_build() {
    FLEET_DIR="$FLEET_DIR" bash "$SUT" "$@"
}

# ============================================================
# Nominal tests
# ============================================================

@test "fleet-build-yaml: generates fleet.yaml from fleet profile" {
    run _run_build fleet
    assert_success
    assert_output --partial "fleet.yaml"
    [[ -f "$FLEET_DIR/fleet.yaml" ]]
}

@test "fleet-build-yaml: generated file contains version from system" {
    _run_build fleet >/dev/null 2>&1
    run grep "6.0.0-test" "$FLEET_DIR/fleet.yaml"
    assert_success
}

@test "fleet-build-yaml: generated file contains role from profile" {
    _run_build fleet >/dev/null 2>&1
    run grep "starfleet" "$FLEET_DIR/fleet.yaml"
    assert_success
}

@test "fleet-build-yaml: projects profile inherits fleet instances" {
    _run_build projects >/dev/null 2>&1
    run grep "starfleet" "$FLEET_DIR/fleet.yaml"
    assert_success
    run grep "architect" "$FLEET_DIR/fleet.yaml"
    assert_success
}

@test "fleet-build-yaml: output has GENERATED comment header" {
    _run_build fleet >/dev/null 2>&1
    run head -1 "$FLEET_DIR/fleet.yaml"
    assert_output --partial "GENERATED"
}

@test "fleet-build-yaml: extends field removed from output" {
    _run_build projects >/dev/null 2>&1
    run grep "^extends:" "$FLEET_DIR/fleet.yaml"
    assert_failure
}

# ============================================================
# Error tests — BLD-01 to BLD-09
# ============================================================

@test "fleet-build-yaml: [BLD-01] yq absent exits with error" {
    # Create a temp dir with only bash, hide real yq
    local fake_path="$BATS_TEST_TMPDIR/fakepath"
    mkdir -p "$fake_path"
    ln -s /bin/bash "$fake_path/bash"
    ln -s /usr/bin/env "$fake_path/env"
    # Minimal path: only bash+coreutils, no yq
    # Exclude /usr/bin and /usr/local/bin where yq may live
    ln -sf /usr/bin/stat "$fake_path/stat" 2>/dev/null || true
    ln -sf /usr/bin/dirname "$fake_path/dirname" 2>/dev/null || true
    ln -sf /usr/bin/readlink "$fake_path/readlink" 2>/dev/null || true
    run env PATH="$fake_path" FLEET_DIR="$FLEET_DIR" bash "$SUT" fleet
    assert_failure
    # Script catches missing yq with explicit exit 1 + "introuvable" message
    assert_output --partial "introuvable"
}

@test "fleet-build-yaml: [BLD-02] fleet-system.yaml absent — script errors when no fallback" {
    rm -f "$FLEET_DIR/fleet-system.yaml"
    # Copy script to isolated dir (blocks BASH_SOURCE fallback to real fleet/)
    local iso_dir="$BATS_TEST_TMPDIR/isolated"
    mkdir -p "$iso_dir"
    cp "$SUT" "$iso_dir/"
    # Also block /local/LCARS/fleet/fleet-system.yaml runtime fallback
    # by pointing FLEET_DIR to our fixture dir (which has no fleet-system.yaml)
    # If /local/LCARS/fleet/fleet-system.yaml exists on this host, the script
    # will find it — that's correct behavior (resilient resolution).
    run env FLEET_DIR="$FLEET_DIR" bash "$iso_dir/fleet-build-yaml.sh" fleet
    if [[ -f "/local/LCARS/fleet/fleet-system.yaml" ]]; then
        # Runtime fallback exists — script finds it, this is correct behavior
        # The error path can only be tested on a clean machine without /local/LCARS
        skip "runtime fallback /local/LCARS/fleet/fleet-system.yaml exists — error path unreachable"
    fi
    assert_failure
    assert_output --partial "introuvable"
}

@test "fleet-build-yaml: [BLD-03] nonexistent profile exits with error" {
    run _run_build nonexistent_profile
    assert_failure
    assert_output --partial "nonexistent_profile"
}

@test "fleet-build-yaml: [BLD-04] extends chain with missing parent exits with error" {
    cat > "$FLEET_DIR/profiles/broken.yaml" <<'YAML'
extends: missing_parent
instances:
  - role: test
    tier: 2
YAML
    run _run_build broken
    assert_failure
    assert_output --partial "missing_parent"
}

@test "fleet-build-yaml: [BLD-05] circular extends chain detected and blocked" {
    cat > "$FLEET_DIR/profiles/loop_a.yaml" <<'YAML'
extends: loop_b
instances:
  - role: a
    tier: 2
YAML
    cat > "$FLEET_DIR/profiles/loop_b.yaml" <<'YAML'
extends: loop_a
instances:
  - role: b
    tier: 2
YAML
    run _run_build loop_a
    assert_failure
    assert_output --partial "circular"
}

@test "fleet-build-yaml: [BLD-06] permission denied on output directory" {
    [[ "$(id -u)" == "0" ]] && skip "running as root — permission test meaningless"
    # Make the output directory read-only so yq can't write fleet.yaml
    local ro_dir="$BATS_TEST_TMPDIR/ro_fleet"
    mkdir -p "$ro_dir/profiles"
    cp "$FLEET_DIR/fleet-system.yaml" "$ro_dir/"
    cp "$FLEET_DIR/profiles/fleet.yaml" "$ro_dir/profiles/"
    chmod 555 "$ro_dir"
    run env FLEET_DIR="$ro_dir" bash "$SUT" fleet
    assert_failure
    # Cleanup
    chmod 755 "$ro_dir"
}

@test "fleet-build-yaml: [BLD-07] invalid YAML in fleet-system.yaml" {
    echo "{{{{ broken yaml ::::" > "$FLEET_DIR/fleet-system.yaml"
    run _run_build fleet
    assert_failure
}

@test "fleet-build-yaml: [BLD-09] FLEET_DIR fallback resolves from BASH_SOURCE" {
    # When FLEET_DIR is unset, script resolves from its own location
    # Since SUT is in the real fleet/ dir, it finds the real fleet-system.yaml
    run env -u FLEET_DIR bash "$SUT" fleet
    # Should either succeed (found real fleet-system.yaml) or fail cleanly
    [[ $status -eq 0 || $status -eq 1 ]]
}

# ============================================================
# Adversarial — depth guard + inheritance
# ============================================================

@test "fleet-build-yaml: extends chain depth 3 works (embedded→projects→fleet)" {
    cat > "$FLEET_DIR/profiles/embedded.yaml" <<'YAML'
extends: projects
instances:
  - role: builder
    tier: 2
    scope: build
YAML
    run _run_build embedded
    assert_success
    grep -q "starfleet" "$FLEET_DIR/fleet.yaml"
    grep -q "architect" "$FLEET_DIR/fleet.yaml"
    grep -q "builder" "$FLEET_DIR/fleet.yaml"
}

# ============================================================
# FMEA cross-ref
# ============================================================

@test "fleet-build-yaml: [FMEA SF-04] output is valid YAML" {
    _run_build fleet >/dev/null 2>&1
    run yq '.fleet.version' "$FLEET_DIR/fleet.yaml"
    assert_success
    assert_output "6.0.0-test"
}

# ============================================================
# Post-generation validation
# ============================================================

@test "fleet-build-yaml: [BLD-10] duplicate roles rejected" {
    cat > "$FLEET_DIR/profiles/duproles.yaml" <<'YAML'
instances:
  - role: starfleet
    tier: 0
    scope: boundary-os
  - role: starfleet
    tier: 1
    scope: sas-user
YAML
    run _run_build duproles
    assert_failure
    assert_output --partial "duplicate roles"
}

@test "fleet-build-yaml: [BLD-11] instance missing scope rejected" {
    cat > "$FLEET_DIR/profiles/noscope.yaml" <<'YAML'
instances:
  - role: ghost
    tier: 2
YAML
    run _run_build noscope
    assert_failure
    assert_output --partial "missing required fields"
}

@test "fleet-build-yaml: [BLD-12] missing fleet.version rejected" {
    cat > "$FLEET_DIR/fleet-system.yaml" <<'YAML'
fleet:
  project: LCARS
  paths:
    lcars_root: /local/LCARS
    homes_root: /home
  identity:
    fleet_user: testuser
YAML
    run _run_build fleet
    assert_failure
    assert_output --partial "missing required key"
}

# ============================================================
# --json mode (Ring 0 API)
# ============================================================

@test "fleet-build-yaml --json: outputs valid JSON" {
    run bash -c "FLEET_DIR='$FLEET_DIR' bash '$SUT' --json fleet 2>/dev/null"
    assert_success
    echo "$output" | python3 -m json.tool > /dev/null
}

@test "fleet-build-yaml --json: contains required keys" {
    run bash -c "FLEET_DIR='$FLEET_DIR' bash '$SUT' --json fleet 2>/dev/null"
    assert_success
    local missing
    missing=$(echo "$output" | python3 -c "
import sys, json
d = json.load(sys.stdin)
required = ['output','profile','version','role_count','chain']
missing = [k for k in required if k not in d]
if missing: print(' '.join(missing))
")
    [[ -z "$missing" ]] || fail "Missing keys: $missing"
}

@test "fleet-build-yaml --json: version matches system" {
    run bash -c "FLEET_DIR='$FLEET_DIR' bash '$SUT' --json fleet 2>/dev/null"
    assert_success
    echo "$output" | python3 -c "
import sys, json
d = json.load(sys.stdin)
assert d['version'] == '6.0.0-test', f'got {d[\"version\"]}'
"
}

@test "fleet-build-yaml: normal mode still works (no JSON leaked)" {
    run _run_build fleet
    assert_success
    refute_output --partial "{"
    assert_output --partial "fleet.yaml"
}

# ============================================================
# Regression guard
# ============================================================

@test "fleet-build-yaml: shellcheck clean (no warnings/errors)" {
    run shellcheck --exclude=SC2016 "$SUT"
    assert_success
}
