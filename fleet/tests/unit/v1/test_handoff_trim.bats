#!/usr/bin/env bats
# test_handoff_trim.bats — Unit tests for fleet/handoff-trim.sh
#
# handoff-trim.sh truncates handoff files >1400B by keeping everything
# before ## ACTIONS and replacing with empty ACTIONS + DONE sections.

# ============================================================
# Setup / Teardown
# ============================================================

setup() {
    source "$BATS_TEST_DIRNAME/../../helpers/v1/test_helpers.bash"
    _setup

    # Copy SUT to sandbox with fleet-env.sh shim
    SANDBOX="$BATS_TEST_TMPDIR/sandbox"
    mkdir -p "$SANDBOX"
    cp "$REPO_ROOT/fleet/v1/handoff-trim.sh" "$SANDBOX/"
    SUT="$SANDBOX/handoff-trim.sh"

    cat > "$SANDBOX/fleet-env.sh" <<'ENVSHIM'
fleet_bin() {
    local bin="$1"
    command -v "$bin" 2>/dev/null && return
    echo ""
}
export -f fleet_bin
ENVSHIM

    # Create test handoff directory
    MOCK_HANDOFFS="$BATS_TEST_TMPDIR/handoffs"
    mkdir -p "$MOCK_HANDOFFS"
    export FLEET_HANDOFFS="$MOCK_HANDOFFS"
}

teardown() {
    _teardown
}

# Helper: create a handoff file of specific size
_create_handoff() {
    local name="$1" size="$2"
    local dir="${3:-$MOCK_HANDOFFS}"
    {
        echo "# ${name}"
        echo ""
        echo "## STATE"
        echo "date: 2026-03-28 08:00"
        echo "action: idle"
        echo ""
        echo "## ACTIONS"
        echo ""
        # Pad to desired size
        local current
        current=$(wc -c <<< "$(cat)")
        local padding=$(( size - current ))
        if (( padding > 0 )); then
            head -c "$padding" /dev/zero | tr '\0' 'x'
            echo ""
        fi
        echo ""
        echo "## DONE"
        echo "### Old session entry"
        echo "Lots of old content here..."
    } > "$dir/$name"
}

# Helper: create a small handoff (under threshold)
_create_small_handoff() {
    local name="${1:-small-handoff.md}"
    echo -e "# Small\n\n## STATE\ndate: 2026-03-28\n\n## ACTIONS\n\n## DONE\n" > "$MOCK_HANDOFFS/$name"
}

# Helper: create a large handoff (over threshold)
_create_large_handoff() {
    local name="${1:-large-handoff.md}"
    {
        echo "# Large"
        echo ""
        echo "## STATE"
        echo "date: 2026-03-28 08:00"
        echo "action: idle"
        echo ""
        echo "## ACTIONS"
        echo ""
        # Pad past 1400 bytes
        python3 -c "print('x' * 1500)" 2>/dev/null || printf '%1500s\n' | tr ' ' 'x'
        echo ""
        echo "## DONE"
        echo "### Old entry"
        echo "old content..."
    } > "$MOCK_HANDOFFS/$name"
}

# ============================================================
# Nominal tests
# ============================================================

@test "handoff-trim: no files — reports 0 trimmed" {
    run bash "$SUT" "$MOCK_HANDOFFS"
    assert_success
    assert_output --partial "0 trimmed"
}

@test "handoff-trim: small file not trimmed" {
    _create_small_handoff "dev-handoff.md"
    run bash "$SUT" "$MOCK_HANDOFFS"
    assert_success
    assert_output --partial "0 trimmed"
    assert_output --partial "1 checked-ok"
}

@test "handoff-trim: large file is trimmed" {
    _create_large_handoff "dev-handoff.md"
    local before
    before=$(wc -c < "$MOCK_HANDOFFS/dev-handoff.md")
    run bash "$SUT" "$MOCK_HANDOFFS"
    assert_success
    assert_output --partial "1 trimmed"
    assert_output --partial "dev-handoff.md"
    # File should be smaller now
    local after
    after=$(wc -c < "$MOCK_HANDOFFS/dev-handoff.md")
    [[ "$after" -lt "$before" ]]
}

@test "handoff-trim: trimmed file keeps STATE section" {
    _create_large_handoff "dev-handoff.md"
    run bash "$SUT" "$MOCK_HANDOFFS"
    assert_success
    run grep "## STATE" "$MOCK_HANDOFFS/dev-handoff.md"
    assert_success
}

@test "handoff-trim: trimmed file has empty ACTIONS and DONE" {
    _create_large_handoff "dev-handoff.md"
    run bash "$SUT" "$MOCK_HANDOFFS"
    assert_success
    run grep "## ACTIONS" "$MOCK_HANDOFFS/dev-handoff.md"
    assert_success
    run grep "## DONE" "$MOCK_HANDOFFS/dev-handoff.md"
    assert_success
}

@test "handoff-trim: --help displays man page" {
    run bash "$SUT" --help
    assert_success
    assert_output --partial "NAME"
    assert_output --partial "handoff-trim.sh"
}

# ============================================================
# Exempt files
# ============================================================

@test "handoff-trim: starfleet-notes.md is exempt" {
    # Create a large exempt file
    {
        python3 -c "print('x' * 2000)" 2>/dev/null || printf '%2000s\n' | tr ' ' 'x'
    } > "$MOCK_HANDOFFS/starfleet-notes.md"
    local before
    before=$(wc -c < "$MOCK_HANDOFFS/starfleet-notes.md")
    run bash "$SUT" "$MOCK_HANDOFFS"
    assert_success
    assert_output --partial "1 exempt"
    local after
    after=$(wc -c < "$MOCK_HANDOFFS/starfleet-notes.md")
    [[ "$after" -eq "$before" ]]
}

@test "handoff-trim: project-refs.md is exempt" {
    printf '%2000s\n' | tr ' ' 'x' > "$MOCK_HANDOFFS/project-refs.md"
    run bash "$SUT" "$MOCK_HANDOFFS"
    assert_success
    assert_output --partial "exempt"
}

# ============================================================
# Directory argument
# ============================================================

@test "handoff-trim: accepts custom directory argument" {
    local custom="$BATS_TEST_TMPDIR/custom-dir"
    mkdir -p "$custom"
    _create_small_handoff "test-handoff.md"
    cp "$MOCK_HANDOFFS/test-handoff.md" "$custom/"
    run bash "$SUT" "$custom"
    assert_success
    assert_output --partial "checked-ok"
}

# ============================================================
# Regression guard
# ============================================================

@test "handoff-trim: shellcheck clean" {
    run shellcheck --exclude=SC1091,SC2016 "$REPO_ROOT/fleet/v1/handoff-trim.sh"
    assert_success
}
