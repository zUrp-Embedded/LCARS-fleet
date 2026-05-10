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
from gate_data import evaluate_gate

# T1 PASS
r1 = '''Rapport qualifier...

Constats prose...

# --- gate_data ---
gate_data:
  tests_total: 7
  tests_passed: 7
  compilation: clean
  lint: clean
  type_check: clean
'''
v, why = evaluate_gate(r1)
assert v == 'PASS', f'T1 expected PASS, got {v}: {why}'
print(f'[PASS] T1 complet clean -> PASS')

# T2 tests partiels
r2 = r1.replace('tests_passed: 7', 'tests_passed: 5')
v, why = evaluate_gate(r2)
assert v == 'FAIL'
print(f'[PASS] T2 5/7 tests -> FAIL ({why})')

# T3 compilation errors
r3 = r1.replace('compilation: clean', 'compilation: errors')
v, why = evaluate_gate(r3)
assert v == 'FAIL'
print(f'[PASS] T3 compilation=errors -> FAIL ({why})')

# T4 fail-closed : pas de bloc
v, why = evaluate_gate('Rapport prose sans gate data.')
assert v == 'FAIL'
print(f'[PASS] T4 pas de bloc -> FAIL fail-closed ({why})')

# T5 champ manquant
r5 = '''# --- gate_data ---
gate_data:
  tests_total: 7
  tests_passed: 7
'''
v, why = evaluate_gate(r5)
assert v == 'FAIL'
print(f'[PASS] T5 champ compilation manquant -> FAIL ({why})')

# T6 compilation valeur bogue
r6 = r1.replace('compilation: clean', 'compilation: foobar')
v, why = evaluate_gate(r6)
assert v == 'FAIL'
print(f'[PASS] T6 compilation valeur hors enum -> FAIL ({why})')

# T7 vulcan F3 fix: lint et type_check sont maintenant obligatoires + valides
# T7a lint errors -> FAIL
r7a = r1.replace('lint: clean', 'lint: errors')
v, why = evaluate_gate(r7a)
assert v == 'FAIL'
print(f'[PASS] T7a lint=errors -> FAIL ({why})')

# T7b lint valeur hors enum -> FAIL
r7b = r1.replace('lint: clean', 'lint: foobar')
v, why = evaluate_gate(r7b)
assert v == 'FAIL'
print(f'[PASS] T7b lint hors enum -> FAIL ({why})')

# T8a type_check errors -> FAIL
r8a = r1.replace('type_check: clean', 'type_check: errors')
v, why = evaluate_gate(r8a)
assert v == 'FAIL'
print(f'[PASS] T8a type_check=errors -> FAIL ({why})')

# T8b type_check n/a -> PASS (stack sans type system)
r8b = r1.replace('type_check: clean', 'type_check: n/a')
v, why = evaluate_gate(r8b)
assert v == 'PASS', f'T8b expected PASS, got {v}: {why}'
print(f'[PASS] T8b type_check=n/a -> PASS (stack sans type system)')

# T9 champ lint manquant -> FAIL (F3 fix : 5 champs requis, pas 3)
r9 = '''# --- gate_data ---
gate_data:
  tests_total: 7
  tests_passed: 7
  compilation: clean
  type_check: clean
'''
v, why = evaluate_gate(r9)
assert v == 'FAIL'
print(f'[PASS] T9 champ lint manquant -> FAIL ({why})')

# R-07 fix: cas negatifs additionnels

# T10 tests_passed > tests_total (overshoot inconsistant)
r10 = r1.replace('tests_passed: 7', 'tests_passed: 10')
v, why = evaluate_gate(r10)
assert v == 'FAIL'
assert 'overshoot' in why
print(f'[PASS] T10 tests_passed=10 > tests_total=7 -> FAIL ({why})')

# T11 tests_total=0 (pas de tests = gate invalide)
r11 = r1.replace('tests_total: 7', 'tests_total: 0').replace('tests_passed: 7', 'tests_passed: 0')
v, why = evaluate_gate(r11)
assert v == 'FAIL'
print(f'[PASS] T11 tests_total=0 -> FAIL ({why})')

# T12 gate_data commente + vrai bloc absent (R-07 : commente ne doit pas match)
r12 = '''Rapport prose...
# gate_data:
#   tests_total: 7
#   tests_passed: 7
#   compilation: clean
#   lint: clean
#   type_check: clean
Suite prose sans vrai bloc.
'''
v, why = evaluate_gate(r12)
assert v == 'FAIL'
print(f'[PASS] T12 gate_data tout commente -> FAIL fail-closed ({why})')

# T13 faux bloc en tete (commente) + vrai bloc en fin -> prendre le vrai
r13 = '''Rapport prose...
# gate_data:
#   tests_total: 7
#   tests_passed: 3
#   compilation: errors

Constats...

# --- gate_data ---
gate_data:
  tests_total: 7
  tests_passed: 7
  compilation: clean
  lint: clean
  type_check: clean
'''
v, why = evaluate_gate(r13)
assert v == 'PASS', f'T13 expected PASS (le vrai bloc clean en fin), got {v}: {why}'
print(f'[PASS] T13 commente-en-tete + vrai bloc fin -> PASS (bloc commente ignore)')

# T14 deux vrais blocs gate_data : le second gagne (docstring dit dernier)
r14 = '''# --- gate_data ---
gate_data:
  tests_total: 7
  tests_passed: 3
  compilation: errors
  lint: clean
  type_check: clean

Correction apres re-run...

# --- gate_data ---
gate_data:
  tests_total: 7
  tests_passed: 7
  compilation: clean
  lint: clean
  type_check: clean
'''
v, why = evaluate_gate(r14)
assert v == 'PASS', f'T14 expected PASS (dernier bloc), got {v}: {why}'
print(f'[PASS] T14 deux blocs : dernier gagne (aligne docstring)')
"
exit $?
