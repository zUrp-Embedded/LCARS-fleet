#!/bin/bash
# SOURCE: test.sh
# AUTHOR: STARFLEET
# STARDATE: 2026.110
# STATUS: PROVEN
# RESOURCE: claude_token
# R-05a fix : manifest d assertions explicite. Le relais verifie
# nommement T1 benign (allow path) et T2 BLOCKME (deny path + is_error).

set -u
HARNESS_DIR=/home/projects/LCARS/PoC/PoC-B1-readiness
PY="$HARNESS_DIR/.venv/bin/python"
SCRIPT="$HARNESS_DIR/probe_can_use_tool.py"

if [ ! -x "$PY" ] || [ ! -f "$SCRIPT" ]; then
  echo "[FAIL] B1b harness absent"
  exit 1
fi

OUT=$("$PY" "$SCRIPT" 2>&1)
RC=$?

# R-05a manifest : assertions nommees par scenario
EXPECTED_ASSERTIONS=(
  "T1 benign allowed"
  "T2 SECRET denied"
)
MISSING=()
for a in "${EXPECTED_ASSERTIONS[@]}"; do
  if ! echo "$OUT" | grep -qE "\[PASS\] ${a}"; then
    MISSING+=("$a")
  fi
done

if [ ${#MISSING[@]} -gt 0 ]; then
  echo "[FAIL] B1b manifest : assertions manquantes ${MISSING[*]}"
  exit 1
fi

if echo "$OUT" | grep -qE "^\[FAIL\]|^  \[FAIL\]"; then
  echo "[FAIL] B1b remonte des FAIL"
  echo "$OUT" | grep "FAIL" | sed 's/^/    /'
  exit 1
fi

echo "[PASS] can-use-tool-deny (manifest 2/2 : allow path + deny path is_error)"
exit 0
