#!/usr/bin/env bash
# SOURCE: test/gate-r-core-comm-inc3b2.sh
# AUTHOR: starfleet (consolidation salvage cow-boy)
# STARDATE: 2026.146
# STATUS: RETIRE / ARCHIVE (DR-032) — court-circuite (exit non-zero) ; NON execute par mix gate. Le « exit 0 ssi… » ci-dessous est HISTORIQUE (cf. « GATE RETIRE » plus bas).
# gate-r-core-comm-inc3b2.sh — R-CORE.comm inc3b.2 (transport HTTP-SSE reel). exit 0 ssi
# Fleet.MCP.PodTools demarre en transport :sse (Cowboy, port OS-assigne) + un client MCP
# (ExMCP.Client) round-trip get_task (IN) / submit_result (OUT) sur le VRAI fil HTTP : SSE etabli,
# POST pour les requetes. PUR Elixir (client+serveur BEAM, pas de claude) — c'est le wire que le
# pod reel empruntera en inc3b.3 (bwrap --share-net → http://localhost:PORT/mcp).
# ── GATE RETIRE (Z7 migration 2026-07-13) ─────────────────────────────────────
# Ciblait pod_tools_http_test.exs, SUPPRIME avec le transport HTTP loopback (pre-migration).
# Decouvert stale pendant la migration : il ne pouvait plus etre vert depuis des
# semaines. Conserve comme ARCHIVE d'increment ; exit 3 EXPLICITE — jamais un
# faux-vert silencieux (famille F-C166/167). Le re-cibler = decision produit.
echo "GATE RETIRE — ciblait un test supprime avec le transport HTTP (cf. header). Archive, exit 3." >&2
exit 3

set -uo pipefail
HERE="$(cd "$(dirname "$0")" && pwd)"; RT="$(cd "$HERE/.." && pwd)"
echo "== Gate R-CORE.comm inc3b.2 — transport HTTP-SSE (ExMCP.Client <-> PodTools/Cowboy) =="
cd "$RT" && mix test apps/fleet_mcp/test/pod_tools_http_test.exs
RC=$?
echo "---"
if [ "$RC" -eq 0 ]; then
  echo "GATE R-CORE.comm inc3b.2 : exit 0 — transport HTTP-SSE round-trip nonce (pur Elixir)"
else
  echo "GATE R-CORE.comm inc3b.2 : exit 1 (rc=$RC)"
fi
exit "$RC"
