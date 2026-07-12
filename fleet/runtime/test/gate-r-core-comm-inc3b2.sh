#!/usr/bin/env bash
# SOURCE: test/gate-r-core-comm-inc3b2.sh
# AUTHOR: starfleet (consolidation salvage cow-boy)
# STARDATE: 2026.146
# STATUS: salvage v2-functional
# gate-r-core-comm-inc3b2.sh — R-CORE.comm inc3b.2 (transport HTTP-SSE réel). exit 0 ssi
# Fleet.MCP.PodTools démarré en transport :sse (Cowboy, port OS-assigné) + un client MCP
# (ExMCP.Client) round-trip get_task (IN) / submit_result (OUT) sur le VRAI fil HTTP : SSE établi,
# POST pour les requêtes. PUR Elixir (client+serveur BEAM, pas de claude) — c'est le wire que le
# pod réel empruntera en inc3b.3 (bwrap --share-net → http://localhost:PORT/mcp).
# ── GATE RETIRÉ (Z7 migration 2026-07-13) ─────────────────────────────────────
# Ciblait pod_tools_http_test.exs, SUPPRIMÉ avec le transport HTTP loopback (pré-migration).
# Découvert stale pendant la migration : il ne pouvait plus être vert depuis des
# semaines. Conservé comme ARCHIVE d'incrément ; exit 3 EXPLICITE — jamais un
# faux-vert silencieux (famille F-C166/167). Le re-cibler = décision produit.
echo "GATE RETIRÉ — ciblait un test supprimé avec le transport HTTP (cf. header). Archive, exit 3." >&2
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
