#!/usr/bin/env bash
# SOURCE: test/gate-r0.2-otp.sh
# AUTHOR: starfleet (consolidation salvage cow-boy)
# STARDATE: 2026.146
# STATUS: salvage v2-functional
# gate-r0.2-otp.sh — R0.2 (Ring 0, OTP supervisor). exit 0 ssi l'umbrella compile (lifecycle BEAM
# buildable = supervision tree buildable). NB : plus de check « daemon systemd actif » — la fleet est
# lancée per-humain via bin/fleet_v2 (modèle humain-lance, ADR-E), pas un service système toujours-on.
set -uo pipefail
RT="$(cd "$(dirname "$0")/.." && pwd)"
FAIL=0
echo "== Gate R0.2 — OTP supervisor =="
if (cd "$RT" && timeout 180 mix compile >/dev/null 2>&1); then
  echo "PASS COMPILE umbrella compile (supervision tree buildable)"
else
  echo "FAIL COMPILE umbrella ne compile pas"; FAIL=1
fi
echo "---"; [ "$FAIL" -eq 0 ] && echo "GATE R0.2 : exit 0 — OTP supervisor porte" || echo "GATE R0.2 : exit 1"; exit "$FAIL"
