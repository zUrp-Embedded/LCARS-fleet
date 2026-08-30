#!/usr/bin/env bash
# SOURCE: fleet/test/probes/_archived/gate-r4-mcp-boot.sh
# AUTHOR: starfleet (consolidation salvage cow-boy)
# STARDATE: 2026.146
# STATUS: RETIRE / ARCHIVE (DR-032) — court-circuite (exit non-zero) ; NON execute par mix gate. Le « exit 0 ssi… » ci-dessous est HISTORIQUE (reecrit F175 puis retire, cf. « GATE RETIRE » plus bas).
# gate-r4-mcp-boot.sh — R-CORE.comm (fleet_mcp central bootable). exit 0 ssi le superviseur
# fleet_mcp, demarre avec `:pod_facing_port` configure (host-side), boote le serveur MCP pod-facing
# CENTRAL (PodTools :http) sur ce port, et qu'un client MCP round-trip get_task/submit_result contre
# le broker per-pod `Fleet.TaskQueue`. = le central que les pods atteignent en PROD (via le pont stdio
# → http://localhost:<port>/mcp). PUR Elixir (pas de claude).
#
# Reecriture Fable F175 : l'ancien modele global `Fleet.MCP.TaskQueue.push/results` (substrat
# MCP-channel pre-ADR-G) a ete retire. Modele courant = per-pod : `Fleet.TaskQueue.enqueue(pod_id, …)`,
# le pod PULL via get_task (`_lcars_pod_id`), PUSH via submit_result ; mandat consomme → get_for_pod
# rend {:error,:no_task}. Le broker vit dans l'app fleet_task_queue (ensure_all_started).
# --no-start : on demarre le superviseur fleet_mcp MANUELLEMENT avec le port (sinon conflit de nom).
set -uo pipefail

# ── GATE SUPERSEDED (audit lot 6, 2026-07-12) — script MORT sur l'app unique ──
# Trois ruptures post-collapse/vocab le tuent au premier pas :
#   1. `Application.ensure_all_started(:fleet_event_router)` / `(:fleet_task_queue)` → MatchError :
#      les apps OTP `:fleet_*` n'existent plus (app unique `:lcars_fleet` ; les atoms `:fleet_<dom>`
#      ne survivent QUE comme cles de config, decision D-07 migration).
#   2. Tool "get_task" perime — le vocab courant est `get_work_item`.
#   3. Le transport HTTP pod-facing (PodTools :http, `:pod_facing_port`) est RETIRE — remplace par
#      la socket AF_UNIX per-pod (PodSocketAcceptor/PodSocketSupervisor).
# NE PAS reparer : une reecriture fidele = re-implementer test/pod_socket_test.exs, qui EXISTE et
# prouve le round-trip get_work_item/submit_result sur le canal per-pod reel.
# PREUVE VIVANTE : test/pod_socket_test.exs (mix test test/pod_socket_test.exs).
# Corps historique conserve ci-dessous (archive) ; exit 2 EXPLICITE — jamais un faux-vert silencieux.
echo "SUPERSEDED — central HTTP + get_task morts sur l'app unique. Preuve vivante : test/pod_socket_test.exs (mix test). exit 2." >&2
exit 2

HERE="$(cd "$(dirname "$0")" && pwd)"; RT="$(cd "$HERE/.." && pwd)"

cat > "$RT/.gate-r4.exs" <<'EXS'
{:ok, _} = Application.ensure_all_started(:fleet_event_router)
# Le broker Fleet.TaskQueue.Server est un enfant de l'app fleet_task_queue (per-pod, correle pod_id).
{:ok, _} = Application.ensure_all_started(:fleet_task_queue)

# Boot manuel du superviseur fleet_mcp AVEC le port pod-facing (host-side).
{:ok, _sup} =
  Fleet.MCP.Supervisor.start_link(
    boot_environment: :host,
    pod_facing_port: 0,
    pod_facing_ranch_ref: :gate_r4
  )

port = :ranch.get_port(:gate_r4)
true = is_integer(port) and port > 0
IO.puts("boot: fleet_mcp central pod-facing sur localhost:#{port} (PodTools :http)")

# Seed un mandat POUR un pod identifie (modele per-pod). brief = la charge a round-tripper.
pod_id = "gate-r4-pod-#{System.system_time(:second)}-#{:rand.uniform(1_000_000)}"
nonce = "r4-#{System.system_time(:second)}-#{:rand.uniform(1_000_000)}"
{:ok, _task} = Fleet.TaskQueue.enqueue(pod_id, %{"brief" => nonce, "role" => "engineer", "ticket_id" => "r4-ticket"})

# Un client MCP reel round-trip sur le central boote, en s'identifiant comme le pod (_lcars_pod_id).
{:ok, client} = ExMCP.Client.start_link(transport: :http, url: "http://localhost:#{port}/mcp")
{:ok, r1} = ExMCP.Client.call_tool(client, "get_task", %{"_lcars_pod_id" => pod_id})
content = r1["content"] || r1[:content]
# content-blocks ExMCP : cles atom (%{text: ...}) ou string selon le chemin → on gere les deux.
t1 =
  case hd(content) do
    %{text: t} -> t
    %{"text" => t} -> t
  end

{:ok, %{"done" => false, "task" => %{"brief" => brief, "task_id" => tid}}} = Jason.decode(t1)
true = brief == nonce

{:ok, _r2} =
  ExMCP.Client.call_tool(client, "submit_result", %{
    "_lcars_pod_id" => pod_id,
    "payload" => %{"task_id" => tid, "status" => "ok", "result" => %{"answer" => nonce}}
  })

# Plus de `results()` global : le mandat consomme → aucun mandat actif pour ce pod.
{:error, :no_task} = Fleet.TaskQueue.get_for_pod(pod_id)

IO.puts("PASS  central boote + round-trip get_task/submit_result per-pod OK (pod #{pod_id}, nonce #{nonce})")
System.halt(0)
EXS

echo "== Gate R-CORE.comm — fleet_mcp central bootable (PodTools :http + broker per-pod) =="
cd "$RT" && timeout 120 mix run --no-start ".gate-r4.exs"
RC=$?
rm -f "$RT/.gate-r4.exs"
echo "---"
if [ "$RC" -eq 0 ]; then
  echo "GATE R-CORE.comm : exit 0 — central pod-facing bootable + servant (config :pod_facing_port)"
else
  echo "GATE R-CORE.comm : exit 1 (rc=$RC)"
fi
exit "$RC"
