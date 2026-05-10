#!/bin/bash
# SOURCE: test.sh
# AUTHOR: STARFLEET
# STARDATE: 2026.110
# STATUS: PROVEN
set -u
HERE=$(dirname "$(readlink -f "$0")")

python3 -c "
import sys
sys.path.insert(0, '$HERE/impl-python')
from dag import validate_dag, CycleDetected, UnknownStage

# T1 : DAG valide (chaine)
validate_dag({
    'engineer': {'needs': []},
    'qualifier': {'needs': ['engineer']},
    'reviewer': {'needs': ['qualifier']},
})
print('[PASS] T1 chaine engineer->qualifier->reviewer : DAG valide')

# T2 : DAG valide (diamant)
validate_dag({
    'a': {'needs': []},
    'b': {'needs': ['a']},
    'c': {'needs': ['a']},
    'd': {'needs': ['b', 'c']},
})
print('[PASS] T2 diamant a->{b,c}->d : DAG valide')

# T3 : cycle direct (A needs A)
try:
    validate_dag({'a': {'needs': ['a']}})
    print('[FAIL] T3 auto-cycle non detecte')
    sys.exit(1)
except CycleDetected as e:
    print(f'[PASS] T3 cycle auto (A->A) detecte : {e}')

# T4 : cycle a 2
try:
    validate_dag({'a': {'needs': ['b']}, 'b': {'needs': ['a']}})
    print('[FAIL] T4 cycle 2 non detecte')
    sys.exit(1)
except CycleDetected as e:
    print(f'[PASS] T4 cycle A<->B detecte : {e}')

# T5 : cycle a 3
try:
    validate_dag({'a': {'needs': ['b']}, 'b': {'needs': ['c']}, 'c': {'needs': ['a']}})
    print('[FAIL] T5 cycle 3 non detecte')
    sys.exit(1)
except CycleDetected as e:
    print(f'[PASS] T5 cycle A->B->C->A detecte : {e}')

# T6 : reference inconnue
try:
    validate_dag({'a': {'needs': ['phantom']}})
    print('[FAIL] T6 needs phantom non detecte')
    sys.exit(1)
except UnknownStage as e:
    print(f'[PASS] T6 needs inconnu detecte : {e}')

# T7 : pipeline vide
validate_dag({})
print('[PASS] T7 pipeline vide : DAG vacuously valide')

# T8 : stages independants (pas de needs)
validate_dag({'a': {}, 'b': {}, 'c': {}})
print('[PASS] T8 stages independants : DAG valide')

# T9 : chemin long sans cycle
validate_dag({
    'a': {'needs': []},
    'b': {'needs': ['a']},
    'c': {'needs': ['b']},
    'd': {'needs': ['c']},
    'e': {'needs': ['d']},
})
print('[PASS] T9 chemin de 5 sans cycle : valide')

# T10 : cycle subtil (A->B->C, D->A, cycle A->B->C->?) - faux test, test plutot :
# DAG avec plusieurs composantes dont une cyclique
try:
    validate_dag({
        'iso1': {'needs': []},
        'iso2': {'needs': []},
        'loop1': {'needs': ['loop2']},
        'loop2': {'needs': ['loop1']},
    })
    print('[FAIL] T10 cycle dans composante secondaire non detecte')
    sys.exit(1)
except CycleDetected as e:
    print(f'[PASS] T10 cycle dans composante secondaire detecte')
"
exit $?
