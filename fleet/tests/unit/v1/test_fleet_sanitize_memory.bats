#!/usr/bin/env bats
# test_fleet_sanitize_memory.bats — Unit tests for fleet/fleet-sanitize-memory.sh
#
# fleet-sanitize-memory.sh strips non-whitelisted sections from MEMORY.md
# files across all fleet instances. Whitelist: Identity, Completed.
# Runs once per day (sentinel file).

# ============================================================
# Setup / Teardown
# ============================================================

setup() {
    source "$BATS_TEST_DIRNAME/../helpers/test_helpers.bash"
    _setup

    # Copy SUT to sandbox with fleet-env.sh shim
    SANDBOX="$BATS_TEST_TMPDIR/sandbox"
    mkdir -p "$SANDBOX"
    cp "$REPO_ROOT/fleet/fleet-sanitize-memory.sh" "$SANDBOX/"
    SUT="$SANDBOX/fleet-sanitize-memory.sh"

    # Create fleet-env shim that provides fleet_roles and HOMES_ROOT
    MOCK_HOMES="$BATS_TEST_TMPDIR/homes"
    mkdir -p "$MOCK_HOMES"

    cat > "$SANDBOX/fleet-env.sh" <<ENVSHIM
export FLEET_LOGS="$BATS_TEST_TMPDIR/logs"
export FLEET_STATE_DIR="$BATS_TEST_TMPDIR/fleet-state"
export HOMES_ROOT="$MOCK_HOMES"
mkdir -p "\$FLEET_LOGS" "\$FLEET_STATE_DIR/run"
fleet_roles() {
    echo "agent1"
    echo "agent2"
}
export -f fleet_roles
fleet_bin() {
    command -v "\$1" 2>/dev/null && return
    echo ""
}
export -f fleet_bin
ENVSHIM

    # Remove any sentinel from today
    rm -f "$BATS_TEST_TMPDIR/fleet-state/run/mem-sanitize-$(date +%Y-%m-%d)"
}

teardown() {
    rm -f "/tmp/mem-sanitize-$(date +%Y-%m-%d)"
    _teardown
}

# Helper: create a MEMORY.md for an agent with given content
_create_memory() {
    local agent="$1"
    shift
    local dir="$MOCK_HOMES/$agent/.claude/projects/-home-$agent/memory"
    mkdir -p "$dir"
    printf '%s\n' "$@" > "$dir/MEMORY.md"
}

# Helper: read a MEMORY.md for an agent
_read_memory() {
    local agent="$1"
    cat "$MOCK_HOMES/$agent/.claude/projects/-home-$agent/memory/MEMORY.md"
}

# ============================================================
# Nominal tests
# ============================================================

@test "sanitize-memory: --help displays man page" {
    run bash "$SUT" --help
    assert_success
    assert_output --partial "NAME"
    assert_output --partial "fleet-sanitize-memory.sh"
}

@test "sanitize-memory: clean memory — no changes" {
    _create_memory "agent1" "# Memory" "" "## Identity" "I am agent1"
    _create_memory "agent2" "# Memory" "" "## Identity" "I am agent2"
    run bash "$SUT"
    assert_success
    assert_output --partial "all MEMORY.md clean"
}

@test "sanitize-memory: strips non-whitelisted sections" {
    _create_memory "agent1" \
        "# Memory" "" \
        "## Identity" "I am agent1" \
        "## Preferences" "user likes tabs" \
        "## Completed" "task done"
    run bash "$SUT"
    assert_success
    # Preferences should be gone
    run _read_memory "agent1"
    refute_output --partial "Preferences"
    refute_output --partial "tabs"
    # Identity and Completed should remain
    assert_output --partial "Identity"
    assert_output --partial "Completed"
}

@test "sanitize-memory: keeps preamble before first ##" {
    _create_memory "agent1" \
        "# Memory" "some preamble text" "" \
        "## Identity" "I am agent1" \
        "## BadSection" "should go"
    run bash "$SUT"
    assert_success
    run _read_memory "agent1"
    assert_output --partial "preamble text"
    refute_output --partial "BadSection"
}

@test "sanitize-memory: creates sentinel file" {
    _create_memory "agent1" "# Memory" "" "## Identity" "I am agent1"
    run bash "$SUT"
    assert_success
    [[ -f "$BATS_TEST_TMPDIR/fleet-state/run/mem-sanitize-$(date +%Y-%m-%d)" ]]
}

@test "sanitize-memory: skips if sentinel exists (once per day)" {
    mkdir -p "$BATS_TEST_TMPDIR/fleet-state/run"
    touch "$BATS_TEST_TMPDIR/fleet-state/run/mem-sanitize-$(date +%Y-%m-%d)"
    _create_memory "agent1" \
        "# Memory" "" \
        "## BadSection" "should stay because sentinel exists"
    run bash "$SUT"
    assert_success
    # File should NOT have been cleaned
    run _read_memory "agent1"
    assert_output --partial "BadSection"
}

@test "sanitize-memory: skips files with < 3 lines" {
    _create_memory "agent1" "# Memory" ""
    run bash "$SUT"
    assert_success
}

@test "sanitize-memory: handles missing MEMORY.md gracefully" {
    # agent1 has no MEMORY.md, agent2 does
    mkdir -p "$MOCK_HOMES/agent1"
    _create_memory "agent2" "# Memory" "" "## Identity" "agent2"
    run bash "$SUT"
    assert_success
}

@test "sanitize-memory: logs cleaned files" {
    _create_memory "agent1" \
        "# Memory" "" \
        "## Identity" "I am agent1" \
        "## Rules" "never do X"
    run bash "$SUT"
    assert_success
    [[ -f "$BATS_TEST_TMPDIR/logs/fleet-state.log" ]]
    run cat "$BATS_TEST_TMPDIR/logs/fleet-state.log"
    assert_output --partial "sanitize-memory"
    assert_output --partial "cleaned"
}

# ============================================================
# Regression guard
# ============================================================

@test "sanitize-memory: shellcheck clean" {
    run shellcheck --exclude=SC1091,SC2016 "$REPO_ROOT/fleet/fleet-sanitize-memory.sh"
    assert_success
}
