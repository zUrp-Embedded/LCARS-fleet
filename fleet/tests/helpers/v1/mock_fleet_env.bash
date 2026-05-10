#!/bin/bash
# mock_fleet_env.bash — Mock fleet-env.sh for bats testing
#
# PURPOSE : Reproduce the exact export interface of fleet/fleet-env.sh
#           without depending on yq, fleet.yaml, or real filesystem.
# INPUTS  : $BATS_TEST_TMPDIR must be set (bats provides this).
# OUTPUTS : All 23 variables + 8 functions exported by fleet-env.sh.
# CONTRACT: Every variable and function exported by fleet-env.sh MUST
#           be present here. If fleet-env.sh adds an export, this mock
#           MUST be updated. Test test_mock_coherence.bats verifies this.
#
# USAGE   : source "$BATS_TEST_DIRNAME/../helpers/mock_fleet_env.bash"
#           (in setup() of each .bats file via test_helpers.bash)

# --- Guard: require BATS_TEST_TMPDIR ---
if [[ -z "${BATS_TEST_TMPDIR:-}" ]]; then
    echo "FATAL: mock_fleet_env.bash requires BATS_TEST_TMPDIR" >&2
    return 1 2>/dev/null || exit 1
fi

# --- Base paths (all under tmpdir — no real filesystem touched) ---
export LCARS_ROOT="$BATS_TEST_TMPDIR/lcars"
export HOMES_ROOT="$BATS_TEST_TMPDIR/homes"

# --- fleet.yaml fixture ---
export FLEET_YAML="$BATS_TEST_TMPDIR/fixtures/fleet.yaml"

# --- Derived paths (mirrors fleet-env.sh logic) ---
export FLEET_DIR="$LCARS_ROOT/fleet"
export FLEET_DIRECTIVES="$LCARS_ROOT/directives"
export FLEET_DOCS="$LCARS_ROOT/docs"
export FLEET_KNOWLEDGE="$LCARS_ROOT/knowledge"

# --- Persistent dirs ---
export FLEET_HANDOFFS="$BATS_TEST_TMPDIR/handoffs"
export FLEET_STATE_DIR="$BATS_TEST_TMPDIR/fleet-state"
export FLEET_LOGS="$FLEET_STATE_DIR"
export FLEET_READY_ROOM="$BATS_TEST_TMPDIR/ready-room"

# --- Runtime ---
export FLEET_TMUX_SOCK="$BATS_TEST_TMPDIR/fleet-tmux.sock"
export FLEET_HUB_PORT="18765"  # non-standard port to avoid collision

# --- Spool IPC ---
export FLEET_SPOOL="$BATS_TEST_TMPDIR/spool"
export FLEET_SPOOL_INBOX="$FLEET_SPOOL/inbox"
export FLEET_SPOOL_OUTBOX="$FLEET_SPOOL/outbox"
export FLEET_PENDING_WAKES="$FLEET_SPOOL/pending-wakes"

# --- Identity ---
export FLEET_INSTANCE="${MOCK_FLEET_INSTANCE:-starfleet}"
export FLEET_USER="${MOCK_FLEET_USER:-testuser}"
export FLEET_USER_HOME="$HOMES_ROOT/$FLEET_USER"
export ARCHITECT_USER="architect"
export ARCHITECT_HOME="$HOMES_ROOT/architect"

# --- GitHub ---
export LCARS_REPO="testuser/LCARS-test"

# --- Blueprint query functions (mock) ---
# These return predictable fixture data instead of querying yq.

fleet_roles() {
    echo "starfleet"
    echo "architect"
    echo "engineer"
    echo "dev"
    echo "qualifier"
    echo "reviewer"
}

fleet_roles_by_tier() {
    case "$1" in
        0) echo "starfleet"; echo "architect" ;;
        1) echo "engineer" ;;
        2) echo "dev"; echo "qualifier"; echo "reviewer" ;;
        *) ;;
    esac
}

fleet_roles_stateless() {
    echo "qualifier"
    echo "reviewer"
}

fleet_roles_stateful() {
    echo "starfleet"
    echo "architect"
    echo "engineer"
    echo "dev"
}

fleet_role_field() {
    local role="$1" field="$2"
    # Minimal fixture data for common queries
    case "$role.$field" in
        starfleet.tier)   echo "0" ;;
        starfleet.scope)  echo "boundary-os" ;;
        architect.tier)   echo "0" ;;
        architect.scope)  echo "boundary-user" ;;
        engineer.tier)    echo "1" ;;
        engineer.scope)   echo "sas-user" ;;
        dev.tier)         echo "2" ;;
        dev.scope)        echo "code" ;;
        qualifier.tier)   echo "2" ;;
        qualifier.scope)  echo "test" ;;
        reviewer.tier)    echo "2" ;;
        reviewer.scope)   echo "analysis" ;;
        *)                echo "null" ;;
    esac
}

# fleet_tmux — mock: log calls, don't execute
fleet_tmux() {
    echo "MOCK_TMUX: $*" >> "$BATS_TEST_TMPDIR/tmux.log"
}

# fleet_find_pane — mock: return fake pane ID
fleet_find_pane() {
    local agent="$1"
    case "$agent" in
        starfleet|architect|engineer|dev)
            echo "%mock-${agent}"
            ;;
        *)
            echo ""  # unknown agent = no pane
            ;;
    esac
}

# fleet_bin — mock: check in test bin dir
fleet_bin() {
    local bin="$1"
    if [[ -x "$BATS_TEST_TMPDIR/bin/$bin" ]]; then
        echo "$BATS_TEST_TMPDIR/bin/$bin"
    else
        echo ""
    fi
}

export -f fleet_roles fleet_roles_by_tier fleet_roles_stateless fleet_roles_stateful
export -f fleet_role_field fleet_tmux fleet_find_pane fleet_bin
