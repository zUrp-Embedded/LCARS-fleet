#!/usr/bin/env bats
# test_watch_handoff.bats — Unit tests for fleet/watch-handoff.sh
#
# watch-handoff.sh is an interactive polling loop (clear + colorize + sleep).
# Tests focus on argument validation, --help, and shellcheck.
# The infinite loop is NOT tested (would require timeout/kill).

# ============================================================
# Setup / Teardown
# ============================================================

setup() {
    source "$BATS_TEST_DIRNAME/../helpers/test_helpers.bash"
    _setup

    SUT="$REPO_ROOT/fleet/watch-handoff.sh"
}

teardown() {
    _teardown
}

# ============================================================
# Nominal tests
# ============================================================

@test "watch-handoff: --help displays man page" {
    run bash "$SUT" --help
    assert_success
    assert_output --partial "NAME"
    assert_output --partial "watch-handoff.sh"
    assert_output --partial "INTERFACE"
    assert_output --partial "Ring:    2"
}

@test "watch-handoff: -h also works" {
    run bash "$SUT" -h
    assert_success
    assert_output --partial "NAME"
}

# ============================================================
# Error tests
# ============================================================

@test "watch-handoff: exits 1 with no arguments" {
    run bash "$SUT"
    assert_failure
    assert_output --partial "usage"
}

# ============================================================
# Regression guard
# ============================================================

@test "watch-handoff: shellcheck clean" {
    run shellcheck --exclude=SC1091,SC2016 "$REPO_ROOT/fleet/watch-handoff.sh"
    assert_success
}
