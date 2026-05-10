#!/usr/bin/env bats
# test_mock_coherence.bats — Verify mocks match real interfaces
#
# PURPOSE: Detect drift between mock_fleet_env.bash and real fleet-env.sh.
#          If fleet-env.sh adds a variable or function, this test fails
#          until the mock is updated. Prevents false-green test suites.
#
# RUNS IN CI: yes (part of unit tests)

setup() {
    source "$BATS_TEST_DIRNAME/../helpers/test_helpers.bash"
    _setup
    REAL_SCRIPT="$REPO_ROOT/fleet/fleet-env.sh"
    MOCK_SCRIPT="$REPO_ROOT/tests/helpers/mock_fleet_env.bash"
}

teardown() {
    _teardown
}

# Helper: extract all exported variable names from a script.
# Handles both `export VAR=val` and `export VAR1 VAR2 VAR3` (re-export).
_extract_vars() {
    local file="$1"
    grep -P '^export\s' "$file" \
        | grep -v 'export -f' \
        | sed 's/export //; s/=.*//g' \
        | tr ' ' '\n' \
        | grep -P '^(FLEET_|LCARS_|HOMES_|ARCHITECT_)' \
        | sort -u
}

# Helper: extract all exported function names from a script.
# Handles `export -f fn1 fn2 fn3` on a single line.
_extract_fns() {
    local file="$1"
    grep -P 'export\s+-f\s' "$file" \
        | sed 's/export -f //' \
        | tr ' ' '\n' \
        | grep -P '^\w+$' \
        | sort -u
}

# ============================================================
# Variable coherence
# ============================================================

@test "mock_coherence: all variables from fleet-env.sh are in mock" {
    local real_vars
    real_vars=$(_extract_vars "$REAL_SCRIPT")

    local missing=""
    for var in $real_vars; do
        if [[ -z "${!var+x}" ]]; then
            missing+="  $var\n"
        fi
    done

    if [[ -n "$missing" ]]; then
        echo "Variables in fleet-env.sh but NOT set by mock:"
        echo -e "$missing"
        false
    fi
}

@test "mock_coherence: mock has no stale variables absent from fleet-env.sh" {
    local real_vars mock_vars
    real_vars=$(_extract_vars "$REAL_SCRIPT")
    mock_vars=$(_extract_vars "$MOCK_SCRIPT")

    local extra=""
    for var in $mock_vars; do
        if ! echo "$real_vars" | grep -qxF "$var"; then
            extra+="  $var\n"
        fi
    done

    if [[ -n "$extra" ]]; then
        echo "Variables in mock but NOT in fleet-env.sh (stale):"
        echo -e "$extra"
        false
    fi
}

# ============================================================
# Function coherence
# ============================================================

@test "mock_coherence: all exported functions from fleet-env.sh are in mock" {
    local real_fns
    real_fns=$(_extract_fns "$REAL_SCRIPT")

    local missing=""
    for fn in $real_fns; do
        if ! declare -F "$fn" &>/dev/null; then
            missing+="  $fn\n"
        fi
    done

    if [[ -n "$missing" ]]; then
        echo "Functions in fleet-env.sh but NOT in mock:"
        echo -e "$missing"
        false
    fi
}

@test "mock_coherence: mock has no stale functions absent from fleet-env.sh" {
    local real_fns mock_fns
    real_fns=$(_extract_fns "$REAL_SCRIPT")
    mock_fns=$(_extract_fns "$MOCK_SCRIPT")

    local extra=""
    for fn in $mock_fns; do
        if ! echo "$real_fns" | grep -qxF "$fn"; then
            extra+="  $fn\n"
        fi
    done

    if [[ -n "$extra" ]]; then
        echo "Functions in mock but NOT in fleet-env.sh (stale):"
        echo -e "$extra"
        false
    fi
}

# ============================================================
# Count sanity checks
# ============================================================

@test "mock_coherence: variable count matches" {
    local real_count mock_count
    real_count=$(_extract_vars "$REAL_SCRIPT" | wc -l)
    mock_count=$(_extract_vars "$MOCK_SCRIPT" | wc -l)

    [[ "$mock_count" -eq "$real_count" ]] || {
        echo "Variable count mismatch: mock=$mock_count, real=$real_count"
        echo "Real:"
        _extract_vars "$REAL_SCRIPT"
        echo "Mock:"
        _extract_vars "$MOCK_SCRIPT"
        false
    }
}

@test "mock_coherence: function count matches" {
    local real_count mock_count
    real_count=$(_extract_fns "$REAL_SCRIPT" | wc -l)
    mock_count=$(_extract_fns "$MOCK_SCRIPT" | wc -l)

    [[ "$mock_count" -eq "$real_count" ]] || {
        echo "Function count mismatch: mock=$mock_count, real=$real_count"
        echo "Real:"
        _extract_fns "$REAL_SCRIPT"
        echo "Mock:"
        _extract_fns "$MOCK_SCRIPT"
        false
    }
}
