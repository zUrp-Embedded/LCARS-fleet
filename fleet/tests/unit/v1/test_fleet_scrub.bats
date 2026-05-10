#!/usr/bin/env bats
# test_fleet_scrub.bats — Unit tests for fleet/fleet-scrub.sh
# Ring 3 kernel. Tests init command (no dispatch dependency).
# scratchpad/backlog commands require fleet-dispatch → integration tests.

setup() {
    source "$BATS_TEST_DIRNAME/../helpers/test_helpers.bash"
    _setup
    SUT="$REPO_ROOT/fleet/fleet-scrub.sh"

    PROJECT="$BATS_TEST_TMPDIR/project"
    mkdir -p "$PROJECT/work"/{TODO,doing,done}

    cd "$PROJECT"
}

teardown() {
    cd /
    _teardown
}

# ============================================================
# init
# ============================================================

@test "fleet-scrub init: creates index.md" {
    run bash "$SUT" init
    assert_success
    assert [ -f "$PROJECT/work/index.md" ]
}

@test "fleet-scrub init: index contains header" {
    run bash "$SUT" init
    assert_success
    run grep "# Work Index" "$PROJECT/work/index.md"
    assert_success
}

@test "fleet-scrub init: index contains plans table" {
    # Create a plan first
    echo "# test-plan" > "$PROJECT/work/TODO/test-plan.md"
    echo "## Objectif" >> "$PROJECT/work/TODO/test-plan.md"
    echo "Test the index." >> "$PROJECT/work/TODO/test-plan.md"
    run bash "$SUT" init
    assert_success
    run grep "test-plan" "$PROJECT/work/index.md"
    assert_success
}

@test "fleet-scrub init: index reflects TODO/doing/done states" {
    echo "# todo-plan" > "$PROJECT/work/TODO/todo-plan.md"
    echo "# doing-plan" > "$PROJECT/work/doing/doing-plan.md"
    echo "# done-plan" > "$PROJECT/work/done/done-plan.md"
    run bash "$SUT" init
    assert_success
    local idx="$PROJECT/work/index.md"
    run grep "todo-plan" "$idx"
    assert_success
    run grep "doing-plan" "$idx"
    assert_success
    run grep "done-plan" "$idx"
    assert_success
}

@test "fleet-scrub init: scratchpad/backlog not auto-created by init" {
    # init creates index.md, not scratchpad/backlog (those are created by other commands)
    run bash "$SUT" init
    assert_success
    # Just verify init doesn't crash without them
}

@test "fleet-scrub init: overwrites existing index with warning" {
    echo "old content" > "$PROJECT/work/index.md"
    run bash "$SUT" init
    assert_success
    assert_output --partial "WARN"
    # New content, not old
    run grep "# Work Index" "$PROJECT/work/index.md"
    assert_success
    run grep "old content" "$PROJECT/work/index.md"
    assert_failure
}

@test "fleet-scrub init: empty work/ — creates index with bootstrap entry" {
    run bash "$SUT" init
    assert_success
    run grep "bootstrap" "$PROJECT/work/index.md"
    assert_success
}

# ============================================================
# Error handling
# ============================================================

@test "fleet-scrub: --help exits 0" {
    run bash "$SUT" --help
    assert_success
    assert_output --partial "NAME"
}

@test "fleet-scrub: no command — exits 1" {
    run bash "$SUT"
    assert_failure
}

@test "fleet-scrub: unknown command — exits 1" {
    run bash "$SUT" bogus
    assert_failure
}

# ============================================================
# scratchpad/backlog — smoke tests (dispatch not available)
# ============================================================

@test "fleet-scrub scratchpad: empty scratchpad — exits with message" {
    touch "$PROJECT/work/scratchpad.md"
    run bash "$SUT" scratchpad
    assert_output --partial "empty"
}

@test "fleet-scrub backlog: empty backlog — exits with message" {
    touch "$PROJECT/work/backlog.md"
    run bash "$SUT" backlog
    assert_output --partial "empty"
}

# ============================================================
# Shellcheck
# ============================================================

@test "fleet-scrub: shellcheck clean" {
    if ! command -v shellcheck &>/dev/null; then skip "shellcheck not installed"; fi
    run shellcheck -S warning "$SUT"
    assert_success
}
