#!/usr/bin/env bats
# test_fleet_inbox_read.bats — Unit tests for fleet/fleet-inbox-read.sh
#
# Reference: docs/qualification/plans/phase2-failure-modes.md (INB-01 to INB-11)
# Vague: 2.2
#
# fleet-inbox-read.sh sources fleet-env.sh from its own BASH_SOURCE dirname.
# Strategy: copy SUT + fleet-env.sh to tmpdir, place a custom fleet.yaml
# there with spool paths pointing to tmpdir. Real yq is used.

# ============================================================
# Setup / Teardown
# ============================================================

setup() {
    # Load bats libs WITHOUT mocks (real yq needed by fleet-env.sh)
    HELPERS_DIR="$(cd "$(dirname "$BATS_TEST_DIRNAME")/helpers" && pwd)"
    REPO_ROOT="$(cd "$HELPERS_DIR/../.." && pwd)"
    load "$REPO_ROOT/tests/.bats/bats-support/load.bash"
    load "$REPO_ROOT/tests/.bats/bats-assert/load.bash"
    load "$REPO_ROOT/tests/.bats/bats-file/load.bash"

    # Verify real yq is available
    command -v yq &>/dev/null || skip "yq not installed"

    # --- Create test fleet dir with SUT + fleet-env.sh ---
    FLEET_TMP="$BATS_TEST_TMPDIR/fleet"
    mkdir -p "$FLEET_TMP"
    cp "$REPO_ROOT/fleet/fleet-inbox-read.sh" "$FLEET_TMP/"
    cp "$REPO_ROOT/fleet/fleet-env.sh"        "$FLEET_TMP/"

    SUT="$FLEET_TMP/fleet-inbox-read.sh"

    # --- Create spool dirs ---
    SPOOL="$BATS_TEST_TMPDIR/spool"
    mkdir -p "$SPOOL/inbox/dev"/{.processing,.consumed}
    mkdir -p "$SPOOL/inbox/starfleet"/{.processing,.consumed}
    mkdir -p "$SPOOL/inbox/engineer"/{.processing,.consumed}
    mkdir -p "$SPOOL/outbox"
    mkdir -p "$SPOOL/pending-wakes"

    # --- Custom fleet.yaml with tmpdir spool paths ---
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
  - role: engineer
    tier: 1
    scope: sas-user
    stateless: false
  - role: dev
    tier: 2
    scope: code
    stateless: false
YAML

    # --- No-op fleet-send.sh for auto-ACK tests ---
    cat > "$FLEET_TMP/fleet-send.sh" <<'SH'
#!/bin/bash
# no-op fleet-send for testing — log call
echo "MOCK_SEND: $*" >> "${BATS_TEST_TMPDIR:-/tmp}/fleet-send.log"
echo "mock-msg.md"
exit 0
SH
    chmod +x "$FLEET_TMP/fleet-send.sh"

    # --- No-op fleet-alert.sh ---
    cat > "$FLEET_TMP/fleet-alert.sh" <<'SH'
#!/bin/bash
exit 0
SH
    chmod +x "$FLEET_TMP/fleet-alert.sh"

    # --- Create required dirs ---
    mkdir -p "$BATS_TEST_TMPDIR"/{lcars/fleet,homes,handoffs,fleet-state,ready-room}
    mkdir -p "$BATS_TEST_TMPDIR/homes/testuser/.claude"
}

teardown() {
    chmod -R u+w "$BATS_TEST_TMPDIR" 2>/dev/null || true
}

# Helper: run fleet-inbox-read.sh
_read_inbox() {
    CLAUDE_AGENT_NAME="${READ_INSTANCE:-dev}" \
    HOME="$BATS_TEST_TMPDIR/homes/testuser" \
        bash "$SUT" "$@"
}

# Helper: place a message in an instance inbox
_place_message() {
    local instance="$1" filename="$2" content="$3"
    echo "$content" > "$SPOOL/inbox/$instance/$filename"
}

# ============================================================
# Nominal tests
# ============================================================

@test "fleet-inbox-read: reads single message from inbox" {
    _place_message dev "20260325-120000-engineer-test-task.md" "---
from: engineer
to: dev
subject: test-task
type: task
priority: normal
ref:
date: 2026-03-25T12:00:00+01:00
---
This is a test task body."

    run _read_inbox dev
    assert_success
    assert_output --partial "INBOX (1 messages)"
    assert_output --partial "test task body"
    assert_output --partial "END INBOX"
}

@test "fleet-inbox-read: message moved to .consumed after reading" {
    _place_message dev "20260325-120000-engineer-consumed.md" "---
from: engineer
to: dev
subject: consumed-test
type: task
priority: normal
ref:
date: 2026-03-25T12:00:00+01:00
---
Body."

    _read_inbox dev >/dev/null 2>&1
    # Original message gone
    [[ ! -f "$SPOOL/inbox/dev/20260325-120000-engineer-consumed.md" ]]
    # Moved to .consumed
    [[ -f "$SPOOL/inbox/dev/.consumed/20260325-120000-engineer-consumed.md" ]]
}

@test "fleet-inbox-read: ACK file created after consumption" {
    _place_message dev "20260325-120000-engineer-ack-test.md" "---
from: engineer
to: dev
subject: ack-test
type: task
priority: normal
ref:
date: 2026-03-25T12:00:00+01:00
---
Body."

    _read_inbox dev >/dev/null 2>&1
    [[ -f "$SPOOL/inbox/dev/.consumed/20260325-120000-engineer-ack-test.ack" ]]
}

@test "fleet-inbox-read: multiple messages processed in order" {
    _place_message dev "20260325-100000-engineer-first.md" "---
from: engineer
to: dev
subject: first
type: task
priority: normal
ref:
date: 2026-03-25T10:00:00+01:00
---
First message."

    _place_message dev "20260325-110000-engineer-second.md" "---
from: engineer
to: dev
subject: second
type: task
priority: normal
ref:
date: 2026-03-25T11:00:00+01:00
---
Second message."

    run _read_inbox dev
    assert_success
    assert_output --partial "INBOX (2 messages)"
    assert_output --partial "First message"
    assert_output --partial "Second message"
}

@test "fleet-inbox-read: PING auto-ACK triggers fleet-send" {
    _place_message starfleet "20260325-120000-engineer-ping.md" "---
from: engineer
to: starfleet
subject: PING
type: ping
priority: normal
ref:
date: 2026-03-25T12:00:00+01:00
---"

    READ_INSTANCE=starfleet _read_inbox starfleet >/dev/null 2>&1
    # fleet-send.sh mock should have been called
    [[ -f "$BATS_TEST_TMPDIR/fleet-send.log" ]]
    run grep "MOCK_SEND" "$BATS_TEST_TMPDIR/fleet-send.log"
    assert_success
    assert_output --partial "engineer"
    assert_output --partial "ACK"
}

@test "fleet-inbox-read: displays type and priority in header" {
    _place_message dev "20260325-120000-engineer-prio.md" "---
from: engineer
to: dev
subject: urgent-task
type: alert
priority: high
ref:
date: 2026-03-25T12:00:00+01:00
---
Urgent body."

    run _read_inbox dev
    assert_success
    assert_output --partial "type:alert"
    assert_output --partial "priority:high"
}

# ============================================================
# Error tests — INB-01 to INB-11
# ============================================================

@test "fleet-inbox-read: [INB-01] instance not specified — exits 0 silently" {
    run _read_inbox ""
    assert_success
    assert_output --partial "no instance specified"
}

@test "fleet-inbox-read: [INB-01] no arguments — exits 0 silently" {
    run bash -c 'HOME="'"$BATS_TEST_TMPDIR/homes/testuser"'" bash "'"$SUT"'"'
    assert_success
    assert_output --partial "no instance specified"
}

@test "fleet-inbox-read: [INB-02] inbox dir nonexistent — exits 0 silently" {
    run _read_inbox nonexistent-agent
    assert_success
    # No output expected — script exits immediately
    refute_output --partial "INBOX"
}

@test "fleet-inbox-read: [INB-03] inbox empty — exits 0 silently" {
    # dev inbox exists but is empty
    run _read_inbox dev
    assert_success
    refute_output --partial "INBOX"
}

@test "fleet-inbox-read: [INB-04] message without YAML frontmatter — still displayed" {
    _place_message dev "20260325-120000-engineer-noyaml.md" "This message has no YAML frontmatter.
It should be handled gracefully."

    run _read_inbox dev
    assert_success
    assert_output --partial "This message has no YAML frontmatter"
    assert_output --partial "END INBOX"
}

@test "fleet-inbox-read: [INB-05] truncated/empty message file — handled gracefully" {
    # Create an empty .md file
    touch "$SPOOL/inbox/dev/20260325-120000-engineer-empty.md"

    run _read_inbox dev
    assert_success
    assert_output --partial "INBOX (1 messages)"
    assert_output --partial "END INBOX"
}

# INB-06: flock fails — skipped (hard to test reliably)

@test "fleet-inbox-read: [INB-07] message > 200 lines truncated" {
    # Generate a message with 250 lines
    {
        echo "---"
        echo "from: engineer"
        echo "to: dev"
        echo "subject: long-message"
        echo "type: task"
        echo "priority: normal"
        echo "ref:"
        echo "date: 2026-03-25T12:00:00+01:00"
        echo "---"
        for i in $(seq 1 242); do
            echo "Line $i of the long message body."
        done
    } > "$SPOOL/inbox/dev/20260325-120000-engineer-long.md"

    run _read_inbox dev
    assert_success
    assert_output --partial "truncated"
    # Verify the total line count is reported
    assert_output --partial "251 lines total"
}

# INB-08: race condition — skipped

@test "fleet-inbox-read: [INB-09] auto-ACK PING when fleet-send absent — no crash" {
    rm -f "$FLEET_TMP/fleet-send.sh"
    _place_message starfleet "20260325-120000-engineer-ping.md" "---
from: engineer
to: starfleet
subject: PING
type: ping
priority: normal
ref:
date: 2026-03-25T12:00:00+01:00
---"

    run bash -c 'READ_INSTANCE=starfleet CLAUDE_AGENT_NAME=starfleet HOME="'"$BATS_TEST_TMPDIR/homes/testuser"'" bash "'"$SUT"'" starfleet'
    assert_success
    assert_output --partial "END INBOX"
}

@test "fleet-inbox-read: [INB-10] fleet-alert.sh absent — no crash at end" {
    rm -f "$FLEET_TMP/fleet-alert.sh"
    _place_message dev "20260325-120000-engineer-noalert.md" "---
from: engineer
to: dev
subject: no-alert
type: task
priority: normal
ref:
date: 2026-03-25T12:00:00+01:00
---
Body."

    run _read_inbox dev
    assert_success
    assert_output --partial "END INBOX"
}

@test "fleet-inbox-read: [INB-11] permission denied on .processing/ — message skipped" {
    [[ "$(id -u)" == "0" ]] && skip "running as root — permission test meaningless"

    _place_message dev "20260325-120000-engineer-perm.md" "---
from: engineer
to: dev
subject: perm-test
type: task
priority: normal
ref:
date: 2026-03-25T12:00:00+01:00
---
Body."

    # Make .processing/ read-only — flock/mv will fail
    chmod 555 "$SPOOL/inbox/dev/.processing"

    run _read_inbox dev
    # Script should not crash (set -uo pipefail but no -e)
    assert_success
    assert_output --partial "INBOX (1 messages)"
}

# ============================================================
# Edge cases
# ============================================================

@test "fleet-inbox-read: hidden files (dotfiles) in inbox are ignored" {
    _place_message dev ".hidden-message.md" "---
from: engineer
to: dev
subject: hidden
type: task
priority: normal
ref:
date: 2026-03-25T12:00:00+01:00
---
Hidden body."

    run _read_inbox dev
    assert_success
    # Should report 0 messages (hidden files excluded by find -not -name '.*')
    refute_output --partial "INBOX"
}

@test "fleet-inbox-read: non-.md files in inbox are ignored" {
    echo "not a message" > "$SPOOL/inbox/dev/random.txt"
    run _read_inbox dev
    assert_success
    refute_output --partial "INBOX"
}

# ============================================================
# Regression guard
# ============================================================

@test "fleet-inbox-read: shellcheck clean (no warnings/errors)" {
    run shellcheck --exclude=SC1090,SC2015,SC2016 "$REPO_ROOT/fleet/fleet-inbox-read.sh"
    assert_success
}
