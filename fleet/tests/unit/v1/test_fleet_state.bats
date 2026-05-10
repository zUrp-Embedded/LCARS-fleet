#!/usr/bin/env bats
# test_fleet_state.bats — Unit tests for fleet/fleet-state.sh
#
# Reference: docs/qualification/plans/phase2-failure-modes.md (STA-01 to STA-09)
#
# fleet-state.sh sources fleet-env.sh, requires FLEET_SESSION set,
# takes key=value args, updates handoff STATE section via sed,
# creates handoff template if missing, rsyncs to ready-room.
# Tests use the FULL test_helpers mock environment.
#
# Strategy: copy SUT to sandbox with a fleet-env.sh shim that preserves
# mock variables. Always export FLEET_SESSION=1 in run commands.

# ============================================================
# Setup / Teardown
# ============================================================

setup() {
    source "$BATS_TEST_DIRNAME/../helpers/test_helpers.bash"
    _setup

    # Copy SUT to sandbox and create a fleet-env.sh shim next to it
    SANDBOX="$BATS_TEST_TMPDIR/sandbox"
    mkdir -p "$SANDBOX"
    cp "$REPO_ROOT/fleet/fleet-state.sh" "$SANDBOX/"
    SUT="$SANDBOX/fleet-state.sh"

    # Shim fleet-env.sh: re-export the mock variables + stub functions
    cat > "$SANDBOX/fleet-env.sh" <<'ENVSHIM'
# shim — variables already exported by mock_fleet_env.bash
fleet_bin() {
    local bin="$1"
    if [[ -x "${BATS_TEST_TMPDIR:-/tmp}/bin/$bin" ]]; then
        echo "${BATS_TEST_TMPDIR:-/tmp}/bin/$bin"
    else
        echo ""
    fi
}
export -f fleet_bin
ENVSHIM

    # Directories from mock_fleet_env
    mkdir -p "$FLEET_HANDOFFS"
    mkdir -p "$FLEET_LOGS"
    mkdir -p "$FLEET_READY_ROOM/handoffs"

    INSTANCE="${FLEET_INSTANCE:-starfleet}"
    HANDOFF_FILE="$FLEET_HANDOFFS/${INSTANCE}-handoff.md"

    # Export FLEET_SESSION=1 globally — individual tests that need it unset
    # will override in their run command
    export FLEET_SESSION=1
}

teardown() {
    # Restore permissions in case a test set read-only dirs
    chmod -R u+w "$BATS_TEST_TMPDIR" 2>/dev/null || true
    _teardown
}

# Helper: create a handoff fixture with STATE section
_create_handoff() {
    cat > "$HANDOFF_FILE" <<'EOF'
## STATE
date: 2026-03-25 10:00
ref: none
action: idle
status: pending
blocker: none
waiting: none
notify: none

## ACTIONS

## DONE
### 2026-03-25 — test fixture
Test handoff fixture.
EOF
}

# ============================================================
# Nominal tests
# ============================================================

@test "fleet-state: updates action field in handoff" {
    _create_handoff
    run bash "$SUT" action=coding
    assert_success
    run grep "^action:" "$HANDOFF_FILE"
    assert_output --partial "coding"
}

@test "fleet-state: updates status field in handoff" {
    _create_handoff
    run bash "$SUT" status=active
    assert_success
    run grep "^status:" "$HANDOFF_FILE"
    assert_output --partial "active"
}

@test "fleet-state: updates multiple fields at once" {
    _create_handoff
    run bash "$SUT" action=review status=active blocker=none
    assert_success
    run grep "^action:" "$HANDOFF_FILE"
    assert_output --partial "review"
    run grep "^status:" "$HANDOFF_FILE"
    assert_output --partial "active"
}

@test "fleet-state: updates date field automatically" {
    _create_handoff
    run bash "$SUT" action=coding
    assert_success
    # Date should no longer be the fixture value
    run grep "^date:" "$HANDOFF_FILE"
    refute_output --partial "2026-03-25 10:00"
}

@test "fleet-state: outputs confirmation with instance and args" {
    _create_handoff
    run bash "$SUT" action=idle
    assert_success
    assert_output --partial "$INSTANCE"
    assert_output --partial "STATE"
}

@test "fleet-state: logs action transitions to fleet-state.log" {
    _create_handoff
    run bash "$SUT" action=handoff
    assert_success
    [[ -f "$FLEET_LOGS/fleet-state.log" ]]
    run cat "$FLEET_LOGS/fleet-state.log"
    assert_output --partial "action=handoff"
}

@test "fleet-state: logs status transitions to fleet-state.log" {
    _create_handoff
    run bash "$SUT" status=offline
    assert_success
    [[ -f "$FLEET_LOGS/fleet-state.log" ]]
    run cat "$FLEET_LOGS/fleet-state.log"
    assert_output --partial "status=offline"
}

# ============================================================
# Error tests — STA-01 to STA-09
# ============================================================

@test "fleet-state: [STA-01] FLEET_SESSION not defined — exits silently" {
    _create_handoff
    run bash -c 'unset FLEET_SESSION; bash "'"$SUT"'" action=idle'
    assert_success
    # No STATE output — silent exit at guard line 59
    refute_output --partial "STATE"
}

@test "fleet-state: [STA-01] FLEET_SESSION empty string — exits silently" {
    _create_handoff
    run env FLEET_SESSION="" bash "$SUT" action=idle
    assert_success
    refute_output --partial "STATE"
}

@test "fleet-state: [STA-02] zero arguments — exits with usage error" {
    _create_handoff
    run bash "$SUT"
    assert_failure
    assert_output --partial "usage"
}

@test "fleet-state: [STA-03] unknown key in arguments — warns and ignores" {
    _create_handoff
    run bash "$SUT" garbage=value
    assert_success
    assert_output --partial "WARNING"
    assert_output --partial "garbage"
}

@test "fleet-state: [STA-03] mix of valid and unknown keys — valid applied, unknown warned" {
    _create_handoff
    run bash "$SUT" action=coding unknown_field=test
    assert_success
    assert_output --partial "WARNING"
    assert_output --partial "unknown_field"
    run grep "^action:" "$HANDOFF_FILE"
    assert_output --partial "coding"
}

@test "fleet-state: [STA-04] handoff file absent (first run) — creates template" {
    rm -f "$HANDOFF_FILE"
    run bash "$SUT" action=idle
    assert_success
    [[ -f "$HANDOFF_FILE" ]]
    run grep "## STATE" "$HANDOFF_FILE"
    assert_success
    run grep "## ACTIONS" "$HANDOFF_FILE"
    assert_success
    run grep "## DONE" "$HANDOFF_FILE"
    assert_success
}

@test "fleet-state: [STA-04] handoff created on first run — then updated" {
    rm -f "$HANDOFF_FILE"
    run bash "$SUT" action=coding
    assert_success
    run grep "^action:" "$HANDOFF_FILE"
    assert_output --partial "coding"
}

@test "fleet-state: [STA-05] section ## STATE absent from handoff — warns and skips" {
    # Create a handoff without the STATE section
    printf '## ACTIONS\nNothing here.\n' > "$HANDOFF_FILE"
    run bash "$SUT" action=idle
    assert_success
    assert_output --partial "STATE"
}

@test "fleet-state: [STA-06] value containing pipes — sed metacharacter escaped" {
    _create_handoff
    run bash "$SUT" "blocker=a|b|c"
    assert_success
    run grep "^blocker:" "$HANDOFF_FILE"
    assert_output --partial "a|b|c"
}

@test "fleet-state: [STA-06] value with multiple special chars — handled correctly" {
    _create_handoff
    run bash "$SUT" "ref=issue#42|PR#99"
    assert_success
    run grep "^ref:" "$HANDOFF_FILE"
    assert_output --partial "issue#42|PR#99"
}

@test "fleet-state: [STA-07] sed fails on file (permission denied) — error emitted" {
    [[ "$(id -u)" == "0" ]] && skip "running as root — permission test meaningless"
    _create_handoff
    # Make the handoffs directory read-only so sed cannot write the .tmp file.
    # Note: set -e does not catch the redirect failure in `sed ... > f.tmp && mv`,
    # so the script continues. But the permission error IS emitted to stderr.
    chmod 555 "$FLEET_HANDOFFS"
    run bash "$SUT" action=coding 2>&1
    assert_output --partial "Permission denied"
    # Handoff should NOT have been updated (sed redirect failed)
    run grep "^action:" "$HANDOFF_FILE"
    assert_output --partial "idle"
    # Cleanup
    chmod 755 "$FLEET_HANDOFFS"
}

@test "fleet-state: [STA-08] rsync to ready-room fails — no crash (|| true guard)" {
    _create_handoff
    # Remove ready-room/handoffs so rsync condition is false
    rm -rf "$FLEET_READY_ROOM/handoffs"
    run bash "$SUT" action=coding
    # Script checks -d before rsync — should not crash
    assert_success
}

@test "fleet-state: [STA-09] fleet-session-log.sh absent when action=handoff — no crash" {
    _create_handoff
    # Ensure fleet-session-log.sh is NOT in PATH or bin dir
    rm -f "$BATS_TEST_TMPDIR/bin/fleet-session-log.sh"
    run bash "$SUT" action=handoff
    # fleet_bin returns "" and the [[ -n ]] guard prevents execution
    assert_success
}

@test "fleet-state: [STA-09] fleet-session-log.sh absent when status=offline — no crash" {
    _create_handoff
    rm -f "$BATS_TEST_TMPDIR/bin/fleet-session-log.sh"
    run bash "$SUT" status=offline
    assert_success
}

# ============================================================
# --help flag
# ============================================================

@test "fleet-state: --help outputs description and exits" {
    run bash "$SUT" --help
    assert_success
    assert_output --partial "fleet-state.sh"
}

# ============================================================
# Regression guard
# ============================================================

@test "fleet-state: shellcheck clean (no warnings/errors)" {
    run shellcheck --exclude=SC1091,SC2015,SC2016 "$REPO_ROOT/fleet/fleet-state.sh"
    assert_success
}
