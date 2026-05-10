#!/usr/bin/env bats
# test_fleet_done.bats — Unit tests for fleet/fleet-done.sh
# Ring 2 kernel. Contract: appends timestamped DONE entry to handoff.

setup() {
    source "$BATS_TEST_DIRNAME/../helpers/test_helpers.bash"
    _setup

    # Copy SUT to sandbox with fleet-env shim
    SANDBOX="$BATS_TEST_TMPDIR/sandbox"
    mkdir -p "$SANDBOX"
    cp "$REPO_ROOT/fleet/fleet-done.sh" "$SANDBOX/"
    SUT="$SANDBOX/fleet-done.sh"

    cat > "$SANDBOX/fleet-env.sh" <<'ENVSHIM'
# shim — variables already exported by mock_fleet_env.bash
:
ENVSHIM

    HANDOFF="$FLEET_HANDOFFS/${FLEET_INSTANCE}-handoff.md"
    cat > "$HANDOFF" <<'HF'
## STATE
date: 2026-03-28 00:00
action: idle
status: done

## ACTIONS
[ ] Task one

## DONE
### 2026-03-27 — Previous entry
Previous work done.
HF
}

teardown() { _teardown; }

# ============================================================
# Nominal
# ============================================================

@test "fleet-done: appends DONE entry with title" {
    run bash "$SUT" "Session complete"
    assert_success
    run grep "Session complete" "$HANDOFF"
    assert_success
}

@test "fleet-done: entry appears after ## DONE anchor (before old entries)" {
    run bash "$SUT" "New entry"
    assert_success
    local line_new line_prev
    line_new=$(grep -n "New entry" "$HANDOFF" | head -1 | cut -d: -f1)
    line_prev=$(grep -n "Previous entry" "$HANDOFF" | head -1 | cut -d: -f1)
    [[ "$line_new" -lt "$line_prev" ]]
}

@test "fleet-done: entry has ### timestamp header" {
    run bash "$SUT" "Test title"
    assert_success
    run grep -E "^### [0-9]{4}-[0-9]{2}-[0-9]{2} [0-9]{2}:[0-9]{2} — Test title" "$HANDOFF"
    assert_success
}

@test "fleet-done: body text appended after title" {
    run bash "$SUT" "Title here" "Body text follows"
    assert_success
    run grep "Body text follows" "$HANDOFF"
    assert_success
}

@test "fleet-done: no body — only title line" {
    run bash "$SUT" "Title only"
    assert_success
    assert_output --partial "DONE: Title only"
}

@test "fleet-done: preserves existing handoff content" {
    run bash "$SUT" "New stuff"
    assert_success
    run grep "^## STATE" "$HANDOFF"
    assert_success
    run grep "Task one" "$HANDOFF"
    assert_success
    run grep "Previous work done" "$HANDOFF"
    assert_success
}

# ============================================================
# Error handling
# ============================================================

@test "fleet-done: --help exits 0" {
    run bash "$SUT" --help
    assert_success
    assert_output --partial "NAME"
}

@test "fleet-done: no arguments — exits 1" {
    run bash "$SUT"
    assert_failure
}

@test "fleet-done: handoff missing — exits 1" {
    rm -f "$HANDOFF"
    run bash "$SUT" "Title"
    assert_failure
    assert_output --partial "introuvable"
}

@test "fleet-done: ## DONE anchor missing — exits 1" {
    echo "## STATE" > "$HANDOFF"
    run bash "$SUT" "Title"
    assert_failure
    assert_output --partial "DONE"
    assert_output --partial "absent"
}

# ============================================================
# Shellcheck
# ============================================================

@test "fleet-done: shellcheck clean" {
    if ! command -v shellcheck &>/dev/null; then skip "shellcheck not installed"; fi
    run shellcheck -S warning "$REPO_ROOT/fleet/fleet-done.sh"
    assert_success
}
