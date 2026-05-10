#!/bin/bash
# SOURCE: test.sh
# AUTHOR: STARFLEET
# STARDATE: 2026.110
# STATUS: PROVEN
# R-02 fix (consultant 2026-04-20) : EXPECTED_PROBES est ancre en dur dans
# le test, pas importe de l impl. Ajout du cas branche "extra probe" qui
# n etait pas couvert.
set -u
HERE=$(dirname "$(readlink -f "$0")")

python3 -c "
import sys
sys.path.insert(0, '$HERE/impl-python')
from ready import is_ready, EXPECTED_PROBES

# ANCRE CORPUS (beyond-contrat-runtime-minimal.md §3 Système READY)
CORPUS_PROBES = {
    'runtime_exists',
    'specs_readable',
    'credentials_avail',
    'event_log_writable',
    'pool_users_exist',
    'fleet_pilot_up',
}

# 1. impl vs corpus
if EXPECTED_PROBES != CORPUS_PROBES:
    diff_plus = CORPUS_PROBES - EXPECTED_PROBES
    diff_minus = EXPECTED_PROBES - CORPUS_PROBES
    print(f'[FAIL] impl.EXPECTED_PROBES diverge du corpus')
    print(f'    manquent: {diff_plus}')
    print(f'    en trop: {diff_minus}')
    sys.exit(1)
print(f'[PASS] impl.EXPECTED_PROBES = corpus (6 probes nommees)')

# 2. Tout True -> READY
all_true = {k: True for k in CORPUS_PROBES}
assert is_ready(all_true) is True
print('[PASS] 6/6 True -> READY')

# 3. 5/6 True -> NOT ready (conjonction stricte, chaque probe testee)
for miss in CORPUS_PROBES:
    r = {k: (k != miss) for k in CORPUS_PROBES}
    assert is_ready(r) is False, f'5/6 (missing {miss}) should be NOT ready'
print('[PASS] 5/6 True + 1 False -> NOT ready (conjonction stricte)')

# 4. 0/6 -> NOT ready
all_false = {k: False for k in CORPUS_PROBES}
assert is_ready(all_false) is False
print('[PASS] 0/6 -> NOT ready')

# 5. Branche missing : probe set reduit raise
try:
    is_ready({'runtime_exists': True})
    print('[FAIL] probe set reduit devrait raise')
    sys.exit(1)
except ValueError as e:
    assert 'missing' in str(e).lower()
print('[PASS] probe set reduit raise ValueError (branche missing)')

# 6. Branche extra : probe set avec clef en trop raise (R-02 fix)
extra = {**{k: True for k in CORPUS_PROBES}, 'rogue_probe': True}
try:
    is_ready(extra)
    print('[FAIL] probe set avec extra devrait raise')
    sys.exit(1)
except ValueError as e:
    assert 'extra' in str(e).lower()
print('[PASS] probe set avec extra raise ValueError (branche extra)')
"
exit $?
