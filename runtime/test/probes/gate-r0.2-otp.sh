#!/usr/bin/env bash
# SOURCE: runtime/test/probes/gate-r0.2-otp.sh
# AUTHOR: starfleet (consolidation salvage cow-boy)
# STARDATE: 2026.247
# STATUS: MANUAL PROBE — standalone, outside `mix gate` (non-CI). The gate's chain is declared in
#         mix.exs (alias `gate:`); do not re-list it here, it drifts.
# gate-r0.2-otp.sh — R0.2 (kernel mechanic: OTP supervisor). exit 0 iff the app compiles (a buildable
# BEAM lifecycle = a buildable supervision tree). There is no "systemd daemon active" check any more:
# the fleet is launched per-human through bin/fleet (the human-launches model, ADR-E), not an
# always-on system service.
set -uo pipefail          # PAS -e : meme raison — la sonde mesure plusieurs points et rend un
                          # bilan, pas le verdict de sa premiere commande.
RT="$(cd "$(dirname "$0")/../.." && pwd)"
FAIL=0
echo "== Gate R0.2 — OTP supervisor =="
if (cd "$RT" && timeout 180 mix compile >/dev/null 2>&1); then
  echo "PASS COMPILE the app compiles (supervision tree buildable)"
else
  echo "FAIL COMPILE the app does not compile"; FAIL=1
fi
echo "---"; [ "$FAIL" -eq 0 ] && echo "GATE R0.2: exit 0 — OTP supervisor holds" || echo "GATE R0.2: exit 1"; exit "$FAIL"
