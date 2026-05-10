#!/bin/bash
# SOURCE: run-all.sh
# AUTHOR: STARFLEET
# STARDATE: 2026.110
# STATUS: orchestrateur PoC_unitaire
# Trouve tous les test.sh sous PoC_unitaire/ et les lance, resume en fin.

HERE=$(dirname "$(readlink -f "$0")")
cd "$HERE"

# F1 fix (vulcan 2026-04-20) : classe PARTIAL explicite. Une unite avec
# [PASS] ET [GAP] dans la meme sortie est PARTIAL, pas PROVEN. PROVEN
# exige zero [GAP] residuel. Evite la comptabilite falsifiable ou un test
# emettant un mini-PASS + 3 GAP passait comme couverture complete.

PROVEN=()
PARTIAL=()
DRAFT=()
FAIL=()
SKIPPED=()

# F-06 ergo fix (consultant 2026-04-20) : tests taggues
# `# RESOURCE: <tag>` skippes par defaut. Override via
# POC_RESOURCES_ALLOWED=claude_token (ou =all).
# Un test qui consomme un token Claude, fait du reseau, ou depend d un
# service externe doit porter un header `# RESOURCE: claude_token` /
# `# RESOURCE: network` / etc. dans ses 20 premieres lignes.
ALLOWED="${POC_RESOURCES_ALLOWED:-none}"

resource_of() {
  head -20 "$1" | grep -oE "^# RESOURCE:\s*\S+" | head -1 | awk '{print $3}'
}

while IFS= read -r t; do
  name=$(dirname "$t" | sed "s|^./||")
  res=$(resource_of "$t")
  if [ -n "$res" ] && [ "$ALLOWED" != "all" ] && [ "$ALLOWED" != "$res" ]; then
    SKIPPED+=("$name  (resource=$res, set POC_RESOURCES_ALLOWED=$res)")
    continue
  fi
  out=$(timeout 60 bash "$t" 2>&1)
  rc=$?
  has_pass=$(echo "$out" | grep -cE "^\[PASS\]")
  has_fail=$(echo "$out" | grep -cE "^\[FAIL\]")
  has_gap=$(echo "$out" | grep -cE "^\[GAP\]")

  if [ "$has_fail" -gt 0 ] || [ "$rc" -ne 0 ]; then
    FAIL+=("$name")
  elif [ "$has_pass" -gt 0 ] && [ "$has_gap" -eq 0 ]; then
    PROVEN+=("$name  ($has_pass assertions)")
  elif [ "$has_pass" -gt 0 ] && [ "$has_gap" -gt 0 ]; then
    PARTIAL+=("$name  ($has_pass pass + $has_gap gaps)")
  elif [ "$has_gap" -gt 0 ]; then
    DRAFT+=("$name  ($has_gap gaps)")
  else
    DRAFT+=("$name  (silent)")
  fi
done < <(find . -name test.sh -type f -executable | sort)

echo "===== PoC_unitaire etat global ====="
echo
echo "PROVEN (${#PROVEN[@]}) — test runnable + [PASS] observe, ZERO gap residuel :"
for n in "${PROVEN[@]}"; do echo "  PASS     $n"; done
echo
echo "PARTIAL (${#PARTIAL[@]}) — [PASS] observe mais des [GAP] restent a couvrir :"
for n in "${PARTIAL[@]}"; do echo "  PARTIAL  $n"; done
echo
echo "DRAFT (${#DRAFT[@]}) — mandat pose, aucun [PASS] encore :"
for n in "${DRAFT[@]}"; do echo "  DRAFT    $n"; done
echo
if [ ${#FAIL[@]} -gt 0 ]; then
  echo "FAIL (${#FAIL[@]}) — regression :"
  for n in "${FAIL[@]}"; do echo "  FAIL     $n"; done
  echo
fi

if [ ${#SKIPPED[@]} -gt 0 ]; then
  echo "SKIPPED (${#SKIPPED[@]}) — tagges RESOURCE, POC_RESOURCES_ALLOWED=$ALLOWED :"
  for n in "${SKIPPED[@]}"; do echo "  SKIP     $n"; done
  echo
fi

TOTAL=$((${#PROVEN[@]} + ${#PARTIAL[@]} + ${#DRAFT[@]} + ${#FAIL[@]} + ${#SKIPPED[@]}))
echo "Total: $TOTAL unites | PROVEN: ${#PROVEN[@]} | PARTIAL: ${#PARTIAL[@]} | DRAFT: ${#DRAFT[@]} | FAIL: ${#FAIL[@]} | SKIPPED: ${#SKIPPED[@]}"
echo
echo "Regle PROVEN (vulcan F1) : PROVEN exige zero [GAP] dans le test.sh."
echo "Une unite avec gaps residuels est PARTIAL, pas PROVEN."
echo
echo "Tests tagges RESOURCE (consultant F-06) : skippes par defaut."
echo "Override : POC_RESOURCES_ALLOWED=claude_token (ou =all)."
