#!/bin/bash
# SOURCE: run-checkbashisms.sh
# AUTHOR: LORDZURP
# STARDATE: 2026.091
# STATUS: OPERATIONAL
#
# run-checkbashisms.sh — Portability check via checkbashisms (devscripts)
#
# Second pair of eyes after shellcheck. Catches bash-specific constructs
# that may break portability. Not a replacement — a complement.
#
# EXIT: 0 if clean, 1 if findings.

set -uo pipefail

REPO_ROOT="$(git -C "$(dirname "$0")" rev-parse --show-toplevel)"
FLEET_DIR="$REPO_ROOT/fleet"

FAIL=0
COUNT=0
FINDINGS=0

for script in "$FLEET_DIR"/*.sh; do
    [[ -f "$script" ]] || continue
    COUNT=$((COUNT + 1))
    exit_code=0
    output=$(checkbashisms "$script" 2>&1) || exit_code=$?
    # exit 4 = "could not find any possible bashisms" — not a finding
    if [[ $exit_code -ne 0 && $exit_code -ne 4 ]]; then
        echo "$output"
        FINDINGS=$((FINDINGS + 1))
        FAIL=1
    fi
done

echo "[checkbashisms] $COUNT scripts checked, $FINDINGS with findings"
exit $FAIL
