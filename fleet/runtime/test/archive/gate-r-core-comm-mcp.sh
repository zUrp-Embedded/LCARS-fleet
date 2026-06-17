#!/usr/bin/env bash
# SOURCE: test/gate-r-core-comm-mcp.sh
# AUTHOR: starfleet (consolidation salvage cow-boy)
# STARDATE: 2026.146
# STATUS: salvage v2-functional
# gate-r-core-comm-mcp.sh — R-CORE.comm increment 2. exit 0 ssi le VRAI claude_launch.sh (support MCP)
# drive un pod qui RETOURNE un résultat STRUCTURÉ via un tool MCP fleet (`submit_result`), SANS scraping
# TUI. = canal OUT du substrat de comm pod, prouvé via le launcher réel (pas un sed-variant).
# Recette (keystone) : config MCP conventionnelle `$POD/.mcp-fleet.json` (PAS .mcp.json → pas de dialog
# auto-discovery) + --strict-mcp-config + tool MCP dans cap-profile allowedTools (auto-approuvé) + folder-trust.
# Serveur MCP = fixture stdio test/fixtures/mcp_submit_server.py (stand-in du futur fleet_mcp http_sse).
# bin + fixture copiés hors /home,/tmp (masqués par bwrap --tmpfs). Zéro stub, zéro jugement agent.
set -uo pipefail
HERE="$(cd "$(dirname "$0")" && pwd)"; RT="$(cd "$HERE/.." && pwd)"; BIN="$RT/bin"
WORK="$(mktemp -d)"; POD="$WORK/pod"; FAIL=0
BINV="$(mktemp -d -p /var/tmp lcars-gate-mcp.XXXXXX)"; SRVV="$BINV/mcp_submit_server.py"
cp "$BIN/bwrap_launch.sh" "$BIN/claude_launch.sh" "$BINV/"
cp "$HERE/fixtures/mcp_submit_server.py" "$SRVV"
trap 'pkill -f "$WORK" 2>/dev/null; [ "${KEEP:-0}" = 1 ] && echo "KEEP $WORK $BINV" || rm -rf "$WORK" "$BINV"' EXIT
mkdir -p "$POD/.claude" "$POD/context" "$POD/output" "$WORK/creds/testrole" "$WORK/mirror"
cp "$HOME/.claude/.credentials.json" "$POD/.claude/.credentials.json"; chmod 600 "$POD/.claude/.credentials.json"
printf 'Tu es un pod de test LCARS. Execute le mandat exactement, rien de plus.\n' > "$POD/.claude/system-prompt.md"
# cap-profile : le tool MCP dans allowedTools (auto-approuvé, pas de prompt)
printf '{"spec":{"scope":{"allowedTools":["mcp__fleet__submit_result"],"disallowedTools":["WebSearch","Bash","Write","Edit"]}}}\n' > "$POD/.cap-profile.json"
NONCE="RCORE-$(date +%s)-$RANDOM"
# config MCP conventionnelle détectée par claude_launch (R-CORE.comm)
cat > "$POD/.mcp-fleet.json" <<EOF
{"mcpServers":{"fleet":{"command":"python3","args":["$SRVV"],"env":{"LCARS_SUBMIT_PATH":"$POD/output/submit.json"}}}}
EOF
cat > "$POD/context/brief.md" <<EOF
Retourne au fleet, en appelant le tool submit_result, payload = {"nonce":"$NONCE","ok":true}. C'est ta seule action, n'ecris aucun fichier toi-meme.
EOF
export LCARS_CREDS_ROOT="$WORK/creds" LCARS_GIT_MIRROR="$WORK/mirror" LCARS_BWRAP_NO_CLEANUP=1
echo "== Gate R-CORE.comm — claude_launch RÉEL drive un pod → submit_result MCP (canal OUT) =="
echo "   nonce: $NONCE"
# argv = PortBackend.build_spawn
timeout 130 "$BINV/bwrap_launch.sh" testrole rcoremcp "$POD" "$BINV/claude_launch.sh" testrole rcoremcp "$POD" 110 1.0 > "$WORK/launch.log" 2>&1 || true
RES="$POD/output/submit.json"
if [ -f "$RES" ] && grep -Fq "$NONCE" "$RES"; then
  echo "PASS  pod → MCP submit_result, résultat structuré côté fleet : $(cat "$RES")"
else
  echo "FAIL  pas de submit MCP conforme ($( [ -f "$RES" ] && cat "$RES" 2>/dev/null || echo ABSENT))"
  echo "  --- dbg (tail) ---"; tail -6 "$POD/claude_launch.dbg" 2>/dev/null
  FAIL=1
fi
echo "---"
[ "$FAIL" -eq 0 ] && echo "GATE R-CORE.comm inc2 : exit 0 — MCP OUT via le vrai launcher" || echo "GATE R-CORE.comm inc2 : exit 1"
exit "$FAIL"
