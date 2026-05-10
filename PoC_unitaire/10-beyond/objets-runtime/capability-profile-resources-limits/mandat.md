# capability-profile-resources-limits

**Source** : `work/moon-shot/10-beyond/beyond-objets-runtime-v2.md` §1 "CapabilityProfile" (resources)
**Date** : 2026-04-20
**Dernière révision** : 2026-04-20
**Statut** : DRAFT
**Référencé par** : `objets-runtime/README.md`

## Contrat

Chaque CapabilityProfile déclare :
- `resources.maxTokens` : budget tokens total pour le pod (int > 0)
- `resources.maxDuration` : durée max en secondes (int > 0)

Fleet-pilot doit :
1. Passer `maxTokens` à `claude -p --max-budget-usd` via conversion (ou équivalent `--max-turns` si estimé)
2. Poser un timer de `maxDuration` secondes ; au dépassement → kill le pod + transition `Failed` reason `timeout`
3. Lire les métriques tokens du stream NDJSON, comparer à `maxTokens`, abort si dépassé → `Failed` reason `token_budget_exceeded`

## Observable

- `maxTokens` et `maxDuration` respectés : un pod qui dépasse est abort
- Un pod qui finit sous budget termine proprement
- Metrics dans PodStatus reflètent la consommation réelle

## Gaps à combler

- [GAP] impl-python `enforce_resources(pod, profile)` daemon asyncio qui surveille et abort si dépassé
- [GAP] timer `maxDuration` via `asyncio.wait_for` ou equivalent
- [GAP] parser tokens du stream NDJSON pour alimenter la metric courante
- [GAP] test d'enforcement : spawn pod qui fait `sleep 300`, `maxDuration=10`, vérifier kill à 10s
- [GAP] test token budget : spawn pod, forger un stream NDJSON depassant budget, vérifier abort
