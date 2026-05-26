#!/usr/bin/env bash
# SOURCE: test/gate-r0.2-otp.sh
# AUTHOR: starfleet (consolidation salvage cow-boy)
# STARDATE: 2026.146
# STATUS: salvage v2-functional
# gate-r0.2-otp.sh — R0.2 (Ring 0, OTP supervisor). exit 0 ssi l'umbrella compile (lifecycle BEAM
# buildable) ET le daemon supervisé tourne (lcars-fleet.service active = supervision tree vivant en prod).
set -uo pipefail
RT="$(cd "$(dirname "$0")/.." && pwd)"
FAIL=0
echo "== Gate R0.2 — OTP supervisor =="
if (cd "$RT" && timeout 180 mix compile >/dev/null 2>&1); then
  echo "PASS COMPILE umbrella compile (supervision tree buildable)"
else
  echo "FAIL COMPILE umbrella ne compile pas"; FAIL=1
fi
if systemctl is-active --quiet lcars-fleet.service 2>/dev/null; then
  echo "PASS DAEMON  lcars-fleet.service active (supervision OTP vivante depuis $(systemctl show -p ActiveEnterTimestamp --value lcars-fleet.service 2>/dev/null))"
else
  echo "FAIL DAEMON  lcars-fleet.service inactive"; FAIL=1
fi
echo "---"; [ "$FAIL" -eq 0 ] && echo "GATE R0.2 : exit 0 — OTP supervisor porte" || echo "GATE R0.2 : exit 1"; exit "$FAIL"
