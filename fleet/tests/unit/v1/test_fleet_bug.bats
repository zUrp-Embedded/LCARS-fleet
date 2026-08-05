#!/usr/bin/env bats
# test_fleet_bug.bats — Unit tests for fleet/fleet-bug.sh
#
# fleet-bug.sh sends a bug report to starfleet via fleet-send.sh.

# ============================================================
# Setup / Teardown
# ============================================================

setup() {
    source "$BATS_TEST_DIRNAME/../../helpers/v1/test_helpers.bash"
    _setup

    # Copy SUT to sandbox
    SANDBOX="$BATS_TEST_TMPDIR/sandbox"
    mkdir -p "$SANDBOX"
    cp "$REPO_ROOT/fleet/v1/fleet-bug.sh" "$SANDBOX/"
    SUT="$SANDBOX/fleet-bug.sh"

    # Create fleet-env shim
    cat > "$SANDBOX/fleet-env.sh" <<'ENVSHIM'
:
ENVSHIM

    # Create mock fleet-send.sh that logs what it receives
    SEND_LOG="$BATS_TEST_TMPDIR/send-log.txt"
    cat > "$SANDBOX/fleet-send.sh" <<SENDSHIM
#!/bin/bash
echo "TO=\$1 SUBJECT=\$2" > "$SEND_LOG"
cat >> "$SEND_LOG"
SENDSHIM
    chmod +x "$SANDBOX/fleet-send.sh"
}

teardown() {
    _teardown
}

# ============================================================
# Nominal tests
# ============================================================

@test "fleet-bug: --help displays man page" {
    run bash "$SUT" --help
    assert_success
    assert_output --partial "NAME"
    assert_output --partial "fleet-bug.sh"
}

@test "fleet-bug: sends bug report with correct format" {
    run bash "$SUT" dev WSL "deploy fails on drvfs"
    assert_success
    assert_output --partial "bug report sent"
    # Check what fleet-send received
    [[ -f "$SEND_LOG" ]]
    run cat "$SEND_LOG"
    assert_output --partial "TO=starfleet"
    assert_output --partial "SUBJECT=bug-report"
    assert_output --partial "BUG"
    assert_output --partial "dev"
    assert_output --partial "WSL"
    assert_output --partial "deploy fails on drvfs"
}

@test "fleet-bug: includes date in report" {
    run bash "$SUT" qualifier ARM "test timeout"
    assert_success
    run cat "$SEND_LOG"
    assert_output --partial "$(date '+%Y-%m-%d')"
}

# ============================================================
# Error tests
# ============================================================

@test "fleet-bug: exits 1 with no arguments" {
    run bash "$SUT"
    assert_failure
    assert_output --partial "usage"
}

@test "fleet-bug: exits 1 with only source" {
    run bash "$SUT" dev
    assert_failure
    assert_output --partial "usage"
}

@test "fleet-bug: exits 1 with source and platform but no description" {
    run bash "$SUT" dev WSL
    assert_failure
}

@test "fleet-bug: exits 1 when fleet-send.sh not found" {
    rm "$SANDBOX/fleet-send.sh"
    run bash "$SUT" dev WSL "some bug"
    assert_failure
    assert_output --partial "fleet-send.sh not found"
}

# ============================================================
# Regression guard
# ============================================================

@test "fleet-bug: shellcheck clean" {
    run shellcheck --exclude=SC1091,SC1090,SC2016 "$REPO_ROOT/fleet/v1/fleet-bug.sh"
    assert_success
}
