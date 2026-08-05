#!/usr/bin/env bats
# test_drift_check.bats — Unit tests for fleet/drift-check.sh
#
# drift-check.sh compares commit counts and alerts when drift audit is due.

# ============================================================
# Setup / Teardown
# ============================================================

setup() {
    source "$BATS_TEST_DIRNAME/../../helpers/v1/test_helpers.bash"
    _setup

    # Copy SUT to sandbox with fleet-env shim
    SANDBOX="$BATS_TEST_TMPDIR/sandbox"
    mkdir -p "$SANDBOX"
    cp "$REPO_ROOT/fleet/v1/drift-check.sh" "$SANDBOX/"
    SUT="$SANDBOX/drift-check.sh"

    # Mock fleet-state directory
    MOCK_STATE="$BATS_TEST_TMPDIR/fleet-state"
    mkdir -p "$MOCK_STATE"

    cat > "$SANDBOX/fleet-env.sh" <<ENVSHIM
export FLEET_STATE_DIR="$MOCK_STATE"
ENVSHIM
}

teardown() {
    _teardown
}

# ============================================================
# Nominal tests
# ============================================================

@test "drift-check: --help displays man page" {
    run bash "$SUT" --help
    assert_success
    assert_output --partial "NAME"
    assert_output --partial "drift-check.sh"
}

@test "drift-check: no commit files — silent exit" {
    run bash "$SUT"
    assert_success
    refute_output --partial "DRIFT AUDIT"
}

@test "drift-check: delta < 10 — no alert" {
    echo "15" > "$MOCK_STATE/lcars-commit-count"
    echo "10" > "$MOCK_STATE/lcars-commit-count-at-audit"
    run bash "$SUT"
    assert_success
    refute_output --partial "DRIFT AUDIT"
}

@test "drift-check: delta = 10 — alert shown" {
    echo "20" > "$MOCK_STATE/lcars-commit-count"
    echo "10" > "$MOCK_STATE/lcars-commit-count-at-audit"
    run bash "$SUT"
    assert_success
    assert_output --partial "DRIFT AUDIT DUE"
    assert_output --partial "10 commits"
}

@test "drift-check: delta > 10 — alert with count" {
    echo "100" > "$MOCK_STATE/lcars-commit-count"
    echo "50" > "$MOCK_STATE/lcars-commit-count-at-audit"
    run bash "$SUT"
    assert_success
    assert_output --partial "DRIFT AUDIT DUE"
    assert_output --partial "50 commits"
}

@test "drift-check: suggests /drift-audit command" {
    echo "25" > "$MOCK_STATE/lcars-commit-count"
    echo "10" > "$MOCK_STATE/lcars-commit-count-at-audit"
    run bash "$SUT"
    assert_success
    assert_output --partial "/drift-audit"
}

# ============================================================
# Regression guard
# ============================================================

@test "drift-check: shellcheck clean" {
    run shellcheck --exclude=SC1091,SC1090,SC2016 "$REPO_ROOT/fleet/v1/drift-check.sh"
    assert_success
}
