#!/usr/bin/env bash
# SOURCE: test/gate-r-core-comm-inc3c1.sh
# AUTHOR: starfleet (consolidation salvage cow-boy)
# STARDATE: 2026.146
# STATUS: RETIRE / ARCHIVE (DR-032) — court-circuite (exit non-zero) ; NON execute par mix gate. Le « exit 0 ssi… » ci-dessous est HISTORIQUE (cf. « GATE RETIRE » plus bas).
# gate-r-core-comm-inc3c1.sh — R-CORE.comm inc3c.1 (pont stdio→HTTP, pur). exit 0 ssi le pont
# `bin/fleet_mcp_stdio_bridge.py` forwarde get_task (IN) / submit_result (OUT) d'un client MCP stdio
# (pilote par Port, PAS claude) vers le VRAI fleet_mcp central (PodTools :http + TaskQueue). Nonce
# depose QUE dans la TaskQueue centrale → ressort via get_task a travers le pont → submit_result le
# renvoie au central. Valide le transport-shim (etat CENTRAL via stdio) avant l'e2e pod (inc3c.2).
# ── GATE RETIRE (Z7 migration 2026-07-13) ─────────────────────────────────────
# Ciblait bridge_stdio_http_test.exs, SUPPRIME avec le transport HTTP loopback (pre-migration).
# Decouvert stale pendant la migration : il ne pouvait plus etre vert depuis des
# semaines. Conserve comme ARCHIVE d'increment ; exit 3 EXPLICITE — jamais un
# faux-vert silencieux (famille F-C166/167). Le re-cibler = decision produit.
echo "GATE RETIRE — ciblait un test supprime avec le transport HTTP (cf. header). Archive, exit 3." >&2
exit 3

set -uo pipefail
HERE="$(cd "$(dirname "$0")" && pwd)"; RT="$(cd "$HERE/.." && pwd)"
echo "== Gate R-CORE.comm inc3c.1 — pont stdio→HTTP (forward vers fleet_mcp central) =="
cd "$RT" && mix test apps/fleet_mcp/test/bridge_stdio_http_test.exs
RC=$?
echo "---"
if [ "$RC" -eq 0 ]; then
  echo "GATE R-CORE.comm inc3c.1 : exit 0 — pont forwarde get_task/submit_result au central (pur Elixir+py)"
else
  echo "GATE R-CORE.comm inc3c.1 : exit 1 (rc=$RC)"
fi
exit "$RC"
