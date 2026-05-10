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
from delivery import validate_delivery, InvalidDelivery, REQUIRED_FIELDS

# ANCRE CORPUS (beyond-objets-runtime-v2.md §2 Delivery)
CORPUS_REQUIRED = {
    'artifacts',
    'qualifierReport',
    'reviewerReport',
    'reviewerScore',
    'gatekeeperDecision',
    'gatekeeperJustification',
}
assert REQUIRED_FIELDS == CORPUS_REQUIRED
print('[PASS] REQUIRED_FIELDS = corpus (6 champs)')

VALID = {
    'artifacts': [{'type': 'branch', 'ref': 'feature/x'}],
    'qualifierReport': 'events/att_002/rapport-qualifier.md',
    'reviewerReport': 'events/att_002/rapport-reviewer.md',
    'reviewerScore': 9,
    'gatekeeperDecision': 'promote',
    'gatekeeperJustification': 'Score 9/10, aucun finding majeur',
}

# T1 : delivery complete valide
validate_delivery(VALID)
print('[PASS] T1 delivery complete valide')

# T2 : champ manquant (decline chacun)
for field in CORPUS_REQUIRED:
    incomplete = {k: v for k, v in VALID.items() if k != field}
    try:
        validate_delivery(incomplete)
        print(f'[FAIL] T2 manque {field} non detecte')
        sys.exit(1)
    except InvalidDelivery:
        pass
print('[PASS] T2 chaque champ manquant detecte (6 cas)')

# T3 : gatekeeperDecision=retry -> rejet (contradiction)
bad = dict(VALID, gatekeeperDecision='retry')
try:
    validate_delivery(bad)
    print('[FAIL] T3 decision=retry non rejetee')
    sys.exit(1)
except InvalidDelivery as e:
    print(f'[PASS] T3 decision!=promote rejete : {e}')

# T4 : reviewerScore hors range (15)
try:
    validate_delivery(dict(VALID, reviewerScore=15))
    print('[FAIL] T4 score=15 non rejete')
    sys.exit(1)
except InvalidDelivery:
    print('[PASS] T4 score=15 rejete (hors range [0,10])')

# T5 : reviewerScore hors range (-1)
try:
    validate_delivery(dict(VALID, reviewerScore=-1))
    print('[FAIL] T5 score=-1 non rejete')
    sys.exit(1)
except InvalidDelivery:
    print('[PASS] T5 score=-1 rejete')

# T6 : reviewerScore mauvais type
try:
    validate_delivery(dict(VALID, reviewerScore='nine'))
    print('[FAIL] T6 score str non rejete')
    sys.exit(1)
except InvalidDelivery:
    print('[PASS] T6 score str rejete (must be int)')

# T7 : artifacts vide
try:
    validate_delivery(dict(VALID, artifacts=[]))
    print('[FAIL] T7 artifacts vide non rejete')
    sys.exit(1)
except InvalidDelivery:
    print('[PASS] T7 artifacts vide rejete')

# T8 : gatekeeperJustification vide
try:
    validate_delivery(dict(VALID, gatekeeperJustification=''))
    print('[FAIL] T8 justification vide non rejetee')
    sys.exit(1)
except InvalidDelivery:
    print('[PASS] T8 justification vide rejetee')

# T9 : gatekeeperJustification espaces blancs
try:
    validate_delivery(dict(VALID, gatekeeperJustification='   '))
    print('[FAIL] T9 justification whitespace non rejetee')
    sys.exit(1)
except InvalidDelivery:
    print('[PASS] T9 justification whitespace rejetee')

# T10 : reviewerScore bornes (0 et 10 acceptes)
for s in (0, 10):
    validate_delivery(dict(VALID, reviewerScore=s))
print('[PASS] T10 score=0 et score=10 acceptes (bornes inclusives)')
"
exit $?
