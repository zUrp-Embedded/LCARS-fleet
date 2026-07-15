#!/usr/bin/env bash
# SOURCE: test/gate-r-core-comm-inc3b1.sh
# AUTHOR: starfleet (consolidation salvage cow-boy)
# STARDATE: 2026.146
# STATUS: SONDE MANUELLE v2 (DR-032) — standalone, hors mix gate (non-CI ; mix gate = ExUnit + shell_gate[python+bats] + contracts.check + dialyzer).
# gate-r-core-comm-inc3b1.sh — R-CORE.comm inc3b.1 (couche tool MCP, pur Elixir). exit 0 ssi
# Fleet.MCP.PodTools (use ExMCP.Server + deftool get_task/submit_result) round-trip avec la file
# in-memory Fleet.MCP.TaskQueue : get_task POP une tâche nonce (canal IN), submit_result la STORE
# (canal OUT), file vidée → {"done":true}. PUR Elixir (pas de claude, pas de transport) — c'est la
# couche tool RÉELLE (SDK ex_mcp) qui remplacera la fixture python ; inc3b.2 ajoute le transport HTTP-SSE.
set -uo pipefail
HERE="$(cd "$(dirname "$0")" && pwd)"; RT="$(cd "$HERE/.." && pwd)"
echo "== Gate R-CORE.comm inc3b.1 — tool layer ExMCP.Server (get_task IN / submit_result OUT) =="
cd "$RT" && mix test test/pod_tools_test.exs
RC=$?
echo "---"
if [ "$RC" -eq 0 ]; then
  echo "GATE R-CORE.comm inc3b.1 : exit 0 — couche tool round-trip nonce (pur Elixir)"
else
  echo "GATE R-CORE.comm inc3b.1 : exit 1 (rc=$RC)"
fi
exit "$RC"
