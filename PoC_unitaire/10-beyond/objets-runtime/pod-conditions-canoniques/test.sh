#!/bin/bash
# SOURCE: test.sh
# AUTHOR: STARFLEET
# STARDATE: 2026.110
# STATUS: PROVEN
# Ancrage contrat en dur (pattern R-01 consultant).
set -u
HERE=$(dirname "$(readlink -f "$0")")

python3 -c "
import sys
sys.path.insert(0, '$HERE/impl-python')
from conditions import CANONICAL_CONDITIONS, MONOTONE_ORDER, EMITTED_AT, is_monotone

# ANCRE CORPUS (beyond-objets-runtime-v2.md §1 Conditions canoniques)
CORPUS_CONDITIONS = {
    'HomeProjected', 'ContextInjected', 'ProcessLaunched',
    'StreamAlive', 'OutputExtracted', 'HomeReleased',
}
CORPUS_MONOTONE = [
    'HomeProjected', 'ContextInjected', 'ProcessLaunched',
    'OutputExtracted', 'HomeReleased',
]
CORPUS_EMITTED_AT = {
    'HomeProjected': 'PROJECT',
    'ContextInjected': 'INJECT',
    'ProcessLaunched': 'LAUNCH',
    'StreamAlive': 'MONITOR',
    'OutputExtracted': 'EXTRACT',
    'HomeReleased': 'RELEASE',
}

# 1. Set des conditions = corpus
if CANONICAL_CONDITIONS != CORPUS_CONDITIONS:
    diff_plus = CORPUS_CONDITIONS - CANONICAL_CONDITIONS
    diff_minus = CANONICAL_CONDITIONS - CORPUS_CONDITIONS
    print(f'[FAIL] CANONICAL_CONDITIONS diverge du corpus')
    print(f'    manquent: {diff_plus}')
    print(f'    en trop: {diff_minus}')
    sys.exit(1)
print(f'[PASS] 6 conditions canoniques = corpus')

# 2. Ordre monotone = corpus
if MONOTONE_ORDER != CORPUS_MONOTONE:
    print(f'[FAIL] MONOTONE_ORDER diverge: {MONOTONE_ORDER} vs corpus {CORPUS_MONOTONE}')
    sys.exit(1)
print(f'[PASS] ordre monotone conforme au spawn cycle (5 conditions en sequence)')

# 3. EMITTED_AT complet et coherent
if EMITTED_AT != CORPUS_EMITTED_AT:
    print(f'[FAIL] EMITTED_AT diverge du corpus')
    sys.exit(1)
print(f'[PASS] mapping condition -> etape spawn cycle conforme')

# 4. is_monotone : StreamAlive doit etre non-monotone
assert is_monotone('StreamAlive') is False, 'StreamAlive doit etre non-monotone'
print(f'[PASS] StreamAlive detecte non-monotone (toggle autorise)')

# 5. is_monotone : les 5 autres doivent etre monotones
for c in CORPUS_MONOTONE:
    assert is_monotone(c) is True, f'{c} doit etre monotone'
print(f'[PASS] 5 conditions monotones correctement classees')

# 6. is_monotone : condition inconnue -> ValueError
try:
    is_monotone('UnknownCondition')
    print('[FAIL] condition inconnue devrait raise')
    sys.exit(1)
except ValueError:
    pass
print(f'[PASS] is_monotone raise ValueError sur condition inconnue')
"
exit $?
