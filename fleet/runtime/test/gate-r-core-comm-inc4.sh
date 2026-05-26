#!/usr/bin/env bash
# SOURCE: test/gate-r-core-comm-inc4.sh
# AUTHOR: starfleet (consolidation salvage cow-boy)
# STARDATE: 2026.146
# STATUS: salvage v2-functional
# gate-r-core-comm-inc4.sh — R-CORE.comm increment 4 (canal IN). exit 0 ssi un pod PULL sa tâche
# auprès du fleet via le tool MCP `get_task` (canal IN), l'exécute, et soumet via `submit_result` (OUT)
# — comm fleet↔pod 100% MCP, zéro scraping/injection. PREUVE forte : la tâche (et son nonce) n'existe
# QUE dans la file fleet ($LCARS_TASK_QUEUE), JAMAIS dans le brief → si la réponse contient le nonce,
# le pod l'a forcément récupérée via get_task. Via le VRAI claude_launch (.mcp-fleet.json + --strict).
# Serveur = fixture bidirectionnelle test/fixtures/mcp_submit_server.py. Bin+fixture hors /home,/tmp.
set -uo pipefail
HERE="$(cd "$(dirname "$0")" && pwd)"; RT="$(cd "$HERE/.." && pwd)"; BIN="$RT/bin"
WORK="$(mktemp -d)"; POD="$WORK/pod"; FAIL=0
BINV="$(mktemp -d -p /var/tmp lcars-gate-inc4.XXXXXX)"; SRVV="$BINV/mcp_submit_server.py"
cp "$BIN/bwrap_launch.sh" "$BIN/claude_launch.sh" "$BINV/"
cp "$HERE/fixtures/mcp_submit_server.py" "$SRVV"
trap 'pkill -f "$WORK" 2>/dev/null; [ "${KEEP:-0}" = 1 ] && echo "KEEP $WORK $BINV" || rm -rf "$WORK" "$BINV"' EXIT
mkdir -p "$POD/.claude" "$POD/context" "$POD/output" "$WORK/creds/testrole" "$WORK/mirror"
cp "$HOME/.claude/.credentials.json" "$POD/.claude/.credentials.json"; chmod 600 "$POD/.claude/.credentials.json"
printf 'Tu es un pod worker LCARS. Suis le brief exactement, rien de plus.\n' > "$POD/.claude/system-prompt.md"
printf '{"spec":{"scope":{"allowedTools":["mcp__fleet__get_task","mcp__fleet__submit_result"],"disallowedTools":["WebSearch","Bash","Write","Edit"]}}}\n' > "$POD/.cap-profile.json"
NONCE="pong-$(date +%s)-$RANDOM"
# La tâche (avec le nonce) est UNIQUEMENT dans la file fleet — JAMAIS dans le brief.
# La file DOIT vivre DANS $POD : bwrap masque /tmp (--tmpfs /tmp) et ne bind QUE $POD_DIR. Une file
# sous $WORK (=/tmp/...) est invisible au serveur MCP DANS le sandbox → get_task renverrait
# {"done":true} d'emblée (bug masked-path diagnostiqué 2026-05-24). Dotfile racine pod : hors
# context/ et hors allowedTools (2 tools MCP only) → le pod ne peut PAS la lire en direct (preuve nonce intacte).
TASKQ="$POD/.fleet-taskq.json"
printf '[{"id":1,"ask":"Reponds EXACTEMENT et UNIQUEMENT le mot suivant : %s"}]\n' "$NONCE" > "$TASKQ"
cat > "$POD/.mcp-fleet.json" <<EOF
{"mcpServers":{"fleet":{"command":"python3","args":["$SRVV"],"env":{"LCARS_SUBMIT_PATH":"$POD/output/submit.json","LCARS_TASK_QUEUE":"$TASKQ"}}}}
EOF
cat > "$POD/context/brief.md" <<'EOF'
Boucle de travail (canal MCP fleet) :
1. Appelle le tool get_task.
2. Si la reponse contient {"done": true} -> tu as fini, arrete-toi.
3. Sinon, execute task.ask, puis appelle submit_result avec payload = {"id": <task.id>, "answer": "<ta reponse exacte>"}.
4. Recommence a l'etape 1.
N'ecris aucun fichier toi-meme. Le brief ne contient PAS les taches — recupere-les via get_task.
EOF
export LCARS_CREDS_ROOT="$WORK/creds" LCARS_GIT_MIRROR="$WORK/mirror" LCARS_BWRAP_NO_CLEANUP=1
echo "== Gate R-CORE.comm inc4 — canal IN : pod PULL sa tâche via get_task (MCP) =="
echo "   nonce (UNIQUEMENT dans la file fleet, absent du brief) : $NONCE"
timeout 160 "$BINV/bwrap_launch.sh" testrole rcore4 "$POD" "$BINV/claude_launch.sh" testrole rcore4 "$POD" 140 1.0 > "$WORK/launch.log" 2>&1 || true
RES="$POD/output/submit.json"
if [ -f "$RES" ] && grep -Fq "$NONCE" "$RES"; then
  echo "PASS IN   pod → get_task (pull tâche) → submit_result : $(cat "$RES")"
  echo "          nonce présent ⇒ tâche forcément récupérée via get_task = canal IN MCP prouvé"
else
  echo "FAIL IN   pas de preuve du pull ($( [ -f "$RES" ] && cat "$RES" 2>/dev/null || echo ABSENT))"
  echo "  --- dbg (tail) ---"; tail -8 "$POD/claude_launch.dbg" 2>/dev/null
  FAIL=1
fi
echo "---"
[ "$FAIL" -eq 0 ] && echo "GATE R-CORE.comm inc4 : exit 0 — canal IN MCP (pod pull task)" || echo "GATE R-CORE.comm inc4 : exit 1"
exit "$FAIL"
