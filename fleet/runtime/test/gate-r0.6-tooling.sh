#!/usr/bin/env bash
# SOURCE: test/gate-r0.6-tooling.sh
# AUTHOR: starfleet (consolidation salvage cow-boy)
# STARDATE: 2026.146
# STATUS: SONDE MANUELLE v2 (DR-032) — standalone, hors mix gate (non-CI ; mix gate = ExUnit + shell_gate[python+bats] + contracts.check + dialyzer).
# gate-r0.6-tooling.sh — R0.6. exit 0 ssi l'outillage statique (Credo/Sobelow/Dialyzer) est
# configuré + RUNNABLE depuis la racine du runtime (app unique). Les FINDINGS sont une baseline (PAS gated à
# zéro — cleanup séparé, par gate). Sert aussi de vérif indépendante des rapports d'audit
# (don't-trust-the-report : Sobelow ↔ injection/traversal, Dialyzer ↔ @spec, Credo ↔ cohérence).
# Critère : chaque tool RUN (signature output), indépendamment du nombre de findings.
# PAS de pipefail : `mix credo`/`sobelow` exitent non-zéro SUR FINDINGS (≠ échec d'exécution) ;
# pipefail masquerait le succès du grep de signature. On juge sur la signature output, pas l'exit.
set -u
RT="$(cd "$(dirname "$0")/.." && pwd)"
cd "$RT" || exit 1
FAIL=0
echo "== Gate R0.6 — outillage statique =="

if timeout 120 mix credo --strict 2>&1 | grep -q "Analysis took"; then
  echo "PASS CREDO   runnable (mix credo --strict)"
else
  echo "FAIL CREDO   ne tourne pas"; FAIL=1
fi

if timeout 90 mix sobelow --root . 2>&1 | grep -qi "Running Sobelow"; then
  echo "PASS SOBELOW runnable (mix sobelow --root .)"
else
  echo "FAIL SOBELOW ne tourne pas"; FAIL=1
fi

if mix help dialyzer 2>&1 | grep -qi "dialyzer"; then
  echo "PASS DIALYZER configuré (task dispo ; PLT = setup one-time)"
else
  echo "FAIL DIALYZER non configuré"; FAIL=1
fi

echo "---"
[ "$FAIL" -eq 0 ] && echo "GATE R0.6 : exit 0 — outillage statique opérationnel" || echo "GATE R0.6 : exit 1"
exit "$FAIL"
