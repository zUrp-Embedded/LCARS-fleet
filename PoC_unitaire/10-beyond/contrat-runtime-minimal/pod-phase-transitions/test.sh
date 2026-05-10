#!/bin/bash
# SOURCE: test.sh
# AUTHOR: STARFLEET
# STARDATE: 2026.110
# STATUS: PROVEN
# R-01 fix (consultant 2026-04-20) : le contrat TRANSITIONS est ancre en
# dur dans le test, pas importe de l impl. Le test compare l impl au
# contrat corpus — une impl qui mentirait (swap d une paire gardant le
# cardinal) serait detectee par la comparaison de sets, pas juste par
# le cardinal.
# R-09 fix : 6 etats x 5 cibles = 30 paires (pas 25 comme l ancien OBS le disait).
set -u
HERE=$(dirname "$(readlink -f "$0")")

python3 -c "
import sys
sys.path.insert(0, '$HERE/impl-python')
from pod_phase import PodPhase, transition, IllegalTransition, TRANSITIONS, TERMINAL

# ANCRE CORPUS (beyond-contrat-runtime-minimal.md §3.1) — hardcoded dans le test,
# pas imports depuis l impl. C est le contrat qu on verifie.
EXPECTED_TRANSITIONS = {
    (None, 'Pending'),
    ('Pending', 'Running'),
    ('Pending', 'Failed'),
    ('Running', 'Succeeded'),
    ('Running', 'Failed'),
    ('Running', 'Unknown'),
    ('Unknown', 'Failed'),
}
EXPECTED_TERMINAL = {'Succeeded', 'Failed'}

# 1. Comparaison impl vs contrat corpus
impl_trans = {(f.value if f else None, t.value) for f, t in TRANSITIONS}
if impl_trans != EXPECTED_TRANSITIONS:
    diff_plus = EXPECTED_TRANSITIONS - impl_trans
    diff_minus = impl_trans - EXPECTED_TRANSITIONS
    print(f'[FAIL] impl.TRANSITIONS diverge du contrat corpus')
    print(f'    manquent dans impl: {diff_plus}')
    print(f'    en trop dans impl: {diff_minus}')
    sys.exit(1)
print(f'[PASS] impl.TRANSITIONS = contrat corpus (7 transitions nommees §3.1)')

impl_terminal = {p.value for p in TERMINAL}
if impl_terminal != EXPECTED_TERMINAL:
    print(f'[FAIL] impl.TERMINAL diverge: {impl_terminal} vs corpus {EXPECTED_TERMINAL}')
    sys.exit(1)
print(f'[PASS] impl.TERMINAL = contrat corpus (Succeeded, Failed)')

# 2. Exhaustif : toutes les paires (None + 5 etats) x 5 etats cibles = 30 paires
ALL = [None] + list(PodPhase)
total = 0
ok = 0
illegal = 0
for frm in ALL:
    for to in list(PodPhase):
        total += 1
        expected_legal = (
            (frm.value if frm else None, to.value) in EXPECTED_TRANSITIONS
        )
        try:
            transition(frm, to)
            legal = True
        except IllegalTransition:
            legal = False
        if legal != expected_legal:
            print(f'[FAIL] {frm} -> {to}: expected legal={expected_legal} got legal={legal}')
            sys.exit(1)
        if legal: ok += 1
        else: illegal += 1

print(f'[OBS] {total} paires testees (6 sources x 5 cibles)')
print(f'[PASS] {ok} transitions autorisees conformes au contrat')
print(f'[PASS] {illegal} transitions interdites correctement refusees')

# 3. Invariance terminaux — verification explicite que TERMINAL est bien set,
# pas vide (adversaire R-06).
if not EXPECTED_TERMINAL:
    print(f'[FAIL] EXPECTED_TERMINAL ne doit pas etre vide')
    sys.exit(1)
for t_val in EXPECTED_TERMINAL:
    t = PodPhase(t_val)
    for to in PodPhase:
        try:
            transition(t, to)
            print(f'[FAIL] {t} terminal partable vers {to}')
            sys.exit(1)
        except IllegalTransition:
            pass
print(f'[PASS] etats terminaux ({sorted(EXPECTED_TERMINAL)}) sont immutables')
"
exit $?
