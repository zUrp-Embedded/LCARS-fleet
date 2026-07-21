#!/usr/bin/env bash
# SOURCE: test/gate-r-core-comm-inc3c2.sh
# AUTHOR: starfleet (consolidation salvage cow-boy)
# STARDATE: 2026.146
# STATUS: RETIRE / ARCHIVE (DR-032) — court-circuite (exit non-zero) ; NON execute par mix gate. Le « exit 0 ssi… » ci-dessous est HISTORIQUE (cf. « GATE RETIRE » plus bas).
# gate-r-core-comm-inc3c2.sh — R-CORE.comm inc3c.2 (e2e : pod claude → pont stdio → fleet_mcp central).
# exit 0 ssi un VRAI pod claude (bwrap --share-net) spawne le pont stdio `fleet_mcp_stdio_bridge.py`
# (connexion SYNCHRONE → tools inline turn-1, le seul transport viable one-shot), PULL sa tache via
# get_task (canal IN) — le pont forwarde au VRAI fleet_mcp central HTTP (PodTools :http + TaskQueue) —
# l'execute, et soumet via submit_result (OUT) → le resultat atterrit dans la TaskQueue CENTRALE.
# PREUVE forte : le nonce n'existe QUE dans la TaskQueue centrale (host), JAMAIS dans le brief → s'il
# ressort cote central, le pod l'a forcement recupere via get_task → pont → central. C'est la
# resolution du blocage inc3b.3 (HTTP direct mort) faite proprement : un seul mecanisme (MCP/stdio),
# etat CENTRAL via le pont. Iron Law respectee. Bin+pont+launchers hors /home,/tmp (bwrap tmpfs).
set -uo pipefail

# ── SUPERSEDED (Fable F168-F178) — archi coffre + file MCP-channel globale RETIREE ──
# Cette gate e2e teste un modele DISPARU : coffre credentials (pre-ADR-F : on bind le claudeDir
# natif), file globale Fleet.MCP.TaskQueue.push/results (pre-per-pod Fleet.TaskQueue), listener
# channel HTTP (purge ADR-G C5.1). Reecriture contre l'archi courante (per-pod + bwrap/RC) = exige
# un vrai claude+bwrap → chantier deploy-env, non faisable en sandbox. Round-trip MCP per-pod prouve
# par test/pod_socket_test.exs (mix test — get_work_item/submit_result sur la socket AF_UNIX per-pod ;
# pointeur realigne audit lot 6 2026-07-12 : gate-r4-mcp-boot.sh est lui-meme SUPERSEDED, script mort
# sur l'app unique). Corps historique conserve ci-dessous (archive).
echo "SUPERSEDED — gate e2e archi coffre/MCP-channel (pre-ADR-F/ADR-G). Reecriture = deploy-env. Preuve vivante : test/pod_socket_test.exs (mix test)"
exit 2
HERE="$(cd "$(dirname "$0")" && pwd)"; RT="$(cd "$HERE/.." && pwd)"; BIN="$RT/bin"
WORK="$(mktemp -d)"; POD="$WORK/pod"
BINV="$(mktemp -d -p /var/tmp lcars-gate-inc3c2.XXXXXX)"
cp "$BIN/bwrap_launch.sh" "$BIN/claude_launch.sh" "$BIN/fleet_mcp_stdio_bridge.py" "$BINV/"
trap 'pkill -f "$WORK" 2>/dev/null; [ "${KEEP:-0}" = 1 ] && echo "KEEP $WORK $BINV" || rm -rf "$WORK" "$BINV"' EXIT
mkdir -p "$POD/.claude" "$POD/context" "$POD/output" "$WORK/creds/testrole" "$WORK/mirror"
cp "$HOME/.claude/.credentials.json" "$POD/.claude/.credentials.json"; chmod 600 "$POD/.claude/.credentials.json"
printf 'Tu es un pod worker LCARS. Suis le brief exactement, rien de plus.\n' > "$POD/.claude/system-prompt.md"
printf '{"spec":{"scope":{"allowedTools":["mcp__fleet__get_task","mcp__fleet__submit_result"],"disallowedTools":["WebSearch","Bash","Write","Edit"]}}}\n' > "$POD/.cap-profile.json"
NONCE="pong-bridge-$(date +%s)-$RANDOM"
cat > "$POD/context/brief.md" <<'EOF'
Boucle de travail (canal MCP fleet) :
1. Appelle le tool get_task.
2. Si la reponse contient {"done": true} -> tu as fini, arrete-toi.
3. Sinon, execute task.ask, puis appelle submit_result avec payload = {"id": <task.id>, "answer": "<ta reponse exacte>"}.
4. Recommence a l'etape 1.
N'ecris aucun fichier toi-meme. Le brief ne contient PAS les taches — recupere-les via get_task.
EOF

cat > "$WORK/driver.exs" <<'EXS'
# Driver inc3c.2 — possede le VRAI fleet_mcp central (PodTools :http + TaskQueue), seed le nonce,
# ecrit .mcp-fleet.json pointant le PONT stdio (command python3, env LCARS_FLEET_MCP_URL=central),
# shelle le vrai pod claude, juge sur la TaskQueue CENTRALE.
Application.put_env(:fleet_mcp, :boot_environment, :host)
{:ok, _} = Application.ensure_all_started(:fleet_mcp)
{:ok, _q} = Fleet.MCP.TaskQueue.start_link([])
ref = :inc3c2_srv
{:ok, _http} = Fleet.MCP.PodTools.start_link(transport: :http, port: 0, ranch_ref: ref)
port = :ranch.get_port(ref)

nonce = System.get_env("NONCE"); pod = System.get_env("POD"); binv = System.get_env("BINV")
Fleet.MCP.TaskQueue.push(%{"id" => 1, "ask" => "Reponds EXACTEMENT et UNIQUEMENT le mot : " <> nonce})

# Le pod spawne le PONT (stdio, synchrone → tools inline turn-1). alwaysLoad:true = tools de-deferes.
# Le pont forwarde vers le central HTTP (LCARS_FLEET_MCP_URL). bwrap --share-net → localhost joignable.
bridge = Path.join(binv, "fleet_mcp_stdio_bridge.py")
File.write!(Path.join(pod, ".mcp-fleet.json"), Jason.encode!(%{
  "mcpServers" => %{"fleet" => %{
    "command" => "python3", "args" => [bridge], "alwaysLoad" => true,
    "env" => %{"LCARS_FLEET_MCP_URL" => "http://localhost:#{port}/mcp"}
  }}
}))
IO.puts("driver: central fleet_mcp HTTP localhost:#{port} ; pod→pont stdio→central ; nonce dans TaskQueue centrale (absent du brief)")

env = [
  {"LCARS_CREDS_ROOT", System.get_env("LCARS_CREDS_ROOT")},
  {"LCARS_GIT_MIRROR", System.get_env("LCARS_GIT_MIRROR")},
  {"LCARS_BWRAP_NO_CLEANUP", "1"}
]
{out, rc} =
  System.cmd(Path.join(binv, "bwrap_launch.sh"),
    ["testrole", "inc3c2", pod, Path.join(binv, "claude_launch.sh"), "testrole", "inc3c2", pod, "140", "1.0"],
    env: env, stderr_to_stdout: true)
IO.puts("driver: pod rc=#{rc} (exit REPL non fiable — on juge sur la TaskQueue centrale)")

results = Fleet.MCP.TaskQueue.results()
hit? = Enum.any?(results, fn r ->
  is_map(r) and Enum.any?(Map.values(r), &(is_binary(&1) and String.contains?(&1, nonce)))
end)

if hit? do
  IO.puts("PASS e2e   pod claude → pont stdio → get_task/submit_result → TaskQueue CENTRALE : #{inspect(results)}")
  IO.puts("           nonce present cote central ⇒ pod a parle au fleet_mcp central VIA le pont stdio")
  System.halt(0)
else
  IO.puts("FAIL e2e   aucun resultat avec le nonce cote central. results=#{inspect(results)}")
  IO.puts("  --- pod out (tail) ---")
  out |> String.split("\n") |> Enum.take(-18) |> Enum.join("\n") |> IO.puts()
  System.halt(1)
end
EXS

export LCARS_CREDS_ROOT="$WORK/creds" LCARS_GIT_MIRROR="$WORK/mirror" LCARS_BWRAP_NO_CLEANUP=1
echo "== Gate R-CORE.comm inc3c.2 — pod claude → pont stdio → fleet_mcp central (e2e) =="
echo "   nonce (UNIQUEMENT dans la TaskQueue centrale, absent du brief) : $NONCE"
cd "$RT" && NONCE="$NONCE" POD="$POD" BINV="$BINV" timeout 260 mix run --no-start "$WORK/driver.exs"
RC=$?
echo "---"
if [ "$RC" -eq 0 ]; then
  echo "GATE R-CORE.comm inc3c.2 : exit 0 — e2e pod→pont→central, etat CENTRAL via stdio (Iron Law OK)"
else
  echo "GATE R-CORE.comm inc3c.2 : exit 1 (rc=$RC)"
fi
exit "$RC"
