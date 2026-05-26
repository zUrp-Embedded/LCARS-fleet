#!/usr/bin/env bash
# SOURCE: test/gate-r0.7-capprofile-canon.sh
# AUTHOR: starfleet (consolidation salvage cow-boy)
# STARDATE: 2026.146
# STATUS: salvage v2-functional
# gate-r0.7-capprofile-canon.sh — R0.7 [DATA]. exit 0 ssi fleet_capprofile passe 0 fail AVEC le
# canon cap-profiles vendoré IN-REPO (priv/canon/{cap-profiles,monks,config}), zéro dépendance au
# `05_data-canon` doctrine hors-repo. = repo auto-suffisant (mandate user "UNE SEULE base de code").
# Source vendoring : 7 workers ← doctrine 05_data-canon (== prod, vérifié identique) ; 18 monks ←
# prod /var/lib/lcars/capprofiles/monks (seule source v2.5, dérivée DN ring2/fleet_memory.md) ;
# intensity-template.json ← doctrine. Tests repointés @canon_dir/@monks_dir/@canon_path → priv/canon.
# PAS de pipefail (mix test exit non-zéro sur fail ≠ échec d'exécution ; on juge sur "0 failures").
set -u
RT="$(cd "$(dirname "$0")/.." && pwd)"
APP="$RT/apps/fleet_capprofile"
cd "$APP" || exit 1
FAIL=0
echo "== Gate R0.7 — cap-profiles canon in-repo (fleet_capprofile auto-suffisant) =="

# 1. plus aucune ref au canon doctrine hors-repo dans les tests
if grep -rq "05_data-canon" test/ 2>/dev/null; then
  echo "FAIL ref    référence 05_data-canon résiduelle dans test/ (doit pointer priv/canon)"; FAIL=1
else
  echo "PASS ref    aucune ref 05_data-canon dans test/ (canon in-repo)"
fi

# 2. canon complet vendoré
W=$(ls priv/canon/cap-profiles/*.yaml 2>/dev/null | wc -l)
M=$(ls priv/canon/cap-profiles/monks/*.yaml 2>/dev/null | wc -l)
I=$([ -f priv/canon/config/intensity-template.json ] && echo 1 || echo 0)
if [ "$W" -eq 7 ] && [ "$M" -eq 18 ] && [ "$I" -eq 1 ]; then
  echo "PASS data   7 workers + 18 monks (16 profils + 2 registries) + intensity vendorés"
else
  echo "FAIL data   canon incomplet (workers=$W/7 monks=$M/18 intensity=$I/1)"; FAIL=1
fi

# 3. suite fleet_capprofile verte
if timeout 150 mix test 2>&1 | grep -qE "[1-9][0-9]* tests?, 0 failures"; then
  echo "PASS test   fleet_capprofile 0 failure (cap_profile_v25 + monks_v25 + intensity)"
else
  echo "FAIL test   fleet_capprofile a des échecs"; FAIL=1
fi

echo "---"
[ "$FAIL" -eq 0 ] && echo "GATE R0.7 : exit 0 — canon cap-profiles auto-suffisant in-repo" || echo "GATE R0.7 : exit 1"
exit "$FAIL"
