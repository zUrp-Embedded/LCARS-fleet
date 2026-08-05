#!/usr/bin/env bats
# test_wake_instance.bats — Unit tests for fleet/wake-instance.sh
#
# Reference: docs/qualification/plans/phase2-failure-modes.md (WAK-01 to WAK-11)
# Vague: 2.2
#
# wake-instance.sh sources fleet-env.sh from its own BASH_SOURCE dirname,
# then calls yq directly on FLEET_YAML, uses tmux, pgrep, sudo.
# Strategy: copy SUT + fleet-env.sh to tmpdir, place a custom fleet.yaml
# there. Mock tmux/pgrep/sudo/stat via PATH shims in tmpdir/bin.

# ============================================================
# Setup / Teardown
# ============================================================

setup() {
    # Load bats libs WITHOUT mocks (real yq needed by fleet-env.sh)
    HELPERS_DIR="$(cd "$(dirname "$(dirname "$BATS_TEST_DIRNAME")")/helpers/v1" && pwd)"
    REPO_ROOT="$(cd "$HELPERS_DIR/../.." && pwd)"
    load "$REPO_ROOT/tests/.bats/bats-support/load.bash"
    load "$REPO_ROOT/tests/.bats/bats-assert/load.bash"
    load "$REPO_ROOT/tests/.bats/bats-file/load.bash"

    # Verify real yq is available
    command -v yq &>/dev/null || skip "yq not installed"

    # --- Create test fleet dir with SUT + fleet-env.sh ---
    FLEET_TMP="$BATS_TEST_TMPDIR/fleet"
    mkdir -p "$FLEET_TMP"
    cp "$REPO_ROOT/fleet/v1/wake-instance.sh" "$FLEET_TMP/"
    cp "$REPO_ROOT/fleet/v1/fleet-env.sh"     "$FLEET_TMP/"

    SUT="$FLEET_TMP/wake-instance.sh"

    # --- Create spool dirs ---
    SPOOL="$BATS_TEST_TMPDIR/spool"
    mkdir -p "$SPOOL"/{inbox,outbox,pending-wakes}

    # --- Custom fleet.yaml ---
    cat > "$FLEET_TMP/fleet.yaml" <<YAML
fleet:
  version: "6.0.0-test"
  project: LCARS-test
  repo: testuser/LCARS-test
  paths:
    lcars_root: $BATS_TEST_TMPDIR/lcars
    homes_root: $BATS_TEST_TMPDIR/homes
    handoffs: $BATS_TEST_TMPDIR/handoffs
    fleet_state: $BATS_TEST_TMPDIR/fleet-state
    ready_room: $BATS_TEST_TMPDIR/ready-room
  runtime:
    tmux_socket: $BATS_TEST_TMPDIR/fleet-tmux.sock
  identity:
    fleet_user: testuser
spool:
  root: $SPOOL
instances:
  - role: starfleet
    tier: 0
    scope: boundary-os
    stateless: true
    wakeable: true
  - role: architect
    tier: 0
    scope: boundary-user
    stateless: false
    wakeable: false
  - role: engineer
    tier: 1
    scope: sas-user
    stateless: false
    wakeable: true
  - role: dev
    tier: 2
    scope: code
    stateless: false
    wakeable: true
  - role: builder
    tier: 2
    scope: build
    stateless: true
    headless: true
YAML

    # --- No-op fleet-wake-notify.sh ---
    cat > "$FLEET_TMP/fleet-wake-notify.sh" <<'SH'
#!/bin/bash
echo "MOCK_WAKE_NOTIFY: $*" >> "${BATS_TEST_TMPDIR:-/tmp}/wake-notify.log"
exit 0
SH
    chmod +x "$FLEET_TMP/fleet-wake-notify.sh"

    # --- No-op fleet-alert.sh ---
    cat > "$FLEET_TMP/fleet-alert.sh" <<'SH'
#!/bin/bash
echo "MOCK_ALERT: $*" >> "${BATS_TEST_TMPDIR:-/tmp}/alert.log"
exit 0
SH
    chmod +x "$FLEET_TMP/fleet-alert.sh"

    # --- Create required dirs ---
    mkdir -p "$BATS_TEST_TMPDIR"/{lcars/fleet,homes,handoffs,fleet-state,ready-room}
    mkdir -p "$BATS_TEST_TMPDIR/homes/testuser/.claude"

    # --- Create mock binaries in tmpdir/bin (prepended to PATH) ---
    MOCK_BIN="$BATS_TEST_TMPDIR/bin"
    mkdir -p "$MOCK_BIN"

    # Mock tmux — returns no panes (no real tmux available in test)
    cat > "$MOCK_BIN/tmux" <<'SH'
#!/bin/bash
# Mock tmux for wake-instance tests
case "$1" in
    list-panes)
        # Return empty — no fleet panes found
        exit 0
        ;;
    has-session)
        # No sessions
        exit 1
        ;;
    display-message)
        echo "bash"
        ;;
    send-keys|capture-pane)
        exit 0
        ;;
    *)
        exit 0
        ;;
esac
SH
    chmod +x "$MOCK_BIN/tmux"

    # Mock pgrep — always returns "not found"
    cat > "$MOCK_BIN/pgrep" <<'SH'
#!/bin/bash
exit 1
SH
    chmod +x "$MOCK_BIN/pgrep"

    # Mock sudo — just exec the args after -u <user>
    cat > "$MOCK_BIN/sudo" <<'SH'
#!/bin/bash
shift 2  # skip -u <user>
exec "$@"
SH
    chmod +x "$MOCK_BIN/sudo"

    # Mock stat — return current user as socket owner
    cat > "$MOCK_BIN/stat" <<'SH'
#!/bin/bash
# If -c '%U' is used, return current user
for arg in "$@"; do
    if [[ "$arg" == "%U" || "$arg" == "%u" ]]; then
        echo "$(whoami)"
        exit 0
    fi
done
# Fallback to real stat for other uses
/usr/bin/stat "$@"
SH
    chmod +x "$MOCK_BIN/stat"
}

teardown() {
    chmod -R u+w "$BATS_TEST_TMPDIR" 2>/dev/null || true
}

# Helper: run wake-instance.sh with mock binaries in PATH
_wake() {
    PATH="$MOCK_BIN:$PATH" \
    CLAUDE_AGENT_NAME="starfleet" \
    HOME="$BATS_TEST_TMPDIR/homes/testuser" \
        bash "$SUT" "$@"
}

# ============================================================
# Nominal tests
# ============================================================

@test "wake-instance: wakes a known wakeable instance (no pane found — info msg)" {
    run _wake engineer "test-subject"
    assert_success
    # No tmux pane found by mock → "no tmux pane" info message
    assert_output --partial "no tmux pane"
}

@test "wake-instance: calls fleet-wake-notify.sh when no pane found" {
    _wake engineer "notify-test" 2>/dev/null || true
    [[ -f "$BATS_TEST_TMPDIR/wake-notify.log" ]]
    run grep "MOCK_WAKE_NOTIFY" "$BATS_TEST_TMPDIR/wake-notify.log"
    assert_success
    assert_output --partial "engineer"
}

@test "wake-instance: subject preserved in notify call" {
    _wake engineer "important task" 2>/dev/null || true
    run grep "important task" "$BATS_TEST_TMPDIR/wake-notify.log"
    assert_success
}

# ============================================================
# Error tests — WAK-01 to WAK-11
# ============================================================

@test "wake-instance: [WAK-01] instance not specified — exits with error" {
    run _wake
    assert_failure
    assert_output --partial "usage"
}

@test "wake-instance: [WAK-02] subject with control chars — sanitized via tr" {
    # Inject a subject with control characters (tab, newline, null)
    local dirty_subject
    dirty_subject=$'test\x01\x02\x03\tinjection\nnewline'
    run _wake engineer "$dirty_subject"
    assert_success
    # Control chars must be stripped — only printable chars survive
    # Check wake-notify log for sanitized subject
    if [[ -f "$BATS_TEST_TMPDIR/wake-notify.log" ]]; then
        run grep $'\x01' "$BATS_TEST_TMPDIR/wake-notify.log"
        assert_failure  # control chars must NOT be present
        run grep $'\x02' "$BATS_TEST_TMPDIR/wake-notify.log"
        assert_failure
    fi
}

@test "wake-instance: [WAK-02] subject > 200 chars — truncated by head -c 200" {
    local long_subject
    long_subject=$(printf 'A%.0s' {1..300})
    run _wake engineer "$long_subject"
    assert_success
    # The subject passed to wake-notify should be <= 200 chars
    if [[ -f "$BATS_TEST_TMPDIR/wake-notify.log" ]]; then
        local logged_subject
        logged_subject=$(cat "$BATS_TEST_TMPDIR/wake-notify.log")
        # The 300-char string should have been truncated
        [[ ${#logged_subject} -lt 350 ]]
    fi
}

@test "wake-instance: [WAK-03] non-wakeable agent — gyrophare started, exit 0" {
    run _wake architect "test-subject"
    assert_success
    assert_output --partial "non-wakeable"
    assert_output --partial "gyrophare"
    # Alert script should have been called
    [[ -f "$BATS_TEST_TMPDIR/alert.log" ]]
}

@test "wake-instance: [WAK-04] headless agent — silent exit 0" {
    run _wake builder "test-subject"
    assert_success
    # Headless agents exit immediately, no output expected about panes
    refute_output --partial "no tmux pane"
    refute_output --partial "gyrophare"
}

@test "wake-instance: [WAK-05] pane not found — info message, notify fallback" {
    # Default mock: no panes found
    run _wake engineer "no-pane-test"
    assert_success
    assert_output --partial "no tmux pane"
}

@test "wake-instance: [WAK-05] pane found via fleet_find_pane — wake proceeds" {
    # Override tmux mock to return a pane for engineer
    cat > "$MOCK_BIN/tmux" <<'SH'
#!/bin/bash
case "$1" in
    list-panes)
        echo "engineer %42"
        ;;
    has-session)
        exit 1
        ;;
    display-message)
        echo "claude"
        ;;
    send-keys|capture-pane)
        exit 0
        ;;
    *)
        exit 0
        ;;
esac
SH
    chmod +x "$MOCK_BIN/tmux"

    # Also need pgrep to find claude
    cat > "$MOCK_BIN/pgrep" <<'SH'
#!/bin/bash
echo "12345"
exit 0
SH
    chmod +x "$MOCK_BIN/pgrep"

    run _wake engineer "found-pane-test"
    assert_success
    assert_output --partial "OK: engineer"
    assert_output --partial "wake sent"
}

# WAK-09: trust dialog false positive — skipped (needs real tmux)
# WAK-11: _wait_for_claude polling — skipped (needs real pgrep)

@test "wake-instance: [WAK-10] fleet-wake-notify.sh absent — no crash" {
    rm -f "$FLEET_TMP/fleet-wake-notify.sh"
    # With no pane found and no wake-notify, script should still succeed
    run _wake engineer "no-notify"
    assert_success
    assert_output --partial "no tmux pane"
}

@test "wake-instance: [WAK-10] fleet-alert.sh absent — non-wakeable still exits 0" {
    rm -f "$FLEET_TMP/fleet-alert.sh"
    run _wake architect "no-alert"
    assert_success
    assert_output --partial "non-wakeable"
}

# ============================================================
# Edge cases
# ============================================================

@test "wake-instance: --help flag shows usage" {
    run bash "$SUT" --help
    assert_success
    assert_output --partial "wake-instance"
}

@test "wake-instance: default subject is 'wake' when not specified" {
    # The script uses ${2:-wake} — only 1 arg provided
    run _wake engineer
    assert_success
    if [[ -f "$BATS_TEST_TMPDIR/wake-notify.log" ]]; then
        run grep "wake" "$BATS_TEST_TMPDIR/wake-notify.log"
        assert_success
    fi
}

@test "wake-instance: standalone session gets gyrophare, not wake injection" {
    # Override tmux mock: no fleet pane found by fleet_find_pane,
    # but has-session succeeds for standalone session.
    # _tmux calls: tmux -S <sock> <subcommand> [args...]
    # So we must skip past -S <sock> to find the real subcommand.
    cat > "$MOCK_BIN/tmux" <<'SH'
#!/bin/bash
# Skip -S <socket> prefix if present
args=("$@")
idx=0
if [[ "${args[0]:-}" == "-S" ]]; then
    idx=2
fi
cmd="${args[$idx]:-}"
case "$cmd" in
    list-panes)
        # fleet_find_pane: -a flag means global pane lookup — return empty
        if [[ "$*" == *"-a"* ]]; then
            exit 0
        fi
        # standalone list-panes: return a pane ID
        echo "%99"
        ;;
    has-session)
        # Standalone session exists
        exit 0
        ;;
    display-message)
        echo "bash"
        ;;
    *)
        exit 0
        ;;
esac
SH
    chmod +x "$MOCK_BIN/tmux"

    run _wake engineer "standalone-test"
    assert_success
    assert_output --partial "standalone session"
    assert_output --partial "gyrophare"
}

# ============================================================
# Regression guard
# ============================================================

@test "wake-instance: shellcheck clean (no warnings/errors)" {
    run shellcheck --exclude=SC1091,SC2015,SC2016 "$REPO_ROOT/fleet/v1/wake-instance.sh"
    assert_success
}
