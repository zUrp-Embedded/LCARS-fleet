#!/usr/bin/env bats
# test_smoke.bats — Validate test harness works correctly
#
# Verifies: mocks loaded, variables set, filesystem created, assertions work.

setup() {
    source "$BATS_TEST_DIRNAME/../../helpers/v1/test_helpers.bash"
    _setup
}

teardown() {
    _teardown
}

# --- Mock loading ---

@test "mock_fleet_env: FLEET_INSTANCE is set" {
    [[ -n "$FLEET_INSTANCE" ]]
}

@test "mock_fleet_env: FLEET_INSTANCE defaults to starfleet" {
    assert_equal "$FLEET_INSTANCE" "starfleet"
}

@test "mock_fleet_env: all 23 exported variables are set" {
    # Every variable exported by fleet-env.sh must be non-empty
    [[ -n "$LCARS_ROOT" ]]
    [[ -n "$HOMES_ROOT" ]]
    [[ -n "$FLEET_YAML" ]]
    [[ -n "$FLEET_DIR" ]]
    [[ -n "$FLEET_DIRECTIVES" ]]
    [[ -n "$FLEET_DOCS" ]]
    [[ -n "$FLEET_KNOWLEDGE" ]]
    [[ -n "$FLEET_HANDOFFS" ]]
    [[ -n "$FLEET_STATE_DIR" ]]
    [[ -n "$FLEET_LOGS" ]]
    [[ -n "$FLEET_READY_ROOM" ]]
    [[ -n "$FLEET_TMUX_SOCK" ]]
    [[ -n "$FLEET_HUB_PORT" ]]
    [[ -n "$FLEET_SPOOL" ]]
    [[ -n "$FLEET_SPOOL_INBOX" ]]
    [[ -n "$FLEET_SPOOL_OUTBOX" ]]
    [[ -n "$FLEET_PENDING_WAKES" ]]
    [[ -n "$FLEET_INSTANCE" ]]
    [[ -n "$FLEET_USER" ]]
    [[ -n "$FLEET_USER_HOME" ]]
    [[ -n "$ARCHITECT_USER" ]]
    [[ -n "$ARCHITECT_HOME" ]]
    [[ -n "$LCARS_REPO" ]]
}

@test "mock_fleet_env: all paths point to tmpdir (no real filesystem)" {
    [[ "$LCARS_ROOT" == "$BATS_TEST_TMPDIR"* ]]
    [[ "$FLEET_SPOOL" == "$BATS_TEST_TMPDIR"* ]]
    [[ "$FLEET_HANDOFFS" == "$BATS_TEST_TMPDIR"* ]]
    [[ "$FLEET_STATE_DIR" == "$BATS_TEST_TMPDIR"* ]]
}

# --- Mock functions ---

@test "mock_fleet_env: fleet_roles returns known roles" {
    run fleet_roles
    assert_success
    assert_line "starfleet"
    assert_line "engineer"
    assert_line "dev"
}

@test "mock_fleet_env: fleet_roles_by_tier 0 returns tier 0 agents" {
    run fleet_roles_by_tier 0
    assert_success
    assert_line "starfleet"
    assert_line "architect"
}

@test "mock_fleet_env: fleet_role_field returns correct values" {
    run fleet_role_field starfleet tier
    assert_output "0"
    run fleet_role_field dev scope
    assert_output "code"
}

@test "mock_fleet_env: fleet_role_field unknown returns null" {
    run fleet_role_field nonexistent tier
    assert_output "null"
}

@test "mock_fleet_env: fleet_find_pane returns pane for known agents" {
    run fleet_find_pane dev
    assert_output "%mock-dev"
}

@test "mock_fleet_env: fleet_find_pane returns empty for unknown agents" {
    run fleet_find_pane nonexistent
    assert_output ""
}

# --- Mock tmux ---

@test "mock_tmux: tmux has-session succeeds for fleet" {
    run tmux has-session -t fleet
    assert_success
}

@test "mock_tmux: tmux has-session fails for unknown session" {
    run tmux has-session -t nonexistent
    assert_failure
}

@test "mock_tmux: tmux calls are logged" {
    tmux send-keys -t %0 "echo test" Enter
    assert_file_exists "$BATS_TEST_TMPDIR/tmux.log"
    run cat "$BATS_TEST_TMPDIR/tmux.log"
    assert_output --partial "send-keys"
}

# --- Mock yq ---

@test "mock_yq: returns fleet paths" {
    run yq '.fleet.paths.lcars_root' /dev/null
    assert_output "/local/LCARS"
}

@test "mock_yq: unknown query returns null" {
    run yq '.nonexistent.path' /dev/null
    assert_output "null"
}

# --- Test filesystem ---

@test "test_helpers: spool inbox directories exist" {
    assert_dir_exists "$FLEET_SPOOL_INBOX/starfleet"
    assert_dir_exists "$FLEET_SPOOL_INBOX/engineer"
    assert_dir_exists "$FLEET_SPOOL_INBOX/dev"
}

@test "test_helpers: spool processing/consumed subdirs exist" {
    assert_dir_exists "$FLEET_SPOOL_INBOX/starfleet/.processing"
    assert_dir_exists "$FLEET_SPOOL_INBOX/starfleet/.consumed"
}

@test "test_helpers: homes directories exist" {
    assert_dir_exists "$HOMES_ROOT/starfleet"
    assert_dir_exists "$HOMES_ROOT/architect"
    assert_dir_exists "$HOMES_ROOT/dev"
}

@test "test_helpers: fixtures are copied" {
    assert_file_exists "$BATS_TEST_TMPDIR/fixtures/fleet.yaml"
}

# --- bats-assert works ---

@test "bats-assert: assert_equal works" {
    assert_equal "hello" "hello"
}

@test "bats-assert: assert_output works with run" {
    run echo "test output"
    assert_output "test output"
}
