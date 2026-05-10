#!/bin/bash
# DEPLOY: instance-util
# SOURCE: coverage.sh
# AUTHOR: STARFLEET
# STARDATE: 2026.091
#
#     [FR]
#     Mesure la couverture de code des scripts fleet via xtrace.
#
#     [EN]
#     NAME
#         coverage.sh — bash code coverage via xtrace instrumentation
#
#     INTERFACE
#         Ring:    gate (quality tooling)
#         Input:   fleet scripts, test scenarios embedded in this file
#         Output:  stdout coverage report per script
#         JSON:    non
#
# --- END HEADER ---

set -euo pipefail

REPO_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
TRACE_DIR="/tmp/fleet-coverage"
rm -rf "$TRACE_DIR"
mkdir -p "$TRACE_DIR"

# --- Target scripts ---
declare -A SCRIPTS=(
    ["fleet-env.sh"]="fleet/fleet-env.sh"
    ["fleet-build-yaml.sh"]="fleet/fleet-build-yaml.sh"
    ["build-sp.sh"]="fleet/system-prompt/build-sp.sh"
    ["fleet-send.sh"]="fleet/fleet-send.sh"
    ["fleet-inbox-read.sh"]="fleet/fleet-inbox-read.sh"
    ["wake-instance.sh"]="fleet/wake-instance.sh"
)

# --- Trace function ---
# Runs a command under xtrace, appends executed lines to the script's trace file
_trace() {
    local name="$1"; shift
    local trace_file="$TRACE_DIR/${name}.trace"
    PS4="+${name}:\${LINENO}: " bash -x "$@" >> "$TRACE_DIR/stdout" 2>>"$trace_file" || true
}

_trace_source() {
    local name="$1" script="$2"; shift 2
    local trace_file="$TRACE_DIR/${name}.trace"
    PS4="+${name}:\${LINENO}: " bash -xc "source '$script'; $*" >> "$TRACE_DIR/stdout" 2>>"$trace_file" || true
}

echo "[coverage] Exercising Ring 0+1 kernel scripts..."
echo ""

# --- Setup test environment (minimal, no bats dependency) ---
export BATS_TEST_TMPDIR="$TRACE_DIR/testenv"
mkdir -p "$BATS_TEST_TMPDIR"/{spool/inbox/{starfleet,engineer,dev}/{.processing,.consumed},handoffs,fleet-state,homes}
source "$REPO_ROOT/tests/helpers/mock_fleet_env.bash" 2>/dev/null || true

# --- fleet-env.sh ---
# Sourced library — exercise via source + --json
_trace_source "fleet-env.sh" "$REPO_ROOT/fleet/fleet-env.sh" "fleet_roles; fleet_role_field starfleet tier; fleet_roles_by_tier 0; fleet_roles_stateless; fleet_roles_stateful; fleet_bin nonexistent"
_trace "fleet-env.sh" "$REPO_ROOT/fleet/fleet-env.sh" --json

# --- fleet-build-yaml.sh ---
_trace "fleet-build-yaml.sh" "$REPO_ROOT/fleet/fleet-build-yaml.sh"
_trace "fleet-build-yaml.sh" "$REPO_ROOT/fleet/fleet-build-yaml.sh" --json
_trace "fleet-build-yaml.sh" "$REPO_ROOT/fleet/fleet-build-yaml.sh" --help
_trace "fleet-build-yaml.sh" "$REPO_ROOT/fleet/fleet-build-yaml.sh" nonexistent_profile

# --- build-sp.sh ---
SP_DIR="$REPO_ROOT/fleet/system-prompt"
mkdir -p /tmp/cov-sp-test/.claude
_trace "build-sp.sh" env BUILD_SP_DIR="$SP_DIR" BUILD_SP_SOURCES="$SP_DIR/sources" ANTHROPIC_SP="$SP_DIR/anthropic-lcars.md" FLEET_YAML="$REPO_ROOT/fleet/fleet.yaml" "$REPO_ROOT/fleet/system-prompt/build-sp.sh" starfleet "anthropic-lcars core organisation/topologie organisation/workflow protocole" /tmp/cov-sp-test
_trace "build-sp.sh" "$REPO_ROOT/fleet/system-prompt/build-sp.sh" --help
_trace "build-sp.sh" env FLEET_YAML=/nonexistent "$REPO_ROOT/fleet/system-prompt/build-sp.sh"
_trace "build-sp.sh" "$REPO_ROOT/fleet/system-prompt/build-sp.sh" "" "" ""

# --- fleet-send.sh ---
_trace "fleet-send.sh" "$REPO_ROOT/fleet/fleet-send.sh" --help
# Real send needs spool dirs — use mock env
_trace "fleet-send.sh" env FLEET_SPOOL_INBOX="$BATS_TEST_TMPDIR/spool/inbox" FLEET_INSTANCE="starfleet" "$REPO_ROOT/fleet/fleet-send.sh" engineer "coverage test" <<< "body"
_trace "fleet-send.sh" env FLEET_SPOOL_INBOX="$BATS_TEST_TMPDIR/spool/inbox" FLEET_INSTANCE="starfleet" "$REPO_ROOT/fleet/fleet-send.sh" --type ack --priority high engineer "test ack" <<< "ack body"
# Error: missing dest
_trace "fleet-send.sh" "$REPO_ROOT/fleet/fleet-send.sh"

# --- fleet-inbox-read.sh ---
_trace "fleet-inbox-read.sh" "$REPO_ROOT/fleet/fleet-inbox-read.sh" --help
# Empty inbox
_trace "fleet-inbox-read.sh" env FLEET_SPOOL_INBOX="$BATS_TEST_TMPDIR/spool/inbox" "$REPO_ROOT/fleet/fleet-inbox-read.sh" starfleet
# With a message
printf '%s\n' "---" "from: dev" "to: starfleet" "subject: test" "type: task" "priority: normal" "ref: " "date: 2026-01-01" "---" "Body here" > "$BATS_TEST_TMPDIR/spool/inbox/starfleet/20260101-000000-dev-test.md"
_trace "fleet-inbox-read.sh" env FLEET_SPOOL_INBOX="$BATS_TEST_TMPDIR/spool/inbox" "$REPO_ROOT/fleet/fleet-inbox-read.sh" starfleet
# No instance
_trace "fleet-inbox-read.sh" "$REPO_ROOT/fleet/fleet-inbox-read.sh"

# --- wake-instance.sh ---
_trace "wake-instance.sh" "$REPO_ROOT/fleet/wake-instance.sh" --help
# No pane (nominal fallback)
_trace "wake-instance.sh" "$REPO_ROOT/fleet/wake-instance.sh" dev "test wake"
# Missing arg
_trace "wake-instance.sh" "$REPO_ROOT/fleet/wake-instance.sh"

# --- Phase 2: Compute coverage ---
echo "================================================================"
echo "  COVERAGE REPORT — Ring 0+1 Kernel"
echo "================================================================"
echo ""

TOTAL_EXEC=0
TOTAL_HIT=0

for name in "fleet-env.sh" "fleet-build-yaml.sh" "build-sp.sh" "fleet-send.sh" "fleet-inbox-read.sh" "wake-instance.sh"; do
    target="${SCRIPTS[$name]}"
    script="$REPO_ROOT/$target"
    trace_file="$TRACE_DIR/${name}.trace"

    # Count executable lines (after END HEADER, non-comment, non-empty, non-structural)
    exec_lines=$(sed -n '/END HEADER/,$p' "$script" | \
        grep -v '^\s*#' | grep -v '^\s*$' | grep -v '^\s*;;$' | \
        grep -v '^\s*esac$' | grep -v '^\s*fi$' | grep -v '^\s*done$' | \
        grep -v '^\s*else$' | grep -v '^\s*then$' | grep -v '^\s*do$' | \
        grep -v '^\s*{$' | grep -v '^\s*}$' | wc -l)

    # Count unique lines hit
    if [[ -f "$trace_file" ]]; then
        hit_lines=$(grep "^+${name}:" "$trace_file" | \
            sed "s/^+${name}:\([0-9]*\):.*/\1/" | sort -un | wc -l)
    else
        hit_lines=0
    fi

    if [[ $exec_lines -gt 0 ]]; then
        pct=$((hit_lines * 100 / exec_lines))
        [[ $pct -gt 100 ]] && pct=100
    else
        pct=0
    fi

    TOTAL_EXEC=$((TOTAL_EXEC + exec_lines))
    TOTAL_HIT=$((TOTAL_HIT + hit_lines))

    # Color
    if [[ $pct -ge 80 ]]; then color="\033[32m"
    elif [[ $pct -ge 50 ]]; then color="\033[33m"
    else color="\033[31m"; fi

    printf "  %-40s ${color}%3d%%\033[0m  (%d/%d lines)\n" "$name" "$pct" "$hit_lines" "$exec_lines"
done

echo ""
if [[ $TOTAL_EXEC -gt 0 ]]; then
    TOTAL_PCT=$((TOTAL_HIT * 100 / TOTAL_EXEC))
    [[ $TOTAL_PCT -gt 100 ]] && TOTAL_PCT=100
    printf "  %-40s %3d%%  (%d/%d lines)\n" "TOTAL" "$TOTAL_PCT" "$TOTAL_HIT" "$TOTAL_EXEC"
fi
echo ""
echo "================================================================"
echo "  Trace data: $TRACE_DIR/"
echo "================================================================"
