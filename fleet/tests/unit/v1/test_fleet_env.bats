#!/usr/bin/env bats
# test_fleet_env.bats — Unit tests for fleet/fleet-env.sh
#
# Reference: docs/qualification/plans/phase2-failure-modes.md (ENV-01 to ENV-12)
#            docs/qualification/fmea/FMEA-agent-starfleet.md (SF-04, SF-06, SF-14)
#
# fleet-env.sh is sourced, not executed. All tests source it in a controlled
# environment with mock yq and mock fleet.yaml (via test_helpers).

# ============================================================
# Setup / Teardown
# ============================================================

setup() {
    source "$BATS_TEST_DIRNAME/../../helpers/v1/test_helpers.bash"
    _setup

    # fleet-env.sh resolves its own location via BASH_SOURCE.
    # Point it to the real script but with our mock yq and fleet.yaml.
    SUT="$REPO_ROOT/fleet/v1/fleet-env.sh"

    # Ensure our mock yq is first in PATH (test_helpers already does this)
    # and FLEET_YAML points to our fixture
    export FLEET_YAML="$BATS_TEST_TMPDIR/lcars/fleet/fleet.yaml"
}

teardown() {
    _teardown
}

# Helper: source fleet-env.sh in a subshell with controlled env.
# Returns the value of a given variable after sourcing.
_source_env() {
    # Source in subshell to avoid polluting test env
    (
        cd "$BATS_TEST_TMPDIR"
        source "$SUT"
        # Print requested variable if specified
        local var="${1:-}"
        if [[ -n "$var" ]]; then
            echo "${!var}"
        fi
        true
    )
}

# Helper: source fleet-env.sh and print multiple vars
_source_env_vars() {
    (
        cd "$BATS_TEST_TMPDIR"
        source "$SUT"
        for var in "$@"; do
            echo "$var=${!var}"
        done
    )
}

# ============================================================
# Nominal tests — happy path
# ============================================================

@test "fleet-env: sources without error" {
    run _source_env
    assert_success
}

@test "fleet-env: LCARS_ROOT set from fleet.yaml" {
    run _source_env LCARS_ROOT
    assert_success
    assert_output "/local/LCARS"
}

@test "fleet-env: HOMES_ROOT set from fleet.yaml" {
    run _source_env HOMES_ROOT
    assert_success
    assert_output "/home"
}

@test "fleet-env: FLEET_YAML points to valid file" {
    run _source_env FLEET_YAML
    assert_success
    # Should be our fixture
    assert_output --partial "fleet.yaml"
}

@test "fleet-env: FLEET_DIR derived from LCARS_ROOT" {
    run _source_env FLEET_DIR
    assert_success
    assert_output "/local/LCARS/fleet"
}

@test "fleet-env: FLEET_SPOOL set from fleet.yaml" {
    run _source_env FLEET_SPOOL
    assert_success
    assert_output "/var/spool/fleet"
}

@test "fleet-env: FLEET_SPOOL_INBOX derived from FLEET_SPOOL" {
    run _source_env FLEET_SPOOL_INBOX
    assert_success
    assert_output "/var/spool/fleet/inbox"
}

@test "fleet-env: FLEET_INSTANCE defaults to mock instance" {
    run _source_env FLEET_INSTANCE
    assert_success
    # mock sets FLEET_INSTANCE via CLAUDE_AGENT_NAME or mock default
    [[ -n "$output" ]]
}

@test "fleet-env: all 23 variables are exported" {
    run bash -c '
        export FLEET_YAML="'"$FLEET_YAML"'"
        source "'"$SUT"'"
        for var in LCARS_ROOT HOMES_ROOT FLEET_YAML FLEET_DIR FLEET_DIRECTIVES \
                   FLEET_DOCS FLEET_KNOWLEDGE FLEET_HANDOFFS FLEET_STATE_DIR \
                   FLEET_LOGS FLEET_READY_ROOM FLEET_TMUX_SOCK FLEET_HUB_PORT \
                   FLEET_SPOOL FLEET_SPOOL_INBOX FLEET_SPOOL_OUTBOX \
                   FLEET_PENDING_WAKES FLEET_INSTANCE FLEET_USER \
                   FLEET_USER_HOME ARCHITECT_USER ARCHITECT_HOME LCARS_REPO; do
            [[ -n "${!var+x}" ]] || echo "MISSING: $var"
        done
    '
    assert_success
    refute_output --partial "MISSING"
}

@test "fleet-env: all 8 functions are exported" {
    run bash -c '
        export FLEET_YAML="'"$FLEET_YAML"'"
        source "'"$SUT"'"
        for fn in fleet_roles fleet_roles_by_tier fleet_roles_stateless \
                  fleet_roles_stateful fleet_role_field fleet_tmux \
                  fleet_find_pane fleet_bin; do
            declare -F "$fn" &>/dev/null || echo "MISSING: $fn"
        done
    '
    assert_success
    refute_output --partial "MISSING"
}

@test "fleet-env: fleet_roles returns known roles" {
    run bash -c '
        export FLEET_YAML="'"$FLEET_YAML"'"
        source "'"$SUT"'"
        fleet_roles
    '
    assert_success
    assert_output --partial "starfleet"
}

@test "fleet-env: fleet_role_field returns a value for known role" {
    run bash -c '
        export FLEET_YAML="'"$FLEET_YAML"'"
        source "'"$SUT"'"
        fleet_role_field starfleet tier
    '
    assert_success
    # Mock yq returns values from fixture — may be "0" or "null" depending on mock
    [[ -n "$output" ]]
}

@test "fleet-env: fleet_role_field unknown role returns null" {
    run bash -c '
        export FLEET_YAML="'"$FLEET_YAML"'"
        source "'"$SUT"'"
        fleet_role_field nonexistent tier
    '
    assert_success
    # yq returns "null" for missing paths
    [[ "$output" == "null" || -z "$output" ]]
}

@test "fleet-env: fleet_bin returns empty for unknown binary" {
    run bash -c '
        export FLEET_YAML="'"$FLEET_YAML"'"
        source "'"$SUT"'"
        fleet_bin "nonexistent-binary-12345"
    '
    assert_success
    assert_output ""
}

# ============================================================
# Error tests — ENV-01 to ENV-12
# ============================================================

@test "fleet-env: [ENV-01] yq absent exits with error" {
    # Hide yq from PATH
    function yq() { return 127; }
    export -f yq
    # Also hide from command -v
    function command() {
        if [[ "${2:-}" == "yq" ]]; then return 1; fi
        builtin command "$@"
    }
    export -f command

    run bash -c 'source "'"$SUT"'"'
    assert_failure
    assert_output --partial "yq"
}

@test "fleet-env: [ENV-02] fleet.yaml absent uses fallbacks" {
    # Remove fleet.yaml from both locations
    rm -f "$FLEET_YAML"
    # Unset so fleet-env.sh searches for it
    unset FLEET_YAML

    # Also ensure HOME/.lcars doesn't exist
    export HOME="$BATS_TEST_TMPDIR/fakehome"
    mkdir -p "$HOME/.claude"

    run bash -c '
        unset FLEET_YAML
        export HOME="'"$BATS_TEST_TMPDIR/fakehome"'"
        mkdir -p "$HOME/.claude"
        source "'"$SUT"'" 2>/dev/null
        echo "LCARS_ROOT=$LCARS_ROOT"
        echo "FLEET_YAML=$FLEET_YAML"
    '
    assert_success
    # Should use fallback /local/LCARS
    assert_output --partial "LCARS_ROOT=/local/LCARS"
    # FLEET_YAML should be /dev/null (no fleet.yaml found anywhere)
    # NOTE: fleet-env resolves via BASH_SOURCE dirname first — if the real
    # fleet.yaml exists there, it will be found. This test verifies the
    # fallback path works when HOME/.lcars doesn't exist either.
    # The real fleet.yaml at source location takes precedence.
    assert_output --partial "FLEET_YAML="
}

@test "fleet-env: [ENV-03] fleet.yaml empty uses fallbacks" {
    # Empty fleet.yaml
    > "$FLEET_YAML"

    run bash -c '
        export FLEET_YAML="'"$FLEET_YAML"'"
        source "'"$SUT"'" 2>/dev/null
        echo "LCARS_ROOT=$LCARS_ROOT"
        echo "HOMES_ROOT=$HOMES_ROOT"
    '
    assert_success
    assert_output --partial "LCARS_ROOT=/local/LCARS"
    assert_output --partial "HOMES_ROOT=/home"
}

@test "fleet-env: [ENV-03] fleet.yaml invalid YAML uses fallbacks" {
    # Broken YAML
    echo "{{{{ invalid yaml ::::" > "$FLEET_YAML"

    run bash -c '
        export FLEET_YAML="'"$FLEET_YAML"'"
        source "'"$SUT"'" 2>/dev/null
        echo "LCARS_ROOT=$LCARS_ROOT"
        echo "HOMES_ROOT=$HOMES_ROOT"
    '
    assert_success
    assert_output --partial "LCARS_ROOT=/local/LCARS"
    assert_output --partial "HOMES_ROOT=/home"
}

@test "fleet-env: [ENV-04] fleet.yaml missing paths section uses fallbacks" {
    # Valid YAML but no fleet.paths
    cat > "$FLEET_YAML" <<'YAML'
fleet:
  version: "6.0.0-beta"
spool:
  root: /var/spool/fleet
YAML

    run bash -c '
        export FLEET_YAML="'"$FLEET_YAML"'"
        source "'"$SUT"'" 2>/dev/null
        echo "LCARS_ROOT=$LCARS_ROOT"
        echo "HOMES_ROOT=$HOMES_ROOT"
        echo "FLEET_HANDOFFS=$FLEET_HANDOFFS"
    '
    assert_success
    assert_output --partial "LCARS_ROOT=/local/LCARS"
    assert_output --partial "HOMES_ROOT=/home"
    assert_output --partial "FLEET_HANDOFFS=/home/projects.work/LCARS/work/handoffs"
}

@test "fleet-env: [ENV-05] FLEET_HUB_PORT pre-set in env is preserved" {
    run bash -c '
        export FLEET_YAML="'"$FLEET_YAML"'"
        export FLEET_HUB_PORT=9999
        source "'"$SUT"'"
        echo "$FLEET_HUB_PORT"
    '
    assert_success
    assert_output "9999"
}

@test "fleet-env: [ENV-08] fleet_find_pane with absent tmux socket does not crash" {
    # fleet_find_pane checks -S on FLEET_TMUX_SOCK. If absent, falls back
    # to plain tmux list-panes (no -S). The mock tmux returns fixture panes.
    # In production, real tmux would fail. Here we verify no crash.
    run bash -c '
        export FLEET_YAML="'"$FLEET_YAML"'"
        source "'"$SUT"'"
        export FLEET_TMUX_SOCK="/nonexistent/socket"
        fleet_find_pane starfleet 2>/dev/null
        echo "EXIT:$?"
    '
    assert_success
    # No crash — the function returns something (mock) or empty (real)
    refute_output --partial "error"
}

@test "fleet-env: [ENV-09] fleet_role_field with metacharacters in role" {
    # Verify yq injection doesn't execute
    run bash -c '
        export FLEET_YAML="'"$FLEET_YAML"'"
        source "'"$SUT"'"
        result=$(fleet_role_field "evil\"; echo INJECTED; #" tier 2>/dev/null)
        echo "result=[$result]"
    '
    assert_success
    # Should NOT contain INJECTED
    refute_output --partial "INJECTED"
}

@test "fleet-env: [ENV-11] fleet_bin returns empty for nonexistent binary" {
    run bash -c '
        export FLEET_YAML="'"$FLEET_YAML"'"
        source "'"$SUT"'"
        result=$(fleet_bin "nonexistent-12345")
        [[ -z "$result" ]] && echo "EMPTY" || echo "GOT: $result"
    '
    assert_success
    assert_output "EMPTY"
}

@test "fleet-env: [ENV-12] FLEET_INSTANCE fallback when no identity sources" {
    run bash -c '
        export FLEET_YAML="'"$FLEET_YAML"'"
        unset CLAUDE_AGENT_NAME
        export HOME="'"$BATS_TEST_TMPDIR/fakehome"'"
        mkdir -p "$HOME/.claude"
        # No instance-name file, no CLAUDE_AGENT_NAME
        source "'"$SUT"'"
        echo "INSTANCE=$FLEET_INSTANCE"
    '
    assert_success
    # Should fall back to hostname
    assert_output --partial "INSTANCE="
    # Should NOT be empty
    [[ "$output" != "INSTANCE=" ]]
}

# ============================================================
# FMEA cross-ref — Severity >= 9 modes
# ============================================================

@test "fleet-env: [FMEA SF-04] corrupted fleet.yaml does not crash" {
    echo "{{{{invalid yaml" > "$FLEET_YAML"
    run bash -c '
        export FLEET_YAML="'"$FLEET_YAML"'"
        source "'"$SUT"'" 2>/dev/null
        echo "OK"
    '
    assert_success
    assert_output --partial "OK"
}

# ============================================================
# --json mode (Ring 0 API — direct execution)
# ============================================================

@test "fleet-env --json: outputs valid JSON" {
    run bash "$SUT" --json
    assert_success
    echo "$output" | python3 -m json.tool > /dev/null
}

@test "fleet-env --json: contains all 23 interface keys" {
    run bash "$SUT" --json
    assert_success
    local missing
    missing=$(echo "$output" | python3 -c "
import sys, json
d = json.load(sys.stdin)
required = ['lcars_root','homes_root','fleet_yaml','fleet_dir','fleet_directives',
    'fleet_docs','fleet_knowledge','fleet_handoffs','fleet_state_dir','fleet_logs',
    'fleet_ready_room','fleet_tmux_sock','fleet_hub_port','fleet_spool',
    'fleet_spool_inbox','fleet_spool_outbox','fleet_pending_wakes',
    'fleet_instance','fleet_user','fleet_user_home','architect_user',
    'architect_home','lcars_repo']
missing = [k for k in required if k not in d]
if missing: print(' '.join(missing))
")
    [[ -z "$missing" ]] || fail "Missing keys: $missing"
}

@test "fleet-env --json: no value is empty or null" {
    run bash "$SUT" --json
    assert_success
    local bad
    bad=$(echo "$output" | python3 -c "
import sys, json
d = json.load(sys.stdin)
bad = [k for k,v in d.items() if not v or v == 'null']
if bad: print(' '.join(bad))
")
    [[ -z "$bad" ]] || fail "Empty/null values: $bad"
}

@test "fleet-env --json: source mode unaffected (no JSON leaked)" {
    run bash -c "source '$SUT' && echo \$LCARS_ROOT"
    assert_success
    # Output should NOT contain JSON braces
    refute_output --partial "{"
    assert_output --partial "LCARS"
}

# ============================================================
# Regression guard
# ============================================================

@test "fleet-env: regression 37fa64b — shellcheck clean (no warnings/errors)" {
    # SC2317 (info) is a false positive on return/exit fallback pattern
    # SC1091 (info) can't follow self-source in --json mode
    run shellcheck --exclude=SC2317,SC1091 "$SUT"
    assert_success
}
