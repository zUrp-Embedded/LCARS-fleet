#!/usr/bin/env bats
# test_fleet_shutdown_clean.bats — Unit tests for fleet/fleet-shutdown-clean.sh
#
# fleet-shutdown-clean.sh moves pending ACTIONS to DONE [interrupted] on shutdown.

# ============================================================
# Setup / Teardown
# ============================================================

setup() {
    source "$BATS_TEST_DIRNAME/../helpers/test_helpers.bash"
    _setup

    # Copy SUT to sandbox with fleet-env shim
    SANDBOX="$BATS_TEST_TMPDIR/sandbox"
    mkdir -p "$SANDBOX"
    cp "$REPO_ROOT/fleet/fleet-shutdown-clean.sh" "$SANDBOX/"
    SUT="$SANDBOX/fleet-shutdown-clean.sh"

    # Mock handoff directory
    MOCK_HANDOFFS="$BATS_TEST_TMPDIR/handoffs"
    mkdir -p "$MOCK_HANDOFFS"

    cat > "$SANDBOX/fleet-env.sh" <<ENVSHIM
export FLEET_HANDOFFS="$MOCK_HANDOFFS"
fleet_roles() {
    echo "agent1"
    echo "agent2"
}
export -f fleet_roles
ENVSHIM
}

teardown() {
    _teardown
}

# Helper: create a handoff with actions
_create_handoff_with_actions() {
    local role="$1"
    cat > "$MOCK_HANDOFFS/${role}-handoff.md" <<'HO'
# Handoff

## STATE
date: 2026-03-28 08:00
action: coding
status: in-progress

## ACTIONS
[ ] finish feature X
[ ] write tests

## DONE
### 2026-03-27 — previous session
[x] setup project
HO
}

# Helper: create a handoff without actions
_create_handoff_empty_actions() {
    local role="$1"
    cat > "$MOCK_HANDOFFS/${role}-handoff.md" <<'HO'
# Handoff

## STATE
date: 2026-03-28 08:00
action: idle
status: done

## ACTIONS

## DONE
### 2026-03-27 — previous session
[x] setup project
HO
}

# ============================================================
# Nominal tests
# ============================================================

@test "shutdown-clean: --help displays man page" {
    run bash "$SUT" --help
    assert_success
    assert_output --partial "NAME"
    assert_output --partial "fleet-shutdown-clean.sh"
}

@test "shutdown-clean: moves ACTIONS to DONE [interrupted]" {
    _create_handoff_with_actions "agent1"
    _create_handoff_empty_actions "agent2"
    run bash "$SUT"
    assert_success
    assert_output --partial "agent1-handoff.md"
    assert_output --partial "ACTIONS moved to DONE"
    # agent1 handoff should have [interrupted] in DONE
    run cat "$MOCK_HANDOFFS/agent1-handoff.md"
    assert_output --partial "[interrupted]"
    assert_output --partial "finish feature X"
}

@test "shutdown-clean: ACTIONS section is emptied after move" {
    _create_handoff_with_actions "agent1"
    run bash "$SUT"
    assert_success
    # Check that ACTIONS section is now empty (between ## ACTIONS and ## DONE)
    local actions
    actions=$(awk '/^## ACTIONS$/{p=1;next} /^## /{p=0} p' "$MOCK_HANDOFFS/agent1-handoff.md" | grep -v '^[[:space:]]*$' || true)
    [[ -z "$actions" ]]
}

@test "shutdown-clean: empty ACTIONS — no changes" {
    _create_handoff_empty_actions "agent1"
    _create_handoff_empty_actions "agent2"
    run bash "$SUT"
    assert_success
    refute_output --partial "ACTIONS moved"
}

@test "shutdown-clean: preserves STATE section" {
    _create_handoff_with_actions "agent1"
    run bash "$SUT"
    assert_success
    run cat "$MOCK_HANDOFFS/agent1-handoff.md"
    assert_output --partial "## STATE"
    assert_output --partial "action: coding"
}

@test "shutdown-clean: preserves existing DONE entries" {
    _create_handoff_with_actions "agent1"
    run bash "$SUT"
    assert_success
    run cat "$MOCK_HANDOFFS/agent1-handoff.md"
    assert_output --partial "setup project"
}

@test "shutdown-clean: no handoff files — silent exit" {
    run bash "$SUT"
    assert_success
}

# ============================================================
# Regression guard
# ============================================================

@test "shutdown-clean: shellcheck clean" {
    run shellcheck --exclude=SC1091,SC1090,SC2016 "$REPO_ROOT/fleet/fleet-shutdown-clean.sh"
    assert_success
}
