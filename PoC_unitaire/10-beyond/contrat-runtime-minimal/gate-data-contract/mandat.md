# gate-data-contract

**Source** : `work/moon-shot/10-beyond/beyond-contrat-runtime-minimal.md` §4 "Contrat gate_data"
**Date** : 2026-04-20
**Dernière révision** : 2026-04-20
**Statut** : PROVEN (parsing + validation logique)
**Référencé par** : `contrat-runtime-minimal/README.md`

## Contrat

Le rapport qualifier est prose (constats factuels), mais DOIT se
terminer par un bloc YAML structuré nommé `gate_data` :

```yaml
# --- gate_data ---
gate_data:
  tests_total: 7
  tests_passed: 7
  compilation: clean          # clean | errors | warnings
  lint: clean                 # clean | errors | warnings
  type_check: clean           # clean | errors | n/a
```

Fleet-pilot évalue :
`tests_passed == tests_total AND compilation == clean` → PASS, sinon FAIL.

**Règle fail-closed** : sans `gate_data`, le rapport est inévaluable →
gate FAIL par défaut.

## Observable

- Parsing : extraire le bloc `gate_data` d'un rapport markdown
- Validation : types + valeurs enum (compilation ∈ {clean,errors,warnings})
- Évaluation : binaire, pas de tolérance
- Fail-closed : rapport sans `gate_data` → FAIL

## Ce que le test vérifie

- Rapport valide avec gate_data PASS → évalué PASS
- Rapport avec `tests_passed < tests_total` → FAIL
- Rapport avec `compilation: errors` → FAIL
- Rapport sans bloc `gate_data` → FAIL (fail-closed)
- Rapport avec `gate_data` malformé → FAIL
