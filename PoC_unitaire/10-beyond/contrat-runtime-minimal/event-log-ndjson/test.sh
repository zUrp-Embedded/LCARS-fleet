#!/bin/bash
# SOURCE: test.sh
# AUTHOR: STARFLEET
# STARDATE: 2026.110
# STATUS: PARTIEL (primitives couvertes, schema canonique non)
# R-05a fix : manifest d assertions PoC-04 explicite.

set -u
HARNESS=/home/projects/LCARS/PoC/PoC-04-ndjson-logrotate/test_ndjson.sh

if [ ! -x "$HARNESS" ]; then
  echo "[FAIL] PoC-04 harness absent"
  exit 1
fi

OUT=$("$HARNESS" 2>&1)
RC=$?

# R-05a manifest : 4 assertions nommees PoC-04
EXPECTED_ASSERTIONS=(
  "T1.integrity"
  "T2.postrotate-meta"
  "T3.atomic-lines"
  "T4.reopen-after-rotate"
)
MISSING=()
for a in "${EXPECTED_ASSERTIONS[@]}"; do
  if ! echo "$OUT" | grep -qE "^\[PASS\] ${a}"; then
    MISSING+=("$a")
  fi
done

if [ ${#MISSING[@]} -gt 0 ]; then
  echo "[FAIL] PoC-04 manifest : assertions manquantes ${MISSING[*]}"
  exit 1
fi

if echo "$OUT" | grep -qE "^\[FAIL\]"; then
  echo "[FAIL] PoC-04 remonte des FAIL"
  echo "$OUT" | grep "^\[FAIL\]" | sed 's/^/    /'
  exit 1
fi

echo "[PASS] event-log-ndjson-primitives (manifest 4/4 PoC-04 : integrity + rotation + reopen)"

# Gaps a couvrir ailleurs (unite reste PARTIEL par ces [GAP])
echo "[GAP] event-schema-canonique (champs obligatoires seq/ts/nodeId/kind, taxonomie kind) - a miroir separement"
echo "[GAP] rotation logrotate config reelle (/etc/logrotate.d/fleet-pilot) - a tester en B2"
echo "[GAP] bump apiVersion = nouveau fichier - contrat de versioning stream"

exit 0
