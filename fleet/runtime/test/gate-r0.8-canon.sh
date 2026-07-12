#!/usr/bin/env bash
# SOURCE: test/gate-r0.8-canon.sh
# AUTHOR: starfleet (consolidation salvage cow-boy)
# STARDATE: 2026.146
# STATUS: salvage v2-functional
# gate-r0.8-canon.sh — R0.8. exit 0 ssi les apps réabsorbées ne réfèrent plus `05_data-canon`
# (chemin doctrine hors-repo) dans leurs tests ET passent 0 fail. Réabsorption incrémentale :
# chaque sub-brick (mcp, coord, pipeline, spawner, spbuilder) ajoute son bloc ici quand done.
# NB invocation : app unique post-collapse (plus d'arbre apps/) — tout `mix test` tourne depuis la
# racine du repo, un seul projet mix (le helper check_app garde la forme historique `apps/<app>/`,
# sans call site depuis F174).
# PAS de pipefail (mix test exit non-zéro sur fail ≠ échec exécution ; on juge sur "0 failures").
# ── GATE RETIRÉ (audit lot 6, 2026-07-12) ─────────────────────────────────────
# Ce gate était un FAUX-VERT structurel (famille F-C166/167) : `check_app` n'a plus AUCUN call-site
# depuis F174, et ses greps ciblent l'arbre `apps/` MORT au collapse umbrella → FAIL reste 0 →
# exit 0 en ne vérifiant RIEN. Le check « 05_data-canon » n'a plus de cible vivante : le re-cibler
# sur lib/ par grep de la string nue ferait des faux positifs sur ~6 commentaires historiques
# (inventaire F-C167), et l'invariant fonctionnel (domaines auto-suffisants, canon vendoré) est
# déjà porté par la suite `mix test` de l'app unique. Conservé comme ARCHIVE d'incrément ;
# exit 3 EXPLICITE — jamais un faux-vert silencieux.
echo "GATE RETIRÉ — check 05_data-canon sans cible vivante post-collapse (cf. header) ; invariant couvert par mix test. Archive, exit 3." >&2
exit 3

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
# F174 : mcp-channels.yaml + tout le substrat channels retirés en MCP-D1 ;
# fleet_mcp n'a plus de priv/. Le check exigeait un canon volontairement
# supprimé → FAIL forever. fleet_mcp reste auto-suffisant sans ce fichier.

echo "---"
[ "$FAIL" -eq 0 ] && echo "GATE R0.8 : exit 0 — apps réabsorbées auto-suffisantes" || echo "GATE R0.8 : exit 1"
exit "$FAIL"
