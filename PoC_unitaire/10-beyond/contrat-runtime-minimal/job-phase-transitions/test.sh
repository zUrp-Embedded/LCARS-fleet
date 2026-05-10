#!/bin/bash
# SOURCE: test.sh
# AUTHOR: STARFLEET
# STARDATE: 2026.110
# STATUS: PROVEN
# R-01 fix : contrat TRANSITIONS ancre en dur dans le test (corpus §3.2).
# R-06 fix : assertion explicite TERMINAL non vide + match contrat.
set -u
HERE=$(dirname "$(readlink -f "$0")")

python3 -c "
import sys
sys.path.insert(0, '$HERE/impl-python')
from job_phase import JobPhase, transition, IllegalTransition, TRANSITIONS, TERMINAL

# ANCRE CORPUS (beyond-contrat-runtime-minimal.md §3.2)
EXPECTED_TRANSITIONS = {
    (None, 'Pending'),
    ('Pending', 'Running'),
    ('Running', 'Succeeded'),
    ('Running', 'Failed'),
    ('Running', 'Aborted'),
    ('Running', 'Suspended'),
    ('Suspended', 'Running'),
    ('Suspended', 'Aborted'),
    ('Running', 'Running'),  # retry (nouveau attempt, meme job)
}
EXPECTED_TERMINAL = {'Succeeded', 'Failed', 'Aborted'}

# 1. Compare impl vs corpus
impl_trans = {(f.value if f else None, t.value) for f, t in TRANSITIONS}
if impl_trans != EXPECTED_TRANSITIONS:
    diff_plus = EXPECTED_TRANSITIONS - impl_trans
    diff_minus = impl_trans - EXPECTED_TRANSITIONS
    print(f'[FAIL] impl.TRANSITIONS diverge du contrat corpus')
    print(f'    manquent: {diff_plus}')
    print(f'    en trop: {diff_minus}')
    sys.exit(1)
print(f'[PASS] impl.TRANSITIONS = contrat corpus (9 transitions nommees §3.2)')

impl_terminal = {p.value for p in TERMINAL}
if impl_terminal != EXPECTED_TERMINAL:
    print(f'[FAIL] impl.TERMINAL diverge du corpus : {impl_terminal} vs {EXPECTED_TERMINAL}')
    sys.exit(1)
print(f'[PASS] impl.TERMINAL = corpus (Succeeded, Failed, Aborted)')

# 2. Exhaustif : 7 sources (None + 6 etats) x 6 cibles = 42 paires
ALL = [None] + list(JobPhase)
total = 0
ok = 0
illegal = 0
for frm in ALL:
    for to in list(JobPhase):
        total += 1
        expected_legal = (frm.value if frm else None, to.value) in EXPECTED_TRANSITIONS
        try:
            transition(frm, to)
            legal = True
        except IllegalTransition:
            legal = False
        if legal != expected_legal:
            print(f'[FAIL] {frm} -> {to}: exp={expected_legal} got={legal}')
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
    t = JobPhase(t_val)
    for to in JobPhase:
        try:
            transition(t, to)
            print(f'[FAIL] {t} terminal partable vers {to}')
            sys.exit(1)
        except IllegalTransition:
            pass
print(f'[PASS] 3 terminaux ({sorted(EXPECTED_TERMINAL)}) immutables')

# 4. Retry Running->Running explicit (cas particulier §3.2)
try:
    transition(JobPhase.RUNNING, JobPhase.RUNNING)
    print('[PASS] Running -> Running autorise (retry semantique §3.2)')
except IllegalTransition:
    print('[FAIL] retry Running->Running bloque')
    sys.exit(1)
"
exit $?
