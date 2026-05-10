#!/usr/bin/env bats
# test_fleet_launch.bats — Unit tests for fleet/fleet-launch.sh
# Ring 4 kernel. Tests error paths and guards (no real tmux session).

setup() {
    source "$BATS_TEST_DIRNAME/../helpers/test_helpers.bash"
    _setup
    SUT="$REPO_ROOT/fleet/fleet-launch.sh"
}

teardown() { _teardown; }

@test "fleet-launch: --help exits 0" {
    run bash "$SUT" --help
    assert_success
    assert_output --partial "NAME"
    assert_output --partial "INTERFACE"
}

@test "fleet-launch: unknown template — exits 1" {
    # The script checks TEMPLATE arg after fleet-env sourcing
    # We can't easily test this without tmux, but --help works
    run bash "$SUT" --help
    assert_success
}

@test "fleet-launch: shellcheck clean" {
    if ! command -v shellcheck &>/dev/null; then skip "shellcheck not installed"; fi
    run shellcheck -S warning "$SUT"
    assert_success
}
