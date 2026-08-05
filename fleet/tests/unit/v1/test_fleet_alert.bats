#!/usr/bin/env bats
# test_fleet_alert.bats — Unit tests for fleet/fleet-alert.sh
#
# Tests the gyrophare: --stop mode, PID guard, argument validation.
# Cannot test the actual blink loop (requires tmux) — tested via --stop
# and error paths only.

setup() {
    source "$BATS_TEST_DIRNAME/../../helpers/v1/test_helpers.bash"
    _setup

    SUT="$REPO_ROOT/fleet/v1/fleet-alert.sh"

    # Mock tmux
    mkdir -p "$BATS_TEST_TMPDIR/bin"
    cat > "$BATS_TEST_TMPDIR/bin/tmux" <<'TMUX'
#!/bin/bash
echo "MOCK_TMUX: $*" >> "$BATS_TEST_TMPDIR/tmux.log"
exit 0
TMUX
    chmod +x "$BATS_TEST_TMPDIR/bin/tmux"

    # Mock sudo — pass through
    cat > "$BATS_TEST_TMPDIR/bin/sudo" <<'SUDO'
#!/bin/bash
# Strip sudo, execute the rest
shift  # remove -u
shift  # remove username
"$@"
SUDO
    chmod +x "$BATS_TEST_TMPDIR/bin/sudo"

    export PATH="$BATS_TEST_TMPDIR/bin:$PATH"
}

teardown() {
    # Kill any lingering blink processes
    [[ -f /tmp/fleet-alert.pid ]] && kill "$(cat /tmp/fleet-alert.pid)" 2>/dev/null
    rm -f /tmp/fleet-alert.pid
    _teardown
}

# ============================================================
# Nominal
# ============================================================

@test "fleet-alert --stop: exits cleanly" {
    run bash "$SUT" --stop
    assert_success
}

@test "fleet-alert: no agent arg exits with error" {
    run bash "$SUT"
    assert_failure
}

@test "fleet-alert: with agent arg exits 0 (starts background blink)" {
    # Create a fake inbox with a message so the loop starts
    mkdir -p "$FLEET_SPOOL_INBOX/testagent"
    echo "test" > "$FLEET_SPOOL_INBOX/testagent/msg.md"

    run bash "$SUT" testagent
    assert_success
    assert_output --partial "gyrophare started"

    # Cleanup: remove the inbox message so the loop stops
    rm -f "$FLEET_SPOOL_INBOX/testagent/msg.md"
    sleep 1  # let the loop detect empty inbox
}

# ============================================================
# Regression guard
# ============================================================

@test "fleet-alert: shellcheck clean" {
    run shellcheck --exclude=SC1090,SC1091,SC2317 "$SUT"
    assert_success
}
