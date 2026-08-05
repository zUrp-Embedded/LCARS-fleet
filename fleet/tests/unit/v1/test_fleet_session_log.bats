#!/usr/bin/env bats
# test_fleet_session_log.bats — Unit tests for fleet/fleet-session-log.sh
#
# Reference: docs/qualification/plans/phase2-failure-modes.md (LOG-01 to LOG-05)
#
# fleet-session-log.sh sources fleet-env.sh, reads a start timestamp file,
# calculates session duration, logs to $FLEET_LOGS/session-durations.log.
# Tests use the FULL test_helpers mock environment.
#
# Strategy: the SUT sources fleet-env.sh via BASH_SOURCE-relative path.
# We copy it to a sandbox dir alongside a shim fleet-env.sh that just
# re-exports the mock variables already set by test_helpers.

# ============================================================
# Setup / Teardown
# ============================================================

setup() {
    source "$BATS_TEST_DIRNAME/../../helpers/v1/test_helpers.bash"
    _setup

    # Copy SUT to sandbox and create a fleet-env.sh shim next to it
    SANDBOX="$BATS_TEST_TMPDIR/sandbox"
    mkdir -p "$SANDBOX"
    cp "$REPO_ROOT/fleet/v1/fleet-session-log.sh" "$SANDBOX/"
    SUT="$SANDBOX/fleet-session-log.sh"

    # Shim fleet-env.sh: re-export the mock variables + stub functions
    cat > "$SANDBOX/fleet-env.sh" <<'ENVSHIM'
# shim — variables already exported by mock_fleet_env.bash
# fleet_bin function needed by fleet-state.sh (not this script, but harmless)
fleet_bin() {
    local bin="$1"
    command -v "$bin" 2>/dev/null && return
    echo ""
}
export -f fleet_bin
ENVSHIM

    # FLEET_LOGS is set by mock_fleet_env to $BATS_TEST_TMPDIR/fleet-state
    mkdir -p "$FLEET_LOGS"

    INSTANCE="${FLEET_INSTANCE:-starfleet}"
    START_FILE="${FLEET_STATE_DIR:-/home/fleet-state}/run/session-start-${INSTANCE}"
    LOG_FILE="$FLEET_LOGS/session-durations.log"
}

teardown() {
    # Clean up start file if created in /tmp
    rm -f "${FLEET_STATE_DIR:-/home/fleet-state}/run/session-start-${INSTANCE:-starfleet}" 2>/dev/null || true
    _teardown
}

# Helper: write a start timestamp N minutes ago
_write_start_file() {
    local minutes_ago="${1:-10}"
    local ts=$(( $(date +%s) - minutes_ago * 60 ))
    echo "$ts" > "$START_FILE"
}

# ============================================================
# Nominal tests
# ============================================================

@test "fleet-session-log: logs session duration when start file exists" {
    _write_start_file 10
    run bash "$SUT"
    assert_success
    assert_output --partial "session"
    [[ -f "$LOG_FILE" ]]
    run cat "$LOG_FILE"
    assert_output --partial "${INSTANCE}"
    assert_output --partial "10m"
}

@test "fleet-session-log: default action is handoff" {
    _write_start_file 5
    run bash "$SUT"
    assert_success
    run cat "$LOG_FILE"
    assert_output --partial "handoff"
}

@test "fleet-session-log: accepts custom action argument" {
    _write_start_file 5
    run bash "$SUT" offline
    assert_success
    run cat "$LOG_FILE"
    assert_output --partial "offline"
}

@test "fleet-session-log: cleans up start file after logging" {
    _write_start_file 5
    run bash "$SUT"
    assert_success
    [[ ! -f "$START_FILE" ]]
}

@test "fleet-session-log: NOTICE for sessions >= 120 min" {
    _write_start_file 130
    run bash "$SUT"
    assert_success
    assert_output --partial "NOTICE:long-session"
}

@test "fleet-session-log: WARNING for sessions >= 180 min" {
    _write_start_file 200
    run bash "$SUT"
    assert_success
    assert_output --partial "WARNING:drift-risk"
}

@test "fleet-session-log: no warning for short sessions" {
    _write_start_file 30
    run bash "$SUT"
    assert_success
    refute_output --partial "WARNING"
    refute_output --partial "NOTICE"
}

# ============================================================
# Error tests — LOG-01 to LOG-05
# ============================================================

@test "fleet-session-log: [LOG-01] fleet-env.sh absent — source error emitted" {
    # Remove the shim so the script cannot find fleet-env.sh
    # Note: set -uo (not -euo) means the script continues after failed source,
    # but the source error IS emitted to stderr.
    rm -f "$SANDBOX/fleet-env.sh"
    run bash "$SUT" 2>&1
    assert_output --partial "No such file or directory"
}

@test "fleet-session-log: [LOG-02] start timestamp file absent — logs unknown" {
    rm -f "$START_FILE"
    run bash "$SUT"
    assert_success
    [[ -f "$LOG_FILE" ]]
    run cat "$LOG_FILE"
    assert_output --partial "unknown"
    assert_output --partial "$INSTANCE"
}

@test "fleet-session-log: [LOG-02] start file absent — outputs explanatory message" {
    rm -f "$START_FILE"
    run bash "$SUT"
    assert_success
    assert_output --partial "no start timestamp found"
}

@test "fleet-session-log: [LOG-03] start file contains non-numeric text — logs unknown" {
    echo "not-a-number" > "$START_FILE"
    run bash "$SUT"
    assert_success
    [[ -f "$LOG_FILE" ]]
    run cat "$LOG_FILE"
    assert_output --partial "unknown"
}

@test "fleet-session-log: [LOG-03] start file contains mixed text — regex guard catches it" {
    echo "12345abc" > "$START_FILE"
    run bash "$SUT"
    assert_success
    [[ -f "$LOG_FILE" ]]
    run cat "$LOG_FILE"
    assert_output --partial "unknown"
}

@test "fleet-session-log: [LOG-03] start file is empty — treated as non-numeric" {
    echo "" > "$START_FILE"
    run bash "$SUT"
    assert_success
    [[ -f "$LOG_FILE" ]]
    run cat "$LOG_FILE"
    assert_output --partial "unknown"
}

@test "fleet-session-log: [LOG-04] FLEET_LOGS directory inaccessible — mkdir -p creates it" {
    local deep_log="$BATS_TEST_TMPDIR/deep/nested/logs"
    export FLEET_LOGS="$deep_log"
    run bash "$SUT"
    # Script does mkdir -p on log dir, should succeed even if dir didn't exist
    assert_success
    [[ -d "$deep_log" ]]
}

@test "fleet-session-log: [LOG-05] negative duration (start in the future) — logs value" {
    # Write a timestamp 10 minutes in the future
    local future_ts=$(( $(date +%s) + 600 ))
    echo "$future_ts" > "$START_FILE"
    run bash "$SUT"
    assert_success
    # Script doesn't guard against negative durations — it just logs them
    [[ -f "$LOG_FILE" ]]
}

# ============================================================
# Regression guard
# ============================================================

@test "fleet-session-log: shellcheck clean (no warnings/errors)" {
    run shellcheck --exclude=SC1091,SC2016 "$REPO_ROOT/fleet/v1/fleet-session-log.sh"
    assert_success
}
