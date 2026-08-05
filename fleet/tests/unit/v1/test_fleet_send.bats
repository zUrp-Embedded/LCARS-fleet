#!/usr/bin/env bats
# test_fleet_send.bats — Unit tests for fleet/fleet-send.sh
#
# Reference: docs/qualification/plans/phase2-failure-modes.md (SND-01 to SND-11)
# Vague: 2.2
#
# fleet-send.sh sources fleet-env.sh from its own BASH_SOURCE dirname.
# Strategy: copy SUT + fleet-env.sh to tmpdir, place a custom fleet.yaml
# there with spool paths pointing to tmpdir. Real yq is used.

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
    cp "$REPO_ROOT/fleet/v1/fleet-send.sh" "$FLEET_TMP/"
    cp "$REPO_ROOT/fleet/v1/fleet-env.sh"  "$FLEET_TMP/"

    SUT="$FLEET_TMP/fleet-send.sh"

    # --- Create spool dirs ---
    SPOOL="$BATS_TEST_TMPDIR/spool"
    mkdir -p "$SPOOL/inbox"/{starfleet,architect,engineer,dev,qualifier,reviewer,documenter,researcher,builder,deployer,compliance,quality}
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
  - role: architect
    tier: 0
    scope: boundary-user
    stateless: false
    wakeable: false
  - role: engineer
    tier: 1
    scope: sas-user
    stateless: false
  - role: dev
    tier: 2
    scope: code
    stateless: false
  - role: qualifier
    tier: 2
    scope: test
    stateless: true
  - role: reviewer
    tier: 2
    scope: analysis
    stateless: true
  - role: documenter
    tier: 2
    scope: docs
    stateless: true
  - role: researcher
    tier: 2
    scope: research
    stateless: true
  - role: builder
    tier: 2
    scope: build
    stateless: true
  - role: deployer
    tier: 2
    scope: deploy
    stateless: true
  - role: compliance
    tier: 2
    scope: compliance
    stateless: true
  - role: quality
    tier: 2
    scope: quality
    stateless: true
YAML

    # --- Create dummy wake-instance.sh (no-op) ---
    cat > "$FLEET_TMP/wake-instance.sh" <<'SH'
#!/bin/bash
# no-op wake for testing
exit 0
SH
    chmod +x "$FLEET_TMP/wake-instance.sh"

    # --- Create required dirs ---
    mkdir -p "$BATS_TEST_TMPDIR"/{lcars/fleet,homes,handoffs,fleet-state,ready-room}
    mkdir -p "$BATS_TEST_TMPDIR/homes/testuser/.claude"
}

teardown() {
    chmod -R u+w "$BATS_TEST_TMPDIR" 2>/dev/null || true
}

# Helper: run fleet-send.sh (SOURCE is now whoami, not injected)
_send() {
    HOME="$BATS_TEST_TMPDIR/homes/testuser" \
        bash "$SUT" "$@"
}

# ============================================================
# Nominal tests
# ============================================================

@test "fleet-send: sends message to valid destination" {
    run _send engineer "hello-world"
    assert_success
    assert_output --partial "OK:"
    # Message file should exist in inbox
    local count
    count=$(find "$SPOOL/inbox/engineer" -name '*.md' | wc -l)
    [[ "$count" -eq 1 ]]
}

@test "fleet-send: message contains YAML envelope" {
    _send engineer "test-envelope" 2>/dev/null
    local msg
    msg=$(find "$SPOOL/inbox/engineer" -name '*.md' | head -1)
    run grep '^from: starfleet' "$msg"
    assert_success
    run grep '^to: engineer' "$msg"
    assert_success
    run grep '^subject: test-envelope' "$msg"
    assert_success
}

@test "fleet-send: content file included in message body" {
    local content_file="$BATS_TEST_TMPDIR/body.txt"
    echo "This is the body content." > "$content_file"
    _send engineer "with-body" "$content_file" 2>/dev/null
    local msg
    msg=$(find "$SPOOL/inbox/engineer" -name '*.md' | head -1)
    run grep 'This is the body content.' "$msg"
    assert_success
}

@test "fleet-send: starfleet can send to any role" {
    for dest in engineer dev qualifier reviewer; do
        run _send "$dest" "broadcast"
        assert_success
    done
}

@test "fleet-send: engineer can send to tier-2 agents" {
    SEND_SOURCE=engineer run _send dev "task-for-dev"
    assert_success
}

@test "fleet-send: --type and --priority flags set envelope fields" {
    _send --type alert --priority high engineer "urgent-test" 2>/dev/null
    local msg
    msg=$(find "$SPOOL/inbox/engineer" -name '*.md' | head -1)
    run grep '^type: alert' "$msg"
    assert_success
    run grep '^priority: high' "$msg"
    assert_success
}

@test "fleet-send: --ref flag sets ref field in envelope" {
    _send --ref "TASK-42" engineer "ref-test" 2>/dev/null
    local msg
    msg=$(find "$SPOOL/inbox/engineer" -name '*.md' | head -1)
    run grep '^ref: TASK-42' "$msg"
    assert_success
}

@test "fleet-send: filename contains sanitized subject" {
    _send engineer "Hello World Test" 2>/dev/null
    local msg
    msg=$(find "$SPOOL/inbox/engineer" -name '*.md' | head -1)
    run basename "$msg"
    assert_output --partial "hello-world-test"
}

# ============================================================
# Error tests — SND-01 to SND-11
# ============================================================

@test "fleet-send: [SND-01] destination inbox nonexistent — exits 1" {
    run _send nonexistent-agent "test-msg"
    assert_failure
    assert_output --partial "inbox dir"
    assert_output --partial "does not exist"
}

@test "fleet-send: [SND-02] source not authorized to send to dest" {
    # dev can only send to engineer or starfleet
    SEND_SOURCE=dev run _send qualifier "unauthorized"
    assert_failure
    assert_output --partial "not authorized"
}

@test "fleet-send: [SND-02] dev cannot send to architect" {
    SEND_SOURCE=dev run _send architect "forbidden"
    assert_failure
    assert_output --partial "not authorized"
}

@test "fleet-send: [SND-02] compliance can only send to starfleet or engineer" {
    SEND_SOURCE=compliance run _send dev "forbidden"
    assert_failure
    assert_output --partial "not authorized"
}

@test "fleet-send: [SND-03] architect forbidden outbound IPC" {
    SEND_SOURCE=architect run _send engineer "forbidden"
    assert_failure
    assert_output --partial "architect"
    assert_output --partial "no outbound IPC"
}

@test "fleet-send: [SND-04] unknown source — IPC denied" {
    SEND_SOURCE=unknown_agent run _send engineer "test"
    assert_failure
    assert_output --partial "unknown source"
}

@test "fleet-send: [SND-05] subject with special chars sanitized in filename" {
    _send engineer 'Test/../../etc/passwd' 2>/dev/null
    local msg
    msg=$(find "$SPOOL/inbox/engineer" -name '*.md' | head -1)
    local bname
    bname=$(basename "$msg")
    # Must not contain slashes or dots (path traversal)
    [[ "$bname" != *"/"* ]]
    [[ "$bname" != *".."* ]]
}

@test "fleet-send: [SND-05] subject with shell metacharacters sanitized" {
    _send engineer 'test;rm -rf /' 2>/dev/null
    local msg
    msg=$(find "$SPOOL/inbox/engineer" -name '*.md' | head -1)
    local bname
    bname=$(basename "$msg")
    # Semicolons and spaces must be stripped
    [[ "$bname" != *";"* ]]
}

@test "fleet-send: [SND-06] content file specified but nonexistent — treated as inline" {
    run _send engineer "test-inline" "/nonexistent/path/to/file.md"
    assert_success
    assert_output --partial "WARN"
    # Message should still be created with inline content
    local count
    count=$(find "$SPOOL/inbox/engineer" -name '*.md' | wc -l)
    [[ "$count" -eq 1 ]]
}

@test "fleet-send: [SND-07] atomic write pattern (tmp+mv) — no partial files" {
    _send engineer "atomic-test" 2>/dev/null
    # No .tmp files should remain
    local tmp_count
    tmp_count=$(find "$SPOOL/inbox/engineer" -name '*.tmp' | wc -l)
    [[ "$tmp_count" -eq 0 ]]
    # Final .md file should exist
    local md_count
    md_count=$(find "$SPOOL/inbox/engineer" -name '*.md' | wc -l)
    [[ "$md_count" -eq 1 ]]
}

# SND-08: concurrent sends — skipped (hard to unit test reliably)

@test "fleet-send: [SND-09] wake-instance.sh absent — send still succeeds" {
    rm -f "$FLEET_TMP/wake-instance.sh"
    run _send engineer "no-wake"
    assert_success
    assert_output --partial "OK:"
}

@test "fleet-send: [SND-10] stdin empty, no content file — envelope-only message" {
    run bash -c 'CLAUDE_AGENT_NAME=starfleet HOME="'"$BATS_TEST_TMPDIR/homes/testuser"'" bash "'"$SUT"'" engineer "empty-msg" < /dev/null'
    assert_success
    local msg
    msg=$(find "$SPOOL/inbox/engineer" -name '*.md' | head -1)
    # Message should contain only the YAML envelope (--- delimiters + fields)
    run grep '^---$' "$msg"
    assert_success
}

@test "fleet-send: [SND-11] flag without value — exits with error" {
    run _send --type
    assert_failure
}

@test "fleet-send: [SND-11] unknown flag — exits with error" {
    run _send --bogus-flag engineer "test"
    assert_failure
    assert_output --partial "unknown flag"
}

# ============================================================
# IPC matrix coverage
# ============================================================

@test "fleet-send: engineer can send to compliance" {
    SEND_SOURCE=engineer run _send compliance "compliance-task"
    assert_success
}

@test "fleet-send: qualifier can send to engineer" {
    SEND_SOURCE=qualifier run _send engineer "results"
    assert_success
}

@test "fleet-send: qualifier can send to starfleet" {
    SEND_SOURCE=qualifier run _send starfleet "escalation"
    assert_success
}

@test "fleet-send: qualifier cannot send to dev" {
    SEND_SOURCE=qualifier run _send dev "forbidden"
    assert_failure
    assert_output --partial "not authorized"
}

# ============================================================
# Regression guard
# ============================================================

@test "fleet-send: shellcheck clean (no warnings/errors)" {
    run shellcheck --exclude=SC1091,SC2005,SC2016 "$REPO_ROOT/fleet/v1/fleet-send.sh"
    assert_success
}
