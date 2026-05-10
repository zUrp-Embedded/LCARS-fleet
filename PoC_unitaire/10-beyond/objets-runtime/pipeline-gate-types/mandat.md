# pipeline-gate-types

**Source** : `work/moon-shot/10-beyond/beyond-objets-runtime-v2.md` §3 "Invariants du pipeline" (3, 4, 5)
**Date** : 2026-04-20
**Dernière révision** : 2026-04-20
**Statut** : PROVEN
**Référencé par** : `objets-runtime/README.md`

## Contrat

Trois types de gate dans un stage pipeline :

| Type | Sémantique | onFail |
|---|---|---|
| `hard` | évalué par fleet-pilot mécaniquement, FAIL bloque le pipeline | retry-<role> OU escalate |
| `soft` | advisory, FAIL n'interrompt pas la séquence | escalate-gatekeeper (ou ignore) |
| `terminal` | dernière décision de promotion (promote / retry / escalate) | onPromote / onRetry / onEscalate |

Règles d'évaluation :
- **hard FAIL** → pipeline bloque sur ce stage, `onFail` détermine la suite (retry attempt, ou escalade Failed)
- **soft FAIL** → pipeline continue, mais l'état est loggué comme advisory. Pas de blocage.
- **terminal** → 3 branches possibles selon le résultat : promote (Delivery créée), retry (nouveau attempt), escalate (architect)

Un pipeline doit avoir **au plus un gate terminal**, en dernière position. Plusieurs terminal = invalide.

## Observable

- Fonction `evaluate_gate(gate_type, result, on_fail_spec) -> next_action`
- hard + pass → continue
- hard + fail → on_fail_spec (retry-X | escalate)
- soft + pass ou fail → continue (soft n'interrompt jamais)
- terminal + promote → create_delivery
- terminal + retry → retry_attempt
- terminal + escalate → escalate_architect

## Ce que le test vérifie

- Table de vérité exhaustive pour les 3 types × outcomes possibles
- Validation d'un pipeline avec plusieurs gates terminal → rejet
- Un type inconnu de gate → rejet
