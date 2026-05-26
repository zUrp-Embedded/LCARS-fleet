#!/usr/bin/env bash
# SOURCE: test/gate-r4-mcp-boot.sh
# AUTHOR: starfleet (consolidation salvage cow-boy)
# STARDATE: 2026.146
# STATUS: salvage v2-functional
# gate-r4-mcp-boot.sh — R-CORE.comm Ring 4 (fleet_mcp central bootable). exit 0 ssi le superviseur
# fleet_mcp, démarré avec `:pod_facing_port` configuré (host-side), boote le serveur MCP pod-facing
# CENTRAL (PodTools :http + TaskQueue) sur ce port, et qu'un client MCP round-trip get_task/submit_result.
# = le central que les pods atteignent en PROD (via le pont stdio → http://localhost:<port>/mcp).
# PUR Elixir (pas de claude). --no-start : on ne laisse pas l'app fleet_mcp auto-démarrer son
# superviseur (sinon conflit de nom) ; on le démarre manuellement avec le port.
set -uo pipefail
HERE="$(cd "$(dirname "$0")" && pwd)"; RT="$(cd "$HERE/.." && pwd)"

cat > "$RT/.gate-r4.exs" <<'EXS'
{:ok, _} = Application.ensure_all_started(:fleet_event_router)

# Boot manuel du superviseur fleet_mcp AVEC le port pod-facing (host-side).
{:ok, _sup} =
  Fleet.MCP.Supervisor.start_link(
    boot_environment: :host,
    pod_facing_port: 0,
    pod_facing_ranch_ref: :gate_r4
  )

port = :ranch.get_port(:gate_r4)
true = is_integer(port) and port > 0
IO.puts("boot: fleet_mcp central pod-facing sur localhost:#{port} (PodTools :http + TaskQueue supervisés)")

# TaskQueue est démarrée par le superviseur (enfant) → seed une tâche.
nonce = "r4-#{System.system_time(:second)}-#{:rand.uniform(1_000_000)}"
Fleet.MCP.TaskQueue.push(%{"id" => 1, "ask" => nonce})

# Un client MCP réel round-trip sur le central booté.
{:ok, client} = ExMCP.Client.start_link(transport: :http, url: "http://localhost:#{port}/mcp")
{:ok, r1} = ExMCP.Client.call_tool(client, "get_task", %{})
content = r1["content"] || r1[:content]
# content-blocks ExMCP : clés atom (%{text: ...}) ou string selon le chemin → on gère les deux.
t1 = case hd(content) do
  %{text: t} -> t
  %{"text" => t} -> t
end
{:ok, %{"done" => false, "task" => %{"ask" => ask}}} = Jason.decode(t1)
true = ask == nonce

{:ok, _r2} = ExMCP.Client.call_tool(client, "submit_result", %{"payload" => %{"id" => 1, "answer" => nonce}})
[%{"answer" => ^nonce}] = Fleet.MCP.TaskQueue.results()

IO.puts("PASS  central booté par le superviseur + round-trip get_task/submit_result OK (nonce #{nonce})")
System.halt(0)
EXS

echo "== Gate R-CORE.comm Ring 4 — fleet_mcp central bootable (PodTools :http + TaskQueue supervisés) =="
cd "$RT" && timeout 120 mix run --no-start ".gate-r4.exs"
RC=$?
rm -f "$RT/.gate-r4.exs"
echo "---"
if [ "$RC" -eq 0 ]; then
  echo "GATE R-CORE.comm Ring 4 : exit 0 — central pod-facing bootable + servant (config :pod_facing_port)"
else
  echo "GATE R-CORE.comm Ring 4 : exit 1 (rc=$RC)"
fi
exit "$RC"
