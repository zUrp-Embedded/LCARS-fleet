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
