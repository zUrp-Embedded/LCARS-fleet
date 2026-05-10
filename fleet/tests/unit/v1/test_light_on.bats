#!/usr/bin/env bats
# test_light_on.bats — Unit tests for fleet/light_on.sh
# Ring 4 kernel. Tests argument parsing, error paths, deploy gate.

setup() {
    source "$BATS_TEST_DIRNAME/../helpers/test_helpers.bash"
    _setup
    SUT="$REPO_ROOT/fleet/light_on.sh"
}

teardown() { _teardown; }

@test "light_on: --help exits 0" {
    run bash "$SUT" --help
    assert_success
    assert_output --partial "NAME"
    assert_output --partial "INTERFACE"
}

@test "light_on: unknown argument — exits 1" {
    run bash "$SUT" --bogus
    assert_failure
    assert_output --partial "Usage"
}

@test "light_on: shellcheck clean" {
    if ! command -v shellcheck &>/dev/null; then skip "shellcheck not installed"; fi
    run shellcheck -S warning "$SUT"
    assert_success
}
