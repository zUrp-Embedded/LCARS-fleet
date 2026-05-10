# pipeline-condition-skip

**Source** : `work/moon-shot/10-beyond/beyond-objets-runtime-v2.md` §3 Invariant 2 "condition avant spawn"
**Date** : 2026-04-20
**Dernière révision** : 2026-04-20
**Statut** : DRAFT
**Référencé par** : `objets-runtime/README.md`

## Contrat

Un stage peut déclarer `condition: <expression>` (template `${{ ... }}`). Fleet-pilot évalue l'expression **avant** de spawner. Si False → stage skippé entièrement (pas de pod, pas d'output produit).

Exemple du corpus :
```yaml
reviewer:
  needs: [qualifier]
  condition: "${{ stages.qualifier.gate.result == 'pass' }}"
```

Invariants :
1. Condition évaluée dans le contexte courant (stages terminés + leurs outputs/gate results)
2. Condition évaluable à partir de l'état observé — pas de fonction arbitraire
3. Skip propre : le stage aval reçoit l'info "skippé" dans son contexte, pas "absent"
4. Grammaire restreinte : `==`, `!=`, `&&`, `||`, `!`, comparaisons sur outputs et gate.result

## Observable

- Expression évaluée retourne booléen
- Stage skippé n'apparaît pas dans les events (pas de `pod.allocated`)
- Stage suivant qui dépend d'un skippé reçoit l'info (pas de crash, pas de wait infini)

## Gaps à combler

- [GAP] parser d'expression `${{ ... }}` limité (grammaire bornée)
- [GAP] évaluateur contextuel (context = stages terminés + outputs + gate results)
- [GAP] impl-python `evaluate_condition(expr, context) -> bool`
- [GAP] test : pipeline 3 stages, skip du 2e, le 3e doit savoir que le 2e était skip pas fail
- [GAP] sécurité : grammaire restrictive, pas d'eval arbitraire (pas de `eval()` Python direct)
