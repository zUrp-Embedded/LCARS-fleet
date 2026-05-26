#!/usr/bin/env bash
# SOURCE: test/gate-r-core-comm-2.2.sh
# AUTHOR: starfleet (consolidation salvage cow-boy)
# STARDATE: 2026.146
# STATUS: salvage v2-functional
# gate-r-core-comm-2.2.sh — R-CORE.comm brick 2.2 (completion EVENT-DRIVEN e2e, via le vrai cycle Pod).
# exit 0 ssi : un VRAI pod claude lancé par `Fleet.Spawner.Pod` (PortBackend) spawne le pont stdio
# (provisionné par pod.ex depuis :mcp_server_spec, alwaysLoad forcé), PULL sa tâche via get_task — le
# pont forwarde au fleet_mcp central HTTP — exécute, soumet via submit_result → le central broadcaste
# `pod.result_submitted` sur le Bus → `pod.ex` (souscrit) extrait le résultat → émet `pod.completed`
# → arrêt :normal. PREUVE : (1) le pod GenServer s'arrête :normal (completion event-driven) ET (2) le
# nonce (UNIQUEMENT dans la TaskQueue centrale, absent du brief) est dans le résultat central.
# Remplace inc3a (fixture fichier, mode retiré) : chaîne PROD complète, un seul mécanisme (Iron Law).
# Bin+pont+launchers hors /home,/tmp (bwrap tmpfs).
set -uo pipefail
HERE="$(cd "$(dirname "$0")" && pwd)"; RT="$(cd "$HERE/.." && pwd)"; BIN="$RT/bin"
WORK="$(mktemp -d)"
BINV="$(mktemp -d -p /var/tmp lcars-gate-2.2.XXXXXX)"
cp "$BIN/bwrap_launch.sh" "$BIN/claude_launch.sh" "$BIN/fleet_mcp_stdio_bridge.py" "$BINV/"
trap 'pkill -f "$WORK" 2>/dev/null; [ "${KEEP:-0}" = 1 ] && echo "KEEP $WORK $BINV" || rm -rf "$WORK" "$BINV"' EXIT
mkdir -p "$WORK/pods" "$WORK/state" "$WORK/coffre/engineer" "$WORK/mirror" "$WORK/sp"
printf '# Engineer SP base\n' > "$WORK/sp/engineer-role.md"

python3 - "$WORK/coffre/engineer" <<'PY'
import json, sys, os
d = json.load(open('/home/starfleet/.claude/.credentials.json'))['claudeAiOauth']
b = sys.argv[1]
# Vulcan #6 : single-file coffre.json (atomicité garantie).
coffre = {
    'refresh_token': d['refreshToken'],
    'access_token': d['accessToken'],
    'scopes': ' '.join(d.get('scopes', [])),
    'expires_at': d.get('expiresAt', 9999999999999),
}
open(os.path.join(b, 'coffre.json'), 'w').write(json.dumps(coffre, indent=2))
PY

NONCE="pong-2.2-$(date +%s)-$RANDOM"

cat > "$WORK/run.exs" <<EXS
Process.flag(:trap_exit, true)
# Central fleet_mcp (PodTools :http + TaskQueue) — host-side, état partagé.
Application.put_env(:fleet_mcp, :boot_environment, :host)
{:ok, _} = Application.ensure_all_started(:fleet_mcp)
{:ok, _q} = Fleet.MCP.TaskQueue.start_link([])
ref = :gate22_srv
{:ok, _http} = Fleet.MCP.PodTools.start_link(transport: :http, port: 0, ranch_ref: ref)
mcp_port = :ranch.get_port(ref)

# fleet_spawner (Spawner.Pod) config.
Application.put_env(:fleet_spawner, :pod_dir_root, "$WORK/pods")
Application.put_env(:fleet_spawner, :state_fs_root, "$WORK/state")
Application.put_env(:fleet_spawner, :launch_backend, Fleet.Spawner.LaunchBackend.PortBackend)
Application.put_env(:fleet_spawner, :bwrap_launch_path, "$BINV/bwrap_launch.sh")
Application.put_env(:fleet_spawner, :claude_launch_path, "$BINV/claude_launch.sh")
# Spec serveur MCP = le PONT stdio → central HTTP (pod.ex force alwaysLoad). UN mécanisme paramétré.
Application.put_env(:fleet_spawner, :mcp_server_spec, %{
  "command" => "python3",
  "args" => ["$BINV/fleet_mcp_stdio_bridge.py"],
  "env" => %{"LCARS_FLEET_MCP_URL" => "http://localhost:#{mcp_port}/mcp"}
})
Application.put_env(:fleet_credentials, :creds_root, "$WORK/coffre")
Application.put_env(:fleet_spbuilder, :sp_role_root, "$WORK/sp")

{:ok, _apps} = Application.ensure_all_started(:fleet_spawner)
case Registry.start_link(keys: :unique, name: Fleet.Spawner.Registry) do
  {:ok, _} -> :ok
  {:error, {:already_started, _}} -> :ok
end

# Le nonce vit UNIQUEMENT dans la TaskQueue centrale (jamais dans le brief).
Fleet.MCP.TaskQueue.push(%{"id" => 1, "ask" => "Reponds EXACTEMENT et UNIQUEMENT le mot : $NONCE"})

cap = %Fleet.CapProfile{
  api_version: "lcars/v2.5", kind: "CapabilityProfile",
  metadata: %{"name" => "engineer", "containment" => "bwrap"},
  spec: %{
    "systemPrompt" => "engineer-role.md",
    "scope" => %{"allowedTools" => ["mcp__fleet__get_task", "mcp__fleet__submit_result"], "disallowedTools" => ["WebSearch", "Bash", "Write", "Edit"], "git_ops_denied" => []},
    "knowledge" => %{"skills" => []},
    "invocation" => %{"lifetime_scope" => "one-shot", "max_alive_sec" => 150},
    "injects" => %{}, "budget" => %{"maxUsd" => 1.0, "maxDurationSec" => 150}, "modop_set" => []
  }
}

brief = """
Boucle de travail (canal MCP fleet) :
1. Appelle le tool get_task.
2. Si la reponse contient {"done": true} -> tu as fini, arrete-toi.
3. Sinon, execute task.ask, puis appelle submit_result avec payload = {"id": <task.id>, "answer": "<ta reponse exacte>"}.
4. Recommence a l'etape 1.
N'ecris aucun fichier toi-meme. Le brief ne contient PAS les taches — recupere-les via get_task.
"""

{:ok, pid} = Fleet.Spawner.Pod.start_link(%{cap_profile: cap, ticket_id: brief, pod_id: "gate22", opts: []})
ref_mon = Process.monitor(pid)

reason =
  receive do
    {:DOWN, ^ref_mon, :process, _, r} -> r
  after
    160_000 -> :timeout
  end

results = Fleet.MCP.TaskQueue.results()
hit? = Enum.any?(results, fn r -> is_map(r) and Enum.any?(Map.values(r), &(is_binary(&1) and String.contains?(&1, "$NONCE"))) end)

IO.puts("run: pod DOWN reason=#{inspect(reason)} ; central results=#{inspect(results)}")

cond do
  reason == :normal and hit? ->
    IO.puts("PASS e2e   Spawner.Pod → pont → central → submit_result → event Bus → pod.completed → :normal")
    IO.puts("           nonce dans la TaskQueue centrale + pod arrêté :normal = completion event-driven prouvée")
    System.halt(0)
  true ->
    IO.puts("FAIL e2e   reason=#{inspect(reason)} hit?=#{hit?}")
    System.halt(1)
end
EXS

export LCARS_CREDS_ROOT="$WORK/coffre" LCARS_GIT_MIRROR="$WORK/mirror" LCARS_BWRAP_NO_CLEANUP=1
echo "== Gate R-CORE.comm 2.2 — completion EVENT-DRIVEN e2e (Spawner.Pod + pont + central + Bus) =="
echo "   nonce (UNIQUEMENT dans la TaskQueue centrale, absent du brief) : $NONCE"
cd "$RT" && timeout 230 mix run --no-start "$WORK/run.exs"
RC=$?
echo "---"
if [ "$RC" -eq 0 ]; then
  echo "GATE R-CORE.comm 2.2 : exit 0 — completion event-driven, chaîne PROD complète (Iron Law : un mécanisme)"
else
  echo "GATE R-CORE.comm 2.2 : exit 1 (rc=$RC)"
fi
exit "$RC"
