#!/usr/bin/env bash
# SOURCE: test/gate-r-core-comm-inc3b1.sh
# AUTHOR: starfleet (consolidation salvage cow-boy)
# STARDATE: 2026.146
# STATUS: MANUAL PROBE v2 — standalone, outside mix gate (non-CI; mix gate = ExUnit + shell_gate
#         [python+bats] + contracts.check + dialyzer).
# gate-r-core-comm-inc3b1.sh — R-CORE.comm inc3b.1 (the MCP tool layer, pure Elixir). exit 0 iff
# Fleet.MCP.PodTools (use ExMCP.Server + deftool get_work_item/submit_result) round-trips against the
# in-memory Fleet.MCP.TaskQueue: get_work_item POPs a nonce task (IN channel), submit_result STOREs it
# (OUT channel), the queue empties → {"done":true}. PURE Elixir — no claude, no transport. This is the
# REAL tool layer (the ex_mcp SDK), as opposed to the python fixture.
# NB: this is a thin wrapper around `mix test test/pod_tools_test.exs`, which `mix gate` already runs.
# It exists to be invokable alone while working on the tool layer, not to add coverage.
set -uo pipefail
HERE="$(cd "$(dirname "$0")" && pwd)"; RT="$(cd "$HERE/.." && pwd)"
echo "== Gate R-CORE.comm inc3b.1 — tool layer ExMCP.Server (get_work_item IN / submit_result OUT) =="
cd "$RT" && mix test test/pod_tools_test.exs
RC=$?
echo "---"
if [ "$RC" -eq 0 ]; then
  echo "GATE R-CORE.comm inc3b.1: exit 0 — tool layer round-trips the nonce (pure Elixir)"
else
  echo "GATE R-CORE.comm inc3b.1: exit 1 (rc=$RC)"
fi
exit "$RC"
