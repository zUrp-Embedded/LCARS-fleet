#!/usr/bin/env bash
# SOURCE: test/gate-r-core-comm-inc3b3.sh
# AUTHOR: starfleet (consolidation salvage cow-boy)
# STARDATE: 2026.146
# STATUS: salvage v2-functional
# ⛔ APPROCHE ABANDONNÉE — CONSERVÉ COMME PREUVE REPRODUCTIBLE D'UN DEAD-END.
# CONCLUSION EMPIRIQUE (2026-05-24, runtime claude 2.1.150) : un pod one-shot ne peut PAS utiliser un
# serveur fleet_mcp HTTP. Testé 4×, dont avec `alwaysLoad:true` (le cran 2.1.150 censé dé-déférer +
# attendre la connexion `regular-required`) : le serveur reste « still connecting » au turn-1, tools
# déférés (total_deferred_tools:16), 11× ToolSearch infructueux, abandon. L'await `regular-required`
# vu dans le binaire NE s'engage PAS pour un serveur HTTP `--mcp-config` (source ≠ vérité absolue).
# Référence qui MARCHE = stdio (inc3a/inc4 : connexion synchrone, tools inline turn-1 via alwaysLoad).
# → R-CORE.comm pod↔fleet_mcp passe par STDIO. État central éventuel = pont stdio→central (brique future).
# Détail : corpus #0_ref_mcp-tool-deferral-oneshot.md §7 (addendum empirique). NE PAS relancer ce gate.
#
# gate-r-core-comm-inc3b3.sh — R-CORE.comm inc3b.3 (canal MCP e2e via VRAI fleet_mcp HTTP).
# exit 0 ssi un VRAI pod claude (bwrap --share-net) se connecte au VRAI serveur fleet_mcp
# (Fleet.MCP.PodTools en transport :sse, host-side, port OS-assigné), PULL sa tâche via le tool
# MCP `get_task` (canal IN) sur HTTP, l'exécute, et la soumet via `submit_result` (canal OUT) —
# le résultat atterrit dans la Fleet.MCP.TaskQueue HOST-SIDE (PAS un fichier, PAS la fixture python).
# PREUVE forte : le nonce n'existe QUE dans la file fleet (host), JAMAIS dans le brief → s'il
# ressort côté fleet, le pod l'a forcément récupéré via get_task sur le fil HTTP. Remplace la
# fixture python (inc4) par le vrai substrat Elixir. Orchestration = driver Elixir (possède
# serveur+queue) qui System.cmd le pod. Bin+driver hors /home,/tmp (bwrap tmpfs).
set -uo pipefail
HERE="$(cd "$(dirname "$0")" && pwd)"; RT="$(cd "$HERE/.." && pwd)"; BIN="$RT/bin"
WORK="$(mktemp -d)"; POD="$WORK/pod"
BINV="$(mktemp -d -p /var/tmp lcars-gate-inc3b3.XXXXXX)"
cp "$BIN/bwrap_launch.sh" "$BIN/claude_launch.sh" "$BINV/"
trap 'pkill -f "$WORK" 2>/dev/null; [ "${KEEP:-0}" = 1 ] && echo "KEEP $WORK $BINV" || rm -rf "$WORK" "$BINV"' EXIT
mkdir -p "$POD/.claude" "$POD/context" "$POD/output" "$WORK/creds/testrole" "$WORK/mirror"
cp "$HOME/.claude/.credentials.json" "$POD/.claude/.credentials.json"; chmod 600 "$POD/.claude/.credentials.json"
printf 'Tu es un pod worker LCARS. Suis le brief exactement, rien de plus.\n' > "$POD/.claude/system-prompt.md"
printf '{"spec":{"scope":{"allowedTools":["mcp__fleet__get_task","mcp__fleet__submit_result"],"disallowedTools":["WebSearch","Bash","Write","Edit"]}}}\n' > "$POD/.cap-profile.json"
NONCE="pong-http-$(date +%s)-$RANDOM"
# La tâche (avec le nonce) est UNIQUEMENT dans la file fleet (host-side, TaskQueue) — JAMAIS dans
# le brief. Le driver Elixir la pousse + écrit .mcp-fleet.json (il connaît le port après start).
cat > "$POD/context/brief.md" <<'EOF'
Boucle de travail (canal MCP fleet) :
1. Appelle le tool get_task.
2. Si la reponse contient {"done": true} -> tu as fini, arrete-toi.
3. Sinon, execute task.ask, puis appelle submit_result avec payload = {"id": <task.id>, "answer": "<ta reponse exacte>"}.
4. Recommence a l'etape 1.
N'ecris aucun fichier toi-meme. Le brief ne contient PAS les taches — recupere-les via get_task.
EOF

cat > "$WORK/driver.exs" <<'EXS'
# Driver inc3b.3 — possède le VRAI serveur fleet_mcp HTTP + la TaskQueue, seed le nonce, écrit
# .mcp-fleet.json (http://localhost:<port>/mcp), shelle le vrai pod claude, juge sur la file fleet.
Application.put_env(:fleet_mcp, :boot_environment, :host)
{:ok, _} = Application.ensure_all_started(:fleet_mcp)
{:ok, _q} = Fleet.MCP.TaskQueue.start_link([])
ref = :inc3b3_srv
# Mode :http (PAS :sse) : les réponses reviennent dans le BODY du POST, pas via un stream SSE.
# Diagnostiqué inc3b.3 strike 1 : claude (type:"http" Streamable HTTP) face à un serveur :sse
# mésgère le stream (reconnexions "Created session" en boucle) et ne POST jamais le tool-call.
{:ok, _http} = Fleet.MCP.PodTools.start_link(transport: :http, port: 0, ranch_ref: ref)
port = :ranch.get_port(ref)

nonce = System.get_env("NONCE")
pod = System.get_env("POD")
binv = System.get_env("BINV")

Fleet.MCP.TaskQueue.push(%{"id" => 1, "ask" => "Reponds EXACTEMENT et UNIQUEMENT le mot : " <> nonce})
# "alwaysLoad":true (clé config SERVEUR, 2.1.150 — vérifiée binaire live + confirmée empiriquement
# via inc3a stdio) : (1) dé-défère TOUS les tools du serveur → inline turn-1, pas de round-trip
# ToolSearch ; (2) classe le serveur "regular-required" → claude ATTEND sa connexion au démarrage
# (Promise.all().then(after_mcp_connect_user), cap 5s). C'est ce (2) qui résout le race HTTP : le
# serveur n'est plus "pending" au turn-1. Strikes 1-3 précédents : deferLoading = FAUX LEVIER (jamais
# parsé, cf #0_ref_mcp-tool-deferral-oneshot.md §3,§7). alwaysLoad = le vrai cran, absent du leak 2.1.88.
File.write!(Path.join(pod, ".mcp-fleet.json"),
  ~s({"mcpServers":{"fleet":{"type":"http","url":"http://localhost:#{port}/mcp","alwaysLoad":true}}}))
IO.puts("driver: fleet_mcp HTTP (:http) sur localhost:#{port} ; alwaysLoad:true (inline turn-1 + await regular-required) ; nonce dans la file (absent du brief)")

env = [
  {"LCARS_CREDS_ROOT", System.get_env("LCARS_CREDS_ROOT")},
  {"LCARS_GIT_MIRROR", System.get_env("LCARS_GIT_MIRROR")},
  {"LCARS_BWRAP_NO_CLEANUP", "1"}
]

{out, rc} =
  System.cmd(Path.join(binv, "bwrap_launch.sh"),
    ["testrole", "inc3b3", pod, Path.join(binv, "claude_launch.sh"), "testrole", "inc3b3", pod, "140", "1.0"],
    env: env, stderr_to_stdout: true)

IO.puts("driver: pod rc=#{rc} (exit REPL non fiable — on juge sur la file fleet, pas le code)")

results = Fleet.MCP.TaskQueue.results()

hit? =
  Enum.any?(results, fn r ->
    is_map(r) and Enum.any?(Map.values(r), &(is_binary(&1) and String.contains?(&1, nonce)))
  end)

if hit? do
  IO.puts("PASS e2e   pod claude -> get_task (HTTP) -> submit_result -> TaskQueue fleet : #{inspect(results)}")
  IO.puts("           nonce present cote fleet (host) => pull via get_task sur le fil HTTP prouve")
  System.halt(0)
else
  IO.puts("FAIL e2e   aucun resultat avec le nonce cote fleet. results=#{inspect(results)}")
  IO.puts("  --- pod out (tail) ---")
  out |> String.split("\n") |> Enum.take(-18) |> Enum.join("\n") |> IO.puts()
  System.halt(1)
end
EXS

export LCARS_CREDS_ROOT="$WORK/creds" LCARS_GIT_MIRROR="$WORK/mirror" LCARS_BWRAP_NO_CLEANUP=1
echo "== Gate R-CORE.comm inc3b.3 — pod claude reel <-> VRAI fleet_mcp HTTP (get_task IN / submit_result OUT) =="
echo "   nonce (UNIQUEMENT dans la TaskQueue fleet host-side, absent du brief) : $NONCE"
cd "$RT" && NONCE="$NONCE" POD="$POD" BINV="$BINV" timeout 260 mix run --no-start "$WORK/driver.exs"
RC=$?
echo "---"
if [ "$RC" -eq 0 ]; then
  echo "GATE R-CORE.comm inc3b.3 : exit 0 — canal MCP e2e via VRAI fleet_mcp HTTP (fixture python retiree)"
else
  echo "GATE R-CORE.comm inc3b.3 : exit 1 (rc=$RC)"
fi
exit "$RC"
