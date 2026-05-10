#!/usr/bin/env bats
# test_fleet_wake_notify.bats — Unit tests for fleet/fleet-wake-notify.sh
#
# Tests the wake primitive: pane resolution, sentinel injection,
# pending wake file creation, non-wakeable agent handling.

setup() {
    source "$BATS_TEST_DIRNAME/../helpers/test_helpers.bash"
    _setup

    SUT="$REPO_ROOT/fleet/fleet-wake-notify.sh"

    # Create mock fleet-env.sh in the same dir as SUT so it sources it
    # (fleet-wake-notify resolves fleet-env via dirname BASH_SOURCE)
    # We use the real SUT but with mocked environment.

    # Setup pending-wakes dir
    mkdir -p "$FLEET_PENDING_WAKES"

    # Mock yq — return wakeable=true by default
    mkdir -p "$BATS_TEST_TMPDIR/bin"
    cat > "$BATS_TEST_TMPDIR/bin/yq" <<'YQ'
#!/bin/bash
# Mock yq for wake-notify tests
echo "true"
YQ
    chmod +x "$BATS_TEST_TMPDIR/bin/yq"
    export PATH="$BATS_TEST_TMPDIR/bin:$PATH"

    # Mock tmux — log calls instead of executing
    cat > "$BATS_TEST_TMPDIR/bin/tmux" <<'TMUX'
#!/bin/bash
echo "MOCK_TMUX: $*" >> "$BATS_TEST_TMPDIR/tmux.log"
# send-keys: pretend success
exit 0
TMUX
    chmod +x "$BATS_TEST_TMPDIR/bin/tmux"
}

teardown() {
    _teardown
}

# ============================================================
# Nominal
# ============================================================

@test "fleet-wake-notify: no agent arg exits with error" {
    run bash "$SUT"
    assert_failure
}

@test "fleet-wake-notify: agent without pane writes pending wake" {
    # fleet-wake-notify sources fleet-env from its own dirname.
    # We pre-export the variables so fleet-env's re-source guard skips.
    run bash -c "
        export _FLEET_ENV_LOADED=1
        export FLEET_TMUX_SOCK=/nonexistent
        export FLEET_PENDING_WAKES='$FLEET_PENDING_WAKES'
        export FLEET_YAML='$FLEET_YAML'
        export PATH='$BATS_TEST_TMPDIR/bin':"\$PATH"
        fleet_find_pane() { echo ''; }
        fleet_tmux() { echo 'MOCK_TMUX' >> '$BATS_TEST_TMPDIR/tmux.log'; }
        export -f fleet_find_pane fleet_tmux
        bash '$SUT' testdev 2>&1
    "
    assert_success
    assert_output --partial "pending wake"
    local wakes
    wakes=$(find "$FLEET_PENDING_WAKES/testdev" -name "*.wake" 2>/dev/null | wc -l)
    [[ "$wakes" -ge 1 ]] || fail "No .wake file created"
}

@test "fleet-wake-notify: wake file contains correct metadata" {
    bash -c "
        export _FLEET_ENV_LOADED=1
        export FLEET_TMUX_SOCK=/nonexistent
        export FLEET_PENDING_WAKES='$FLEET_PENDING_WAKES'
        export FLEET_YAML='$FLEET_YAML'
        export PATH='$BATS_TEST_TMPDIR/bin':"\$PATH"
        fleet_find_pane() { echo ''; }
        fleet_tmux() { true; }
        export -f fleet_find_pane fleet_tmux
        bash '$SUT' myagent 'test-subject' 2>/dev/null
    "
    local wakefile
    wakefile=$(find "$FLEET_PENDING_WAKES/myagent" -name "*.wake" | head -1)
    [[ -f "$wakefile" ]] || fail "No wake file"
    run grep "Agent: myagent" "$wakefile"
    assert_success
    run grep "Subject: test-subject" "$wakefile"
    assert_success
}

@test "fleet-wake-notify: default subject is 'wake'" {
    bash -c "
        export _FLEET_ENV_LOADED=1
        export FLEET_TMUX_SOCK=/nonexistent
        export FLEET_PENDING_WAKES='$FLEET_PENDING_WAKES'
        export FLEET_YAML='$FLEET_YAML'
        export PATH='$BATS_TEST_TMPDIR/bin':"\$PATH"
        fleet_find_pane() { echo ''; }
        fleet_tmux() { true; }
        export -f fleet_find_pane fleet_tmux
        bash '$SUT' myagent 2>/dev/null
    "
    local wakefile
    wakefile=$(find "$FLEET_PENDING_WAKES/myagent" -name "*-wake.wake" | head -1)
    [[ -f "$wakefile" ]] || fail "No wake file with default subject"
}

# ============================================================
# Regression guard
# ============================================================

@test "fleet-wake-notify: shellcheck clean" {
    run shellcheck --exclude=SC1090,SC1091,SC2317 "$SUT"
    assert_success
}
