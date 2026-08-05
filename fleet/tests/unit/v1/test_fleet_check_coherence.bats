#!/usr/bin/env bats
# test_fleet_check_coherence.bats — Unit tests for fleet/fleet-check-coherence.sh
#
# fleet-check-coherence.sh compares source CLAUDE.md vs deployed copies.
# Reports drift via fleet-send.sh. Runs once per day (sentinel).

# ============================================================
# Setup / Teardown
# ============================================================

setup() {
    source "$BATS_TEST_DIRNAME/../../helpers/v1/test_helpers.bash"
    _setup

    # Copy SUT to sandbox with fleet-env shim
    SANDBOX="$BATS_TEST_TMPDIR/sandbox"
    mkdir -p "$SANDBOX"
    cp "$REPO_ROOT/fleet/v1/fleet-check-coherence.sh" "$SANDBOX/"
    SUT="$SANDBOX/fleet-check-coherence.sh"

    # Mock LCARS root with source .claude/CLAUDE.md (B5 fix: real path)
    MOCK_LCARS="$BATS_TEST_TMPDIR/lcars"
    mkdir -p "$MOCK_LCARS/.claude"
    echo "source CLAUDE.md content" > "$MOCK_LCARS/.claude/CLAUDE.md"

    # Mock homes with deployed copies
    MOCK_HOMES="$BATS_TEST_TMPDIR/homes"
    mkdir -p "$MOCK_HOMES"

    # Create fleet-env shim
    cat > "$SANDBOX/fleet-env.sh" <<ENVSHIM
export LCARS_ROOT="$MOCK_LCARS"
export HOMES_ROOT="$MOCK_HOMES"
export FLEET_LOGS="$BATS_TEST_TMPDIR/logs"
mkdir -p "\$FLEET_LOGS"
fleet_roles() {
    echo "agent1"
    echo "agent2"
}
export -f fleet_roles
fleet_bin() {
    echo ""
}
export -f fleet_bin
ENVSHIM

    # Remove any sentinel from today
    rm -f "${FLEET_STATE_DIR:-/home/fleet-state}/run/coherence-check-$(date +%Y-%m-%d)"
}

teardown() {
    rm -f "${FLEET_STATE_DIR:-/home/fleet-state}/run/coherence-check-$(date +%Y-%m-%d)"
    _teardown
}

# Helper: deploy a CLAUDE.md for an agent (matching source)
_deploy_matching() {
    local agent="$1"
    mkdir -p "$MOCK_HOMES/$agent/.claude"
    cp "$MOCK_LCARS/.claude/CLAUDE.md" "$MOCK_HOMES/$agent/.claude/CLAUDE.md"
}

# Helper: deploy a CLAUDE.md for an agent (different from source)
_deploy_drifted() {
    local agent="$1"
    mkdir -p "$MOCK_HOMES/$agent/.claude"
    echo "DRIFTED content" > "$MOCK_HOMES/$agent/.claude/CLAUDE.md"
}

# ============================================================
# Nominal tests
# ============================================================

@test "check-coherence: --help displays man page" {
    run bash "$SUT" --help
    assert_success
    assert_output --partial "NAME"
    assert_output --partial "fleet-check-coherence.sh"
}

@test "check-coherence: all in sync — reports OK" {
    _deploy_matching "agent1"
    _deploy_matching "agent2"
    run bash "$SUT"
    assert_success
    assert_output --partial "OK"
    assert_output --partial "all CLAUDE.md in sync"
}

@test "check-coherence: drift detected — reports drift" {
    _deploy_matching "agent1"
    _deploy_drifted "agent2"
    run bash "$SUT"
    assert_success
    assert_output --partial "drift detected"
}

@test "check-coherence: missing deployed file — reports missing" {
    _deploy_matching "agent1"
    # agent2 has no deployed CLAUDE.md
    mkdir -p "$MOCK_HOMES/agent2/.claude"
    run bash "$SUT"
    assert_success
    assert_output --partial "drift detected"
}

@test "check-coherence: creates sentinel file" {
    _deploy_matching "agent1"
    _deploy_matching "agent2"
    run bash "$SUT"
    assert_success
    [[ -f "${FLEET_STATE_DIR:-/home/fleet-state}/run/coherence-check-$(date +%Y-%m-%d)" ]]
}

@test "check-coherence: skips if sentinel exists (once per day)" {
    touch "${FLEET_STATE_DIR:-/home/fleet-state}/run/coherence-check-$(date +%Y-%m-%d)"
    _deploy_drifted "agent1"
    _deploy_drifted "agent2"
    run bash "$SUT"
    assert_success
    # Should exit immediately without checking
    refute_output --partial "drift"
    refute_output --partial "OK"
}

# ============================================================
# Regression guard
# ============================================================

@test "check-coherence: shellcheck clean" {
    run shellcheck --exclude=SC1091,SC1090,SC2016 "$REPO_ROOT/fleet/v1/fleet-check-coherence.sh"
    assert_success
}
