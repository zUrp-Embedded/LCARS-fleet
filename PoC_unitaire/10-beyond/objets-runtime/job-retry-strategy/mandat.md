# job-retry-strategy

**Source** : `work/moon-shot/10-beyond/beyond-objets-runtime-v2.md` §2 "Retry"
**Date** : 2026-04-20
**Dernière révision** : 2026-04-20
**Statut** : PROVEN
**Référencé par** : `objets-runtime/README.md`

## Contrat

Le Job.spec.strategy porte trois éléments pour la décision retry :

```yaml
strategy:
  maxAttempts: 3
  retryOn:
    - hard_gate_fail
    - interrupted
  noRetryOn:
    - scope_violation
    - policy_denied
```

Règles de décision (fleet-pilot applique mécaniquement) :

1. **Attempt termine en Failed avec raison R** :
   - R ∈ `noRetryOn` → Job → Failed (escalade)
   - R ∈ `retryOn` ET attempts < maxAttempts → nouveau Attempt (retry)
   - R ∈ `retryOn` ET attempts >= maxAttempts → Job → Failed (maxAttempts atteint)
   - R ∉ `retryOn` ∪ `noRetryOn` → Job → Failed (raison non spécifiée, fail-closed)

2. **Attempt termine en Interrupted** : Job → Aborted (décision, pas retry, indépendamment de la strategy).

3. **Attempt termine en Lost** : fleet-pilot tente recovery, puis applique la même logique que Failed avec raison `lost` si recovery infructueux.

**Fail-closed** : une raison non listée dans retryOn ne retry PAS. Il faut expliciter retry.

## Observable

Fonction `decide_retry(reason, attempts, strategy) -> decision` où decision ∈ {retry, escalate_failed, escalate_aborted}.

Table de vérité exhaustive pour les combinaisons `(reason in retryOn?, reason in noRetryOn?, attempts < max?)`.

## Ce que le test vérifie

- Cas `noRetryOn` prime sur `retryOn` (si une raison est dans les deux, fail-closed)
- Cas `retryOn + attempts < max` → retry
- Cas `retryOn + attempts >= max` → escalate_failed
- Cas raison inconnue → escalate_failed (fail-closed)
- Cas raison `interrupted` → escalate_aborted (branche séparée)
