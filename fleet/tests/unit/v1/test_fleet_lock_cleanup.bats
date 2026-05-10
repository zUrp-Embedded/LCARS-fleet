#!/usr/bin/env bats
# test_fleet_lock_cleanup.bats — Unit tests for fleet/fleet-lock-cleanup.sh
#
# fleet-lock-cleanup.sh removes stale lock files from /tmp/handoff-locks/.

# ============================================================
# Setup / Teardown
# ============================================================

setup() {
    source "$BATS_TEST_DIRNAME/../helpers/test_helpers.bash"
    _setup

    # Copy SUT to sandbox with fleet-env shim
    SANDBOX="$BATS_TEST_TMPDIR/sandbox"
    mkdir -p "$SANDBOX"
    cp "$REPO_ROOT/fleet/fleet-lock-cleanup.sh" "$SANDBOX/"
    SUT="$SANDBOX/fleet-lock-cleanup.sh"

    cat > "$SANDBOX/fleet-env.sh" <<'ENVSHIM'
# minimal shim
:
ENVSHIM

    # Use a temp dir instead of /tmp/handoff-locks
    MOCK_LOCKS="$BATS_TEST_TMPDIR/handoff-locks"
    mkdir -p "$MOCK_LOCKS"

    # Patch the script to use our mock dir
    sed -i "s|/tmp/handoff-locks|$MOCK_LOCKS|g" "$SANDBOX/fleet-lock-cleanup.sh"
}

teardown() {
    _teardown
}

# Helper: create a lock dir with a specific age
_create_lock() {
    local name="$1" age_secs="${2:-0}" owner="${3:-test:1234}"
    local dir="$MOCK_LOCKS/${name}.lock.d"
    mkdir -p "$dir"
    local ts=$(( $(date +%s) - age_secs ))
    echo "${owner}:${ts}" > "$dir/owner"
}

# Helper: create a lock dir with no owner file
_create_orphan_lock() {
    local name="$1"
    mkdir -p "$MOCK_LOCKS/${name}.lock.d"
}

# ============================================================
# Nominal tests
# ============================================================

@test "lock-cleanup: --help displays man page" {
    run bash "$SUT" --help
    assert_success
    assert_output --partial "NAME"
    assert_output --partial "fleet-lock-cleanup.sh"
}

@test "lock-cleanup: no lock dir — silent exit" {
    rmdir "$MOCK_LOCKS"
    run bash "$SUT"
    assert_success
}

@test "lock-cleanup: no lock files — silent exit" {
    run bash "$SUT"
    assert_success
    refute_output --partial "Removing"
}

@test "lock-cleanup: fresh lock (< 3600s) — kept" {
    _create_lock "fresh" 60
    run bash "$SUT"
    assert_success
    refute_output --partial "Removing"
    [[ -d "$MOCK_LOCKS/fresh.lock.d" ]]
}

@test "lock-cleanup: stale lock (> 3600s) — removed" {
    _create_lock "stale" 7200
    run bash "$SUT" 2>&1
    assert_success
    assert_output --partial "Removing stale lock"
    assert_output --partial "stale.lock.d"
    [[ ! -d "$MOCK_LOCKS/stale.lock.d" ]]
}

@test "lock-cleanup: orphan lock (no owner) — removed" {
    _create_orphan_lock "orphan"
    run bash "$SUT" 2>&1
    assert_success
    assert_output --partial "Removing owner-less lock"
    [[ ! -d "$MOCK_LOCKS/orphan.lock.d" ]]
}

@test "lock-cleanup: malformed owner (no timestamp) — removed" {
    mkdir -p "$MOCK_LOCKS/malformed.lock.d"
    echo "broken:format" > "$MOCK_LOCKS/malformed.lock.d/owner"
    run bash "$SUT" 2>&1
    assert_success
    assert_output --partial "Removing malformed lock"
    [[ ! -d "$MOCK_LOCKS/malformed.lock.d" ]]
}

@test "lock-cleanup: reports count of removed locks" {
    _create_lock "old1" 5000
    _create_lock "old2" 6000
    _create_lock "fresh" 10
    run bash "$SUT" 2>&1
    assert_success
    assert_output --partial "Removed 2 stale lock(s)"
    # Fresh one should still be there
    [[ -d "$MOCK_LOCKS/fresh.lock.d" ]]
}

# ============================================================
# Regression guard
# ============================================================

@test "lock-cleanup: shellcheck clean" {
    run shellcheck --exclude=SC1091,SC1090,SC2016 "$REPO_ROOT/fleet/fleet-lock-cleanup.sh"
    assert_success
}
