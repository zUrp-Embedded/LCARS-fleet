#!/usr/bin/env bats
# test_fleet_action_done.bats — Unit tests for fleet/fleet-action-done.sh
# Ring 2 kernel. Contract: marks first matching [ ] as [x] in handoff.

setup() {
    source "$BATS_TEST_DIRNAME/../helpers/test_helpers.bash"
    _setup

    SANDBOX="$BATS_TEST_TMPDIR/sandbox"
    mkdir -p "$SANDBOX"
    cp "$REPO_ROOT/fleet/fleet-action-done.sh" "$SANDBOX/"
    SUT="$SANDBOX/fleet-action-done.sh"

    cat > "$SANDBOX/fleet-env.sh" <<'ENVSHIM'
:
ENVSHIM

    HANDOFF="$FLEET_HANDOFFS/${FLEET_INSTANCE}-handoff.md"
    cat > "$HANDOFF" <<'HF'
## STATE
date: 2026-03-28 00:00

## ACTIONS
[ ] First task
[ ] Second task
[ ] Ring 0 FREEZE

## DONE
HF
}

teardown() { _teardown; }

# ============================================================
# Nominal — no fragment
# ============================================================

@test "fleet-action-done: marks first [ ] as [x]" {
    run bash "$SUT"
    assert_success
    run grep "^\[x\] First task" "$HANDOFF"
    assert_success
    run grep "^\[ \] Second task" "$HANDOFF"
    assert_success
}

@test "fleet-action-done: output confirms action" {
    run bash "$SUT"
    assert_success
    assert_output --partial "ACTION [x]"
}

# ============================================================
# Nominal — with fragment
# ============================================================

@test "fleet-action-done: fragment matches specific task" {
    run bash "$SUT" "Ring 0 FREEZE"
    assert_success
    run grep "^\[x\] Ring 0 FREEZE" "$HANDOFF"
    assert_success
    run grep "^\[ \] First task" "$HANDOFF"
    assert_success
}

@test "fleet-action-done: only first matching [ ] is marked" {
    echo "[ ] Ring 0 FREEZE again" >> "$HANDOFF"
    run bash "$SUT" "Ring 0 FREEZE"
    assert_success
    local count
    count=$(grep -c "^\[x\].*Ring 0 FREEZE" "$HANDOFF")
    [[ "$count" -eq 1 ]]
}

# ============================================================
# Edge cases
# ============================================================

@test "fleet-action-done: no [ ] actions — exits 0 with warning" {
    cat > "$HANDOFF" <<'HF'
## ACTIONS
[x] Already done

## DONE
HF
    run bash "$SUT"
    assert_success
    assert_output --partial "WARNING"
}

@test "fleet-action-done: fragment not found — exits 1" {
    run bash "$SUT" "nonexistent task"
    assert_failure
    assert_output --partial "WARNING"
}

@test "fleet-action-done: sequential calls mark sequentially" {
    bash "$SUT" > /dev/null 2>&1  # marks First
    run bash "$SUT"  # marks Second
    assert_success
    run grep "^\[x\] Second task" "$HANDOFF"
    assert_success
}

@test "fleet-action-done: preserves rest of handoff" {
    run bash "$SUT"
    assert_success
    run grep "^## STATE" "$HANDOFF"
    assert_success
    run grep "^## DONE" "$HANDOFF"
    assert_success
}

# ============================================================
# Error handling
# ============================================================

@test "fleet-action-done: --help exits 0" {
    run bash "$SUT" --help
    assert_success
    assert_output --partial "NAME"
}

@test "fleet-action-done: handoff missing — exits 1" {
    rm -f "$HANDOFF"
    run bash "$SUT"
    assert_failure
    assert_output --partial "introuvable"
}

# ============================================================
# Shellcheck
# ============================================================

@test "fleet-action-done: shellcheck clean" {
    if ! command -v shellcheck &>/dev/null; then skip "shellcheck not installed"; fi
    run shellcheck -S warning "$REPO_ROOT/fleet/fleet-action-done.sh"
    assert_success
}
