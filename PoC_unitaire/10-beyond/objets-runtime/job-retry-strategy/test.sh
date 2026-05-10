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
from retry import decide_retry, RetryDecision

STRATEGY = {
    'maxAttempts': 3,
    'retryOn': ['hard_gate_fail', 'interrupted_worker_crash'],
    'noRetryOn': ['scope_violation', 'policy_denied'],
}

# T1 : retryOn + budget
d = decide_retry('hard_gate_fail', attempts=1, strategy=STRATEGY)
assert d == RetryDecision.RETRY, f'T1: {d}'
print('[PASS] T1 retryOn + attempts=1/3 -> retry')

# T2 : retryOn + budget epuise
d = decide_retry('hard_gate_fail', attempts=3, strategy=STRATEGY)
assert d == RetryDecision.ESCALATE_FAILED
print('[PASS] T2 retryOn + attempts=3/3 -> escalate_failed (maxAttempts)')

# T3 : noRetryOn prime
d = decide_retry('scope_violation', attempts=1, strategy=STRATEGY)
assert d == RetryDecision.ESCALATE_FAILED
print('[PASS] T3 noRetryOn + budget -> escalate_failed (fail-closed)')

# T4 : raison non listee -> fail-closed escalate
d = decide_retry('mystery_reason', attempts=1, strategy=STRATEGY)
assert d == RetryDecision.ESCALATE_FAILED
print('[PASS] T4 raison inconnue + budget -> escalate_failed (fail-closed)')

# T5 : interrupted est une branche separee -> aborted
d = decide_retry('interrupted', attempts=1, strategy=STRATEGY)
assert d == RetryDecision.ESCALATE_ABORTED
print('[PASS] T5 reason=interrupted -> escalate_aborted (decision user/gatekeeper)')

# T6 : overlap retryOn + noRetryOn : noRetryOn prime (fail-closed)
overlap_strategy = {
    'maxAttempts': 3,
    'retryOn': ['ambiguous'],
    'noRetryOn': ['ambiguous'],
}
d = decide_retry('ambiguous', attempts=1, strategy=overlap_strategy)
assert d == RetryDecision.ESCALATE_FAILED
print('[PASS] T6 overlap retryOn+noRetryOn -> noRetryOn prime (fail-closed)')

# T7 : retryOn + dernier budget restant
d = decide_retry('hard_gate_fail', attempts=2, strategy=STRATEGY)
assert d == RetryDecision.RETRY
print('[PASS] T7 retryOn + attempts=2/3 -> retry (dernier budget)')

# T8 : strategy vide (pas de retryOn) -> toute raison escalate
empty_strategy = {'maxAttempts': 3, 'retryOn': [], 'noRetryOn': []}
d = decide_retry('anything', attempts=0, strategy=empty_strategy)
assert d == RetryDecision.ESCALATE_FAILED
print('[PASS] T8 strategy vide -> escalate_failed (fail-closed par defaut)')
"
exit $?
