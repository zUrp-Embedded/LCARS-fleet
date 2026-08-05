#!/usr/bin/env bats
# test_light_off.bats — Unit tests for fleet/light_off.sh
# Ring 4 kernel. Tests --help, helpers, shellcheck.

setup() {
    source "$BATS_TEST_DIRNAME/../../helpers/v1/test_helpers.bash"
    _setup

    # light_off.sh sources fleet-env then uses fleet functions.
    # Create a sandbox with shim for testable paths.
    SANDBOX="$BATS_TEST_TMPDIR/sandbox"
    mkdir -p "$SANDBOX"
    cp "$REPO_ROOT/fleet/v1/light_off.sh" "$SANDBOX/"
    SUT="$SANDBOX/light_off.sh"

    cat > "$SANDBOX/fleet-env.sh" <<'ENVSHIM'
# shim — minimal for light_off error paths
FLEET_TMUX_SOCK="/tmp/fleet-tmux-test-nonexistent.sock"
fleet_roles() { echo "starfleet"; }
fleet_find_pane() { echo ""; }
fleet_tmux() { return 1; }
export -f fleet_roles fleet_find_pane fleet_tmux
ENVSHIM
}

teardown() { _teardown; }

@test "light_off: --help exits 0" {
    run bash "$REPO_ROOT/fleet/v1/light_off.sh" --help
    assert_success
    assert_output --partial "NAME"
    assert_output --partial "INTERFACE"
}

@test "light_off: no tmux session — exits gracefully" {
    run bash "$SUT"
    # Should not crash — tmux commands fail silently via shim
    # The script may exit 0 (no session to kill) or 1 (timeout)
    # Either is acceptable — no crash is the test
    [[ "$status" -eq 0 || "$status" -eq 1 ]]
}

@test "light_off: shellcheck clean" {
    if ! command -v shellcheck &>/dev/null; then skip "shellcheck not installed"; fi
    run shellcheck -S warning "$REPO_ROOT/fleet/v1/light_off.sh"
    assert_success
}
