#!/bin/bash
# SOURCE: test.sh
# AUTHOR: STARFLEET
# STARDATE: 2026.110
# STATUS: PROVEN
# RESOURCE: claude_token
# R-04b+c fix (consultant 2026-04-20) :
# - Le volet `--resume sur home vide` a ete separe en mode opt-in
#   (POC_RESOURCES_ALLOWED=claude_token requis) parce qu il consomme un
#   token Claude reel. Par defaut, test mecanique pur (relais PoC-01).
# - Le critere a ete durci : [FAIL] au lieu de [OBS] si la detection
#   "--resume sur session absente" ne produit pas une erreur explicite.
# R-05a fix : manifest d assertions attendues du harness amont (PoC-01).

set -u
HARNESS=/home/projects/LCARS/PoC/PoC-01-claude-p-recette/test_recette.sh

if [ ! -x "$HARNESS" ]; then
  echo "[FAIL] PoC-01 harness absent ($HARNESS)"
  exit 1
fi

OUT=$("$HARNESS" 2>&1)
RC=$?

# R-05a: manifest explicite. Chaque assertion attendue doit apparaitre.
# Si le harness renomme ou supprime une assertion, le relais detecte.
EXPECTED_ASSERTIONS=("T2.no-session-persistence" "T3.setting-sources-empty" "T4.ndjson-no-ansi" "T4.ndjson-valid-json")
MISSING=()
for a in "${EXPECTED_ASSERTIONS[@]}"; do
  if ! echo "$OUT" | grep -qE "^\[PASS\] ${a}"; then
    MISSING+=("$a")
  fi
done

if [ ${#MISSING[@]} -gt 0 ]; then
  echo "[FAIL] PoC-01 harness manque des assertions nommees : ${MISSING[*]}"
  exit 1
fi

# R-05a : FAIL attendus allowlist. Ce sont des findings documentes hors du
# scope de cette unite, et qui ne doivent pas retro-bloquer le relais.
# Les autres FAIL sont des regressions reelles.
EXPECTED_FAILS=("T1.disable-claude-mds")  # finding P1 documente, CLAUDE_CODE_DISABLE_CLAUDE_MDS ignore 2.1.114
UNEXPECTED=()
while IFS= read -r fail_line; do
  matched=0
  for ef in "${EXPECTED_FAILS[@]}"; do
    if echo "$fail_line" | grep -qE "^\[FAIL\] ${ef}"; then
      matched=1
      break
    fi
  done
  [ "$matched" = "0" ] && UNEXPECTED+=("$fail_line")
done < <(echo "$OUT" | grep -E "^\[FAIL\]")

if [ ${#UNEXPECTED[@]} -gt 0 ]; then
  echo "[FAIL] PoC-01 harness : FAIL inattendus (hors allowlist)"
  for f in "${UNEXPECTED[@]}"; do echo "    $f"; done
  exit 1
fi

echo "[PASS] PoC-01 manifest (${#EXPECTED_ASSERTIONS[@]} assertions nommees presentes)"
if [ ${#EXPECTED_FAILS[@]} -gt 0 ]; then
  echo "[OBS] PoC-01 FAIL attendus (allowlist): ${EXPECTED_FAILS[*]}"
fi

# Volet --resume : opt-in (consomme un vrai token Claude)
if [ "${POC_RESOURCES_ALLOWED:-}" = "claude_token" ] || [ "${POC_RESOURCES_ALLOWED:-}" = "all" ]; then
  T=$(mktemp -d /tmp/poc-resume-XXXXXX)
  mkdir -p "$T/.claude"
  if [ -r /home/starfleet/.claude/.credentials.json ]; then
    cp /home/starfleet/.claude/.credentials.json "$T/.claude/.credentials.json"
    chmod 600 "$T/.claude/.credentials.json"
    FAKE_UUID="00000000-0000-4000-8000-000000000000"
    OUT2=$(HOME="$T" claude -p "hi" --resume "$FAKE_UUID" --output-format json \
      --model haiku --no-session-persistence --setting-sources "" 2>&1 | head -c 500)
    # R-04c : durci en FAIL si la detection ne sort pas un message explicite
    if echo "$OUT2" | grep -qiE 'not found|unknown|no such|error|invalid'; then
      echo "[PASS] --resume sur session absente rejete explicitement (message: $(echo "$OUT2" | head -c 100))"
    else
      echo "[FAIL] --resume sur session absente n a pas de message d erreur explicite"
      echo "    output: $(echo "$OUT2" | head -c 200)"
      rm -rf "$T"
      exit 1
    fi
  else
    echo "[GAP] credentials starfleet non lisibles pour le test --resume (skip)"
  fi
  rm -rf "$T"
else
  # Default : skip + expliciter pourquoi, pas de GAP (l assertion N est
  # pas manquante, elle est optionnelle-par-design)
  echo "[OBS] volet --resume skip (POC_RESOURCES_ALLOWED!=claude_token, evite consommation token)"
fi

exit 0
