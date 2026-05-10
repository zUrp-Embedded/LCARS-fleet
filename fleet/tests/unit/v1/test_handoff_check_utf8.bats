#!/usr/bin/env bats
# test_handoff_check_utf8.bats — Unit tests for fleet/handoff-check-utf8.sh
#
# handoff-check-utf8.sh scans handoff files for non-UTF-8 bytes using iconv.
# Three modes: scan all dirs (default), --restore (snapshot only, blocking),
# single file argument.

# ============================================================
# Setup / Teardown
# ============================================================

setup() {
    source "$BATS_TEST_DIRNAME/../helpers/test_helpers.bash"
    _setup

    SUT="$REPO_ROOT/fleet/handoff-check-utf8.sh"

    # Create mock handoff directories
    MOCK_HANDOFFS="$BATS_TEST_TMPDIR/handoffs"
    MOCK_READY_ROOM="$BATS_TEST_TMPDIR/ready-room"
    MOCK_SNAPSHOT="$MOCK_READY_ROOM/handoffs"
    mkdir -p "$MOCK_HANDOFFS" "$MOCK_SNAPSHOT"

    export FLEET_HANDOFFS="$MOCK_HANDOFFS"
    export FLEET_READY_ROOM="$MOCK_READY_ROOM"
}

teardown() {
    _teardown
}

# Helper: create a valid UTF-8 handoff file
_create_valid_handoff() {
    local dir="${1:-$MOCK_HANDOFFS}"
    local name="${2:-test-handoff.md}"
    echo "## STATE" > "$dir/$name"
    echo "date: 2026-03-28 08:00" >> "$dir/$name"
    echo "action: idle" >> "$dir/$name"
}

# Helper: create a file with invalid UTF-8 bytes
_create_corrupted_handoff() {
    local dir="${1:-$MOCK_HANDOFFS}"
    local name="${2:-test-handoff.md}"
    printf '## STATE\ndate: 2026-03-28\n\x80\x81\x82 invalid bytes\n' > "$dir/$name"
}

# ============================================================
# Nominal tests
# ============================================================

@test "handoff-check-utf8: exits 0 with no handoff files" {
    run bash "$SUT"
    assert_success
}

@test "handoff-check-utf8: exits 0 with valid UTF-8 files" {
    _create_valid_handoff "$MOCK_HANDOFFS" "starfleet-handoff.md"
    run bash "$SUT"
    assert_success
    refute_output --partial "AVERTISSEMENT"
}

@test "handoff-check-utf8: detects corrupted file in commons" {
    _create_corrupted_handoff "$MOCK_HANDOFFS" "starfleet-handoff.md"
    run bash "$SUT" 2>&1
    assert_success  # non-blocking in default mode
    assert_output --partial "AVERTISSEMENT"
    assert_output --partial "starfleet-handoff.md"
}

@test "handoff-check-utf8: checks both commons and snapshot dirs" {
    _create_valid_handoff "$MOCK_HANDOFFS" "dev-handoff.md"
    _create_corrupted_handoff "$MOCK_SNAPSHOT" "engineer-handoff.md"
    run bash "$SUT" 2>&1
    assert_success
    assert_output --partial "engineer-handoff.md"
}

@test "handoff-check-utf8: --help displays man page" {
    run bash "$SUT" --help
    assert_success
    assert_output --partial "NAME"
    assert_output --partial "handoff-check-utf8.sh"
}

# ============================================================
# --restore mode
# ============================================================

@test "handoff-check-utf8: --restore exits 0 with valid snapshot" {
    _create_valid_handoff "$MOCK_SNAPSHOT" "starfleet-handoff.md"
    run bash "$SUT" --restore
    assert_success
}

@test "handoff-check-utf8: --restore exits 1 on corrupted snapshot" {
    _create_corrupted_handoff "$MOCK_SNAPSHOT" "starfleet-handoff.md"
    run bash "$SUT" --restore 2>&1
    assert_failure
    assert_output --partial "restauration bloquée"
}

@test "handoff-check-utf8: --restore only checks snapshot dir" {
    _create_corrupted_handoff "$MOCK_HANDOFFS" "dev-handoff.md"
    _create_valid_handoff "$MOCK_SNAPSHOT" "dev-handoff.md"
    run bash "$SUT" --restore
    assert_success  # commons corruption ignored in --restore mode
}

# ============================================================
# Single file mode
# ============================================================

@test "handoff-check-utf8: single valid file exits 0" {
    _create_valid_handoff "$BATS_TEST_TMPDIR" "single.md"
    run bash "$SUT" "$BATS_TEST_TMPDIR/single.md"
    assert_success
    refute_output --partial "AVERTISSEMENT"
}

@test "handoff-check-utf8: single corrupted file reports warning" {
    _create_corrupted_handoff "$BATS_TEST_TMPDIR" "single.md"
    run bash "$SUT" "$BATS_TEST_TMPDIR/single.md" 2>&1
    assert_success  # non-blocking when not --restore
    assert_output --partial "AVERTISSEMENT"
}

@test "handoff-check-utf8: nonexistent single file exits 0 silently" {
    run bash "$SUT" "/nonexistent/path/file.md"
    assert_success
}

# ============================================================
# Edge cases
# ============================================================

@test "handoff-check-utf8: empty file is valid UTF-8" {
    touch "$MOCK_HANDOFFS/empty-handoff.md"
    run bash "$SUT"
    assert_success
    refute_output --partial "AVERTISSEMENT"
}

@test "handoff-check-utf8: reports count of corrupted files" {
    _create_corrupted_handoff "$MOCK_HANDOFFS" "a-handoff.md"
    _create_corrupted_handoff "$MOCK_HANDOFFS" "b-handoff.md"
    run bash "$SUT" 2>&1
    assert_success
    assert_output --partial "2 fichier(s)"
}

@test "handoff-check-utf8: suggests iconv correction command" {
    _create_corrupted_handoff "$MOCK_HANDOFFS" "bad-handoff.md"
    run bash "$SUT" 2>&1
    assert_output --partial "iconv"
}

# ============================================================
# Regression guard
# ============================================================

@test "handoff-check-utf8: shellcheck clean" {
    run shellcheck --exclude=SC1091,SC2016 "$REPO_ROOT/fleet/handoff-check-utf8.sh"
    assert_success
}
