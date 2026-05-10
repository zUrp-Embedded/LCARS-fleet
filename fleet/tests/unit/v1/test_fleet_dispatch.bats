#!/usr/bin/env bats
# test_fleet_dispatch.bats — Unit tests for fleet/fleet-dispatch.sh
# Ring 3 kernel. Tests error paths, --help, argument parsing.
# Dispatch requires sudo + claude -p → integration test for nominal path.

setup() {
    source "$BATS_TEST_DIRNAME/../helpers/test_helpers.bash"
    _setup

    # Create sandbox with fleet-env shim
    SANDBOX="$BATS_TEST_TMPDIR/sandbox"
    mkdir -p "$SANDBOX"
    cp "$REPO_ROOT/fleet/fleet-dispatch.sh" "$SANDBOX/"
    SUT="$SANDBOX/fleet-dispatch.sh"

    # Shim fleet-env: provide variables, stub yq/functions
    cat > "$SANDBOX/fleet-env.sh" <<ENVSHIM
FLEET_YAML="$BATS_TEST_TMPDIR/fleet.yaml"
FLEET_INSTANCE="starfleet"
FLEET_TMUX_SOCK="/tmp/nonexistent.sock"
FLEET_SPOOL_INBOX="$BATS_TEST_TMPDIR/spool/inbox"
_yq() { yq "\$@" "\$FLEET_YAML" 2>/dev/null; }
fleet_find_pane() { echo ""; }
export -f _yq fleet_find_pane
ENVSHIM

    # Minimal fleet.yaml with a headless role
    cat > "$BATS_TEST_TMPDIR/fleet.yaml" <<'YAML'
instances:
  - role: qualifier
    tier: 2
    scope: test
    headless:
      max_turns: 5
      timeout: 30
      allowed_tools: "Read,Grep,Glob"
  - role: dev
    tier: 2
    scope: code
YAML
}

teardown() { _teardown; }

# ============================================================
# --help
# ============================================================

@test "fleet-dispatch: --help exits 0" {
    run bash "$REPO_ROOT/fleet/fleet-dispatch.sh" --help
    assert_success
    assert_output --partial "NAME"
    assert_output --partial "INTERFACE"
}

# ============================================================
# Argument validation
# ============================================================

@test "fleet-dispatch: no arguments — exits 1" {
    run bash "$SUT"
    assert_failure
}

@test "fleet-dispatch: role only, no subject — exits 1" {
    run bash "$SUT" qualifier
    assert_failure
}

@test "fleet-dispatch: unknown role — exits 1" {
    run bash "$SUT" nonexistent "test task" <<< "prompt"
    assert_failure
    assert_output --partial "not found"
}

# ============================================================
# Shellcheck
# ============================================================

@test "fleet-dispatch: shellcheck clean" {
    if ! command -v shellcheck &>/dev/null; then skip "shellcheck not installed"; fi
    run shellcheck -S warning "$REPO_ROOT/fleet/fleet-dispatch.sh"
    assert_success
}
