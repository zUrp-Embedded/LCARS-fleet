# qualifier-double-verification

**Source** : `work/moon-shot/10-beyond/beyond-contrat-runtime-minimal.md` §4 "Vérification indépendante (FG-01)"
**Date** : 2026-04-20
**Dernière révision** : 2026-04-20
**Statut** : DRAFT
**Référencé par** : `contrat-runtime-minimal/README.md`

## Contrat

Le qualifier est un LLM. Il peut halluciner `tests_passed: 7` alors
que 3/7 ont échoué. Pour éviter la gate molle :

1. Qualifier rejoue les tests et produit `gate_data` dans son rapport
2. **Fleet-pilot rejoue les tests indépendamment** (subprocess
   `pytest` ou équivalent selon stack) et produit `gate_data_verified`
3. Gate PASS ssi `gate_data == gate_data_verified` ET critères
   binaires satisfaits
4. Discordance → event `qualifier.untruthful` + gate FAIL + escalade

C'est le split mécanique/cognitif poussé à la gate.

## Observable

- Donné un repo projet + un rapport qualifier,
  `verify_gate_data(repo, report) → gate_data_verified`
- Comparaison dict-à-dict → match ou mismatch explicite
- Événement `qualifier.untruthful` émis sur mismatch

## Ce que le test vérifiera

- Repo sample (pytest) + rapport qualifier honnête → match PASS
- Même repo + rapport qualifier mentant (`tests_passed: 7` alors que
  runtime dit 5/7) → mismatch détecté, event `qualifier.untruthful`
- Rapport manquant `gate_data` → fail-closed (couvert par
  gate-data-contract)

## Pourquoi DRAFT

Besoin d'une sous-spec "verify_gate_data" par stack (python+pytest,
js+jest, rust+cargo-test, …). Hors scope contrat-runtime-minimal,
appartient plutôt à `04-phase-1-core/fleet-pilot/` ou à un doc dédié.

À miroir quand on arrive à `fleet-pilot-architecture.md`.
