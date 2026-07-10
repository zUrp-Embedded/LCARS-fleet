#!/usr/bin/env bash
# SOURCE: test/gate-r0.1-bwrap.sh
# AUTHOR: starfleet (consolidation salvage cow-boy)
# STARDATE: 2026.146
# STATUS: salvage v2-functional
# gate-r0.1-bwrap.sh — R0.1 (Ring 0, primitive bwrap). exit 0 ssi le VRAI bin/bwrap_launch.sh
# provisionne le binaire vendor (claude) DANS le pod à son emplacement natif (fix native-install)
# ET l'isolation du home host tient. Teste le launcher RÉEL, pas une copie. Zéro jugement agent.
set -uo pipefail
HERE="$(cd "$(dirname "$0")" && pwd)"
BWRAP_LAUNCH="$HERE/../bin/bwrap_launch.sh"
WORK="$(mktemp -d)"; FAIL=0
SENTINEL="$HOME/.claude/.gate-r01-sentinel-$$"
trap 'rm -rf "$WORK"; rm -f "$SENTINEL"' EXIT
mkdir -p "$WORK/creds/testrole" "$WORK/mirror" "$WORK/pod1" "$WORK/pod2"
export LCARS_CREDS_ROOT="$WORK/creds" LCARS_GIT_MIRROR="$WORK/mirror" LCARS_BWRAP_NO_CLEANUP=1

echo "== Gate R0.1 — bwrap primitive (vrai bwrap_launch.sh) =="
echo "   launcher: $BWRAP_LAUNCH"

# BIND : claude provisionné + exécuté dans le pod via le vrai launcher
OUT=$(timeout 25 "$BWRAP_LAUNCH" testrole pod1 "$WORK/pod1" claude --version 2>&1)
if echo "$OUT" | grep -qiF "Claude Code"; then
  echo "PASS BIND  claude s'execute dans le pod (native-install provisionne par bwrap_launch)"
else
  echo "FAIL BIND  claude introuvable/inexecutable (out: $(echo "$OUT" | tr '\n' ' ' | cut -c1-140))"; FAIL=1
fi

# ISO : un secret host DOIT rester masque dans le pod. On ne depend PAS de l'existence du vrai
# ~/.claude/.credentials.json (absent -> l'ancien test faisait `cat` sur un fichier inexistant ->
# echec -> branche `else` -> faux PASS = faux-vert, F-C166). On pose une SENTINELLE deterministe dans
# ~/.claude (masquee par le meme --tmpfs /home que le vrai secret), on prouve qu'elle est masquee, on la
# retire (trap EXIT). Le test devient reel et deterministe quelle que soit la machine.
mkdir -p "$HOME/.claude"
if ! echo "lcars-gate-r01-secret" > "$SENTINEL" 2>/dev/null; then
  echo "FAIL ISO   impossible de poser la sentinelle host ($SENTINEL) — isolation non verifiable"; FAIL=1
elif timeout 25 "$BWRAP_LAUNCH" testrole pod2 "$WORK/pod2" /bin/cat "$SENTINEL" >/dev/null 2>&1; then
  echo "FAIL ISO   sentinelle host LISIBLE dans le pod (isolation cassee)"; FAIL=1
else
  echo "PASS ISO   sentinelle host masquee (--tmpfs /home tient)"
fi

echo "---"
if [ "$FAIL" -eq 0 ]; then echo "GATE R0.1 : exit 0 — bwrap primitive porte (vrai launcher)"; else echo "GATE R0.1 : exit 1 — ne porte pas"; fi
exit "$FAIL"
