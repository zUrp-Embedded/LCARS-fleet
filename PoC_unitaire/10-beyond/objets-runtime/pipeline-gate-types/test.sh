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
from gates import evaluate_gate, validate_pipeline_gates, InvalidGate, ALLOWED_GATE_TYPES, ALLOWED_TERMINAL_OUTCOMES

# ANCRE CORPUS (beyond-objets-runtime-v2.md §3)
CORPUS_GATE_TYPES = {'hard', 'soft', 'terminal'}
CORPUS_TERMINAL_OUTCOMES = {'promote', 'retry', 'escalate'}

assert ALLOWED_GATE_TYPES == CORPUS_GATE_TYPES, f'types divergent: {ALLOWED_GATE_TYPES}'
print('[PASS] ALLOWED_GATE_TYPES = corpus (hard/soft/terminal)')

assert ALLOWED_TERMINAL_OUTCOMES == CORPUS_TERMINAL_OUTCOMES
print('[PASS] ALLOWED_TERMINAL_OUTCOMES = corpus (promote/retry/escalate)')

# T1 hard + pass
assert evaluate_gate('hard', 'pass') == 'continue'
print('[PASS] T1 hard pass -> continue')

# T2 hard + fail + on_fail_spec
assert evaluate_gate('hard', 'fail', 'retry-engineer') == 'retry-engineer'
print('[PASS] T2 hard fail + on_fail_spec -> next action')

# T3 hard + fail sans on_fail_spec -> erreur
try:
    evaluate_gate('hard', 'fail')
    print('[FAIL] T3 hard fail sans spec devrait raise')
    sys.exit(1)
except InvalidGate:
    print('[PASS] T3 hard fail sans on_fail_spec -> InvalidGate')

# T4 soft + pass -> continue (advisory)
assert evaluate_gate('soft', 'pass') == 'continue'
print('[PASS] T4 soft pass -> continue')

# T5 soft + fail -> continue (advisory, ne bloque pas)
assert evaluate_gate('soft', 'fail') == 'continue'
print('[PASS] T5 soft fail -> continue (advisory, pas de blocage)')

# T6 terminal + promote
assert evaluate_gate('terminal', 'promote') == 'create_delivery'
print('[PASS] T6 terminal promote -> create_delivery')

# T7 terminal + retry
assert evaluate_gate('terminal', 'retry') == 'retry_attempt'
print('[PASS] T7 terminal retry -> retry_attempt')

# T8 terminal + escalate
assert evaluate_gate('terminal', 'escalate') == 'escalate_architect'
print('[PASS] T8 terminal escalate -> escalate_architect')

# T9 type gate inconnu -> raise
try:
    evaluate_gate('mystery', 'pass')
    print('[FAIL] T9 type inconnu devrait raise')
    sys.exit(1)
except InvalidGate:
    print('[PASS] T9 type inconnu -> InvalidGate')

# T10 terminal + outcome inconnu
try:
    evaluate_gate('terminal', 'whatever')
    print('[FAIL] T10 terminal outcome inconnu devrait raise')
    sys.exit(1)
except InvalidGate:
    print('[PASS] T10 terminal outcome inconnu -> InvalidGate')

# T11 hard + result inconnu
try:
    evaluate_gate('hard', 'whatever')
    print('[FAIL] T11 hard result inconnu devrait raise')
    sys.exit(1)
except InvalidGate:
    print('[PASS] T11 hard result inconnu -> InvalidGate')

# T12 pipeline valide (1 terminal)
validate_pipeline_gates({
    'engineer': {'gate': {'type': 'hard'}},
    'qualifier': {'gate': {'type': 'hard'}},
    'reviewer': {'gate': {'type': 'soft'}},
    'gatekeeper': {'gate': {'type': 'terminal'}},
})
print('[PASS] T12 pipeline 1 terminal : valide')

# T13 pipeline avec 2 terminaux -> rejet
try:
    validate_pipeline_gates({
        'a': {'gate': {'type': 'terminal'}},
        'b': {'gate': {'type': 'terminal'}},
    })
    print('[FAIL] T13 2 terminaux non rejetes')
    sys.exit(1)
except InvalidGate:
    print('[PASS] T13 2 terminaux rejetes')

# T14 pipeline sans gates : valide
validate_pipeline_gates({'a': {}, 'b': {}})
print('[PASS] T14 pipeline sans gates : valide')
"
exit $?
