#!/bin/bash
# SOURCE: test.sh
# AUTHOR: STARFLEET
# STARDATE: 2026.110
# STATUS: PROVEN
# R-01 fix : contrat TRANSITIONS ancre en dur (corpus §3.3).
# R-06 fix : assertion explicite TERMINAL.
set -u
HERE=$(dirname "$(readlink -f "$0")")

python3 -c "
import sys
sys.path.insert(0, '$HERE/impl-python')
from attempt_phase import AttemptPhase, transition, IllegalTransition, TRANSITIONS, TERMINAL

# ANCRE CORPUS (beyond-contrat-runtime-minimal.md §3.3)
EXPECTED_TRANSITIONS = {
    (None, 'Pending'),
    ('Pending', 'Running'),
    ('Running', 'Succeeded'),
    ('Running', 'Failed'),
    ('Running', 'Interrupted'),
    ('Running', 'Lost'),
    ('Running', 'Running'),  # passage stage suivant
}
EXPECTED_TERMINAL = {'Succeeded', 'Failed', 'Interrupted', 'Lost'}

# 1. Compare impl vs corpus
impl_trans = {(f.value if f else None, t.value) for f, t in TRANSITIONS}
if impl_trans != EXPECTED_TRANSITIONS:
    diff_plus = EXPECTED_TRANSITIONS - impl_trans
    diff_minus = impl_trans - EXPECTED_TRANSITIONS
    print(f'[FAIL] impl.TRANSITIONS diverge du contrat corpus')
    print(f'    manquent: {diff_plus}')
    print(f'    en trop: {diff_minus}')
    sys.exit(1)
print(f'[PASS] impl.TRANSITIONS = contrat corpus (7 transitions nommees §3.3)')

impl_terminal = {p.value for p in TERMINAL}
if impl_terminal != EXPECTED_TERMINAL:
    print(f'[FAIL] impl.TERMINAL diverge: {impl_terminal} vs {EXPECTED_TERMINAL}')
    sys.exit(1)
print(f'[PASS] impl.TERMINAL = corpus (Succeeded, Failed, Interrupted, Lost)')

# 2. Exhaustif : 7 sources x 6 cibles = 42 paires
ALL = [None] + list(AttemptPhase)
total = 0; ok = 0; illegal = 0
for frm in ALL:
    for to in list(AttemptPhase):
        total += 1
        exp = (frm.value if frm else None, to.value) in EXPECTED_TRANSITIONS
        try:
            transition(frm, to); legal = True
        except IllegalTransition:
            legal = False
        if legal != exp:
            print(f'[FAIL] {frm}->{to}: exp={exp} got={legal}')
            sys.exit(1)
        if legal: ok += 1
        else: illegal += 1

print(f'[OBS] {total} paires testees (7 sources x 6 cibles)')
print(f'[PASS] {ok} transitions autorisees conformes au contrat')
print(f'[PASS] {illegal} transitions interdites correctement refusees')

# 3. Invariance terminaux
if not EXPECTED_TERMINAL:
    print('[FAIL] EXPECTED_TERMINAL vide')
    sys.exit(1)
for t_val in EXPECTED_TERMINAL:
    t = AttemptPhase(t_val)
    for to in AttemptPhase:
        try:
            transition(t, to)
            print(f'[FAIL] {t} terminal partable vers {to}')
            sys.exit(1)
        except IllegalTransition:
            pass
print(f'[PASS] 4 terminaux ({sorted(EXPECTED_TERMINAL)}) immutables')
"
exit $?
