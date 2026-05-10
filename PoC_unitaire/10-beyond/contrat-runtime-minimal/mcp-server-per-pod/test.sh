#!/bin/bash
# SOURCE: test.sh
# AUTHOR: STARFLEET
# STARDATE: 2026.110
# STATUS: PROVEN
# RESOURCE: claude_token
# R-05a fix (consultant 2026-04-20) : manifest d assertions explicite.
# Detecte un harness amont renomme, reduit, ou stubbe.

set -u
HARNESS_DIR=/home/projects/LCARS/PoC/PoC-03-mcp-in-process
PY="$HARNESS_DIR/.venv/bin/python"
SCRIPT="$HARNESS_DIR/test_mcp_in_process.py"

if [ ! -x "$PY" ] || [ ! -f "$SCRIPT" ]; then
  echo "[FAIL] PoC-03 harness absent (PY=$PY SCRIPT=$SCRIPT)"
  exit 1
fi

OUT=$("$PY" "$SCRIPT" 2>&1)
RC=$?

# R-05a manifest : les 5 assertions nommees PoC-03
EXPECTED_ASSERTIONS=(
  "T1.tool-invoked"
  "T2.same-pid"
  "T3.no-mcp-fork"
  "T4.tool-latency"
  "T5.payload-roundtrip"
)
MISSING=()
for a in "${EXPECTED_ASSERTIONS[@]}"; do
  if ! echo "$OUT" | grep -qE "^\[PASS\] ${a}"; then
    MISSING+=("$a")
  fi
done

if [ ${#MISSING[@]} -gt 0 ]; then
  echo "[FAIL] PoC-03 manifest : assertions manquantes ${MISSING[*]}"
  echo "    harness rc=$RC"
  exit 1
fi

# Zero FAIL attendu
if echo "$OUT" | grep -qE "^\[FAIL\]|^FAIL "; then
  echo "[FAIL] PoC-03 remonte des FAIL"
  echo "$OUT" | grep -E "^\[FAIL\]|^FAIL " | sed 's/^/    /'
  exit 1
fi

echo "[PASS] mcp-server-per-pod (manifest 5/5 assertions PoC-03 presentes)"
exit 0
