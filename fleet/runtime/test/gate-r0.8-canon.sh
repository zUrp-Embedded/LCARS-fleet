#!/usr/bin/env bash
# SOURCE: test/gate-r0.8-canon.sh
# AUTHOR: starfleet (consolidation salvage cow-boy)
# STARDATE: 2026.146
# STATUS: salvage v2-functional
# gate-r0.8-canon.sh — R0.8. exit 0 ssi les apps réabsorbées ne réfèrent plus `05_data-canon`
# (chemin doctrine hors-repo) dans leurs tests ET passent 0 fail. Réabsorption incrémentale :
# chaque sub-brick (mcp, coord, pipeline, spawner, spbuilder) ajoute son bloc ici quand done.
# NB invocation : les tests à deps umbrella (extra_applications) tournent depuis la RACINE umbrella
# (`mix test apps/<app>/test/`), PAS depuis l'app-dir (sibling .app hors code-path → boot fail).
# PAS de pipefail (mix test exit non-zéro sur fail ≠ échec exécution ; on juge sur "0 failures").
set -u
RT="$(cd "$(dirname "$0")/.." && pwd)"
cd "$RT" || exit 1
FAIL=0
echo "== Gate R0.8 — réabsorption 05_data-canon (apps auto-suffisantes) =="

check_app() {  # $1=app $2=test_glob $3=fichier_canon_attendu
  local app="$1" tglob="$2" canon="$3"
  if grep -rq "05_data-canon" "apps/$app/test/" 2>/dev/null; then
    echo "FAIL $app : ref 05_data-canon résiduelle dans test/"; FAIL=1; return
  fi
  if [ -n "$canon" ] && [ ! -f "apps/$app/$canon" ]; then
    echo "FAIL $app : canon vendoré absent ($canon)"; FAIL=1; return
  fi
  if timeout 150 mix test "apps/$app/test/$tglob" 2>&1 | grep -qE "[1-9][0-9]* tests?, 0 failures"; then
    echo "PASS $app : 0 ref 05_data-canon + suite verte"
  else
    echo "FAIL $app : tests en échec"; FAIL=1
  fi
}

# --- sub-brick mcp (R0.8.mcp) ---
check_app fleet_mcp "" "priv/config/mcp-channels.yaml"

echo "---"
[ "$FAIL" -eq 0 ] && echo "GATE R0.8 : exit 0 — apps réabsorbées auto-suffisantes" || echo "GATE R0.8 : exit 1"
exit "$FAIL"
