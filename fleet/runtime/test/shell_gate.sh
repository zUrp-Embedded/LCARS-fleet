#!/usr/bin/env bash
# SOURCE: test/shell_gate.sh
# AUTHOR: starfleet
# STARDATE: 0000.000
# STATUS: filet des tests HORS-mix (python + bats des launchers) — le trou que `mix gate` ne voit pas.
#
# RAISON D'ETRE : `mix gate` = compile + `mix test` (ExUnit) + contracts.check. Il ne lance AUCUN
# test shell/python. Un test comme test/test_fleet_mcp_stdio_bridge.py peut donc devenir ROUGE en
# silence (le bridge renomme, le test jamais rejoue) — c'est exactement le bug qui a motive ce filet.
# Ce script est le point d'entree unique des tests hors-mix, cablable dans `mix gate` (cf. mix.exs).
#
# CONTRAT anti-faux-vert :
#   - python3 ABSENT               → ECHEC EXPLICITE (jamais un skip silencieux : c'est la lecon du bug).
#   - 0 test compte OU FAIL>0      → exit != 0 (jamais vert sans compteur positif — la « coquille vide »
#                                     qui passe est l'anti-pattern precis a tuer).
#   - bats PRESENT + rouge         → exit != 0.
#   - bats ABSENT                  → PAS d'echec ICI (warning + compte MANQUE). Choix delibere : ce filet
#                                     est cable dans `mix gate`, l'absence de bats sur une machine sans
#                                     bats-core ne doit pas casser le gate de tous. A DURCIR en echec le
#                                     jour ou bats-core est un prerequis pose (installe partout / en CI) :
#                                     passer BATS_MISSING_FATAL=1 (ou flipper le defaut ci-dessous).
set -euo pipefail

HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
PYTEST="$HERE/test_fleet_mcp_stdio_bridge.py"

# Politique bats-absent : warning compte (defaut) vs echec dur. Overridable par env pour le jour du
# durcissement, sans re-editer le script. Defaut 0 = warning (cf. contrat ci-dessus).
BATS_MISSING_FATAL="${BATS_MISSING_FATAL:-0}"

GATE_FAIL=0

echo "=== shell_gate : tests hors-mix (python + bats des launchers) ==="

# ---------------------------------------------------------------------------
# 1) Test python du bridge MCP stdio.
# ---------------------------------------------------------------------------
if ! command -v python3 >/dev/null 2>&1; then
  # python3 absent = le test NE PEUT PAS tourner. On ECHOUE au lieu de sauter en silence : un « pas de
  # python donc on passe » masquerait exactement la classe de bug (test jamais joue) que ce filet attrape.
  echo "ECHEC: python3 absent — impossible de lancer $PYTEST (pas de skip silencieux)." >&2
  exit 1
fi

if [[ ! -f "$PYTEST" ]]; then
  echo "ECHEC: fichier de test introuvable : $PYTEST" >&2
  exit 1
fi

# On capture sortie + code retour SANS que set -e n'avorte le script sur un test rouge (on veut le
# decompte, pas un abandon a la premiere ligne FAIL).
set +e
PY_OUT="$(python3 "$PYTEST" 2>&1)"
PY_RC=$?
set -e

echo "$PY_OUT"

# Decompte a partir des lignes emises par check() : « PASS: ... » / « FAIL: ... » (ancre en debut de
# ligne pour ne PAS attraper le « ALL PASS » du verdict). grep -c sort 0 + exit 1 quand rien ne matche
# → `|| true` neutralise le exit sous set -e, la valeur « 0 » reste correcte.
PASS_N="$(printf '%s\n' "$PY_OUT" | grep -c '^PASS: ' || true)"
FAIL_N="$(printf '%s\n' "$PY_OUT" | grep -c '^FAIL: ' || true)"
TOTAL_N=$((PASS_N + FAIL_N))

echo "--- python : PASS=$PASS_N FAIL=$FAIL_N (exit=$PY_RC) ---"

if [[ "$TOTAL_N" -eq 0 ]]; then
  # 0 test compte = coquille vide (fichier casse, import qui plante avant tout check, refactor qui a
  # vide les assertions...). Vert sans compteur positif est INTERDIT : on echoue.
  echo "ECHEC: 0 test python lance (coquille vide) — un gate vert doit avoir un compteur positif." >&2
  GATE_FAIL=1
elif [[ "$FAIL_N" -gt 0 || "$PY_RC" -ne 0 ]]; then
  # FAIL>0 (assertion rouge) OU exit!=0 (crash / verdict d'echec du test) → rouge.
  echo "ECHEC: test python rouge (FAIL=$FAIL_N, exit=$PY_RC)." >&2
  GATE_FAIL=1
fi

# ---------------------------------------------------------------------------
# 2) Tests bats : les launchers (bwrap_launch, claude_launch) ET les skills du depot. Ranges en
#    sous-dossiers → recherche recursive (pas un simple glob test/*.bats). LE test bats de
#    bwrap_launch ne se contourne pas : s'il est joignable (bats present) il DOIT etre vert.
#
#    Les skills de `.claude/skills/*/tests/` sont inclus parce qu'un skill qui MESURE (le toolkit
#    d'etat de starfleet) est un instrument : non teste, il rapporte des verdicts que rien ne
#    verifie. Le repertoire est hors du runtime, d'ou la seconde recherche ; son absence n'est pas
#    une erreur (un depot sans skills reste valide).
#
#    `fleet/git-hooks/tests/` : meme raison encore. Le pre-commit est le SEUL mur qui s'applique a
#    tout le depot, y compris a lui-meme, et il n'avait aucun test — un mur non teste ne se
#    distingue d'un mur absent que le jour ou on le contourne.
#
#    `fleet/provisioning_v2/tests/` : ajoute le 2026-08-05. Ces suites existaient depuis le
#    2026-07-30 et AUCUN gate ne les jouait — un test que personne ne lance est un test qui
#    pourrit, et il donne la couverture sans la donner. Meme raison que les skills : le
#    provisioning est ce qui fabrique la machine sur laquelle tout le reste tourne. Absence du
#    repertoire = pas une erreur (meme regle que les skills).
# ---------------------------------------------------------------------------
REPO_ROOT="$(cd "$HERE/../../.." && pwd)"
SKILLS_TESTS="$REPO_ROOT/.claude/skills"
PROVISION_TESTS="$REPO_ROOT/fleet/provisioning_v2/tests"
HOOK_TESTS="$REPO_ROOT/fleet/git-hooks/tests"
mapfile -t BATS_FILES < <(
  find "$HERE" -type f -name '*.bats'
  [[ -d "$SKILLS_TESTS" ]] && find "$SKILLS_TESTS" -type f -path '*/tests/*.bats'
  [[ -d "$PROVISION_TESTS" ]] && find "$PROVISION_TESTS" -type f -name '*.bats'
  [[ -d "$HOOK_TESTS" ]] && find "$HOOK_TESTS" -type f -name '*.bats'
  true
)
mapfile -t BATS_FILES < <(printf '%s\n' "${BATS_FILES[@]}" | sort -u)
BATS_FILE_COUNT="${#BATS_FILES[@]}"
# Nombre de cas @test (info plus fine que le nb de fichiers pour l'avertissement « N tests manques »).
if [[ "$BATS_FILE_COUNT" -gt 0 ]]; then
  BATS_TEST_COUNT="$(grep -hcE '^@test' "${BATS_FILES[@]}" 2>/dev/null | awk '{s+=$1} END {print s+0}')"
else
  BATS_TEST_COUNT=0
fi

if [[ "$BATS_FILE_COUNT" -eq 0 ]]; then
  echo "--- bats : aucun fichier .bats trouve sous $HERE (rien a lancer) ---"
elif command -v bats >/dev/null 2>&1; then
  echo "--- bats : $BATS_FILE_COUNT fichier(s), $BATS_TEST_COUNT test(s) launchers+skills+provisioning+hooks — execution ---"
  set +e
  bats "${BATS_FILES[@]}"
  BATS_RC=$?
  set -e
  if [[ "$BATS_RC" -ne 0 ]]; then
    echo "ECHEC: suite bats rouge (exit=$BATS_RC)." >&2
    GATE_FAIL=1
  else
    echo "--- bats : OK ($BATS_TEST_COUNT test(s)) ---"
  fi
else
  # bats ABSENT : on ne saute pas en silence — on COMPTE les tests non joues et on avertit fort.
  echo "AVERTISSEMENT: bats absent — $BATS_TEST_COUNT test(s) launchers NON executes" \
       "($BATS_FILE_COUNT fichier(s) : bwrap_launch/claude_launch). Installer : apt/brew install bats-core." >&2
  if [[ "$BATS_MISSING_FATAL" != "0" ]]; then
    echo "ECHEC: bats absent et BATS_MISSING_FATAL=$BATS_MISSING_FATAL — durcissement actif." >&2
    GATE_FAIL=1
  fi
fi

# ---------------------------------------------------------------------------
# Verdict.
# ---------------------------------------------------------------------------
echo "=== shell_gate : PASS=$PASS_N FAIL=$FAIL_N (python) | bats=$BATS_TEST_COUNT test(s) $(command -v bats >/dev/null 2>&1 && echo joues || echo MANQUES) ==="
if [[ "$GATE_FAIL" -ne 0 ]]; then
  echo "=== shell_gate : ECHEC ==="
  exit 1
fi
echo "=== shell_gate : VERT ==="
exit 0
