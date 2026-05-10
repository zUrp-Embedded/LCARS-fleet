# delivery-required-fields

**Source** : `work/moon-shot/10-beyond/beyond-objets-runtime-v2.md` §2 "Delivery"
**Date** : 2026-04-20
**Dernière révision** : 2026-04-20
**Statut** : PROVEN
**Référencé par** : `objets-runtime/README.md`

## Contrat

Une Delivery est créée uniquement par le gatekeeper lors de la promotion. Structure obligatoire :

```yaml
spec:
  artifacts: [...]                # liste, au moins 1
  qualifierReport: path/to/...    # rapport PROVEN (obligatoire)
  reviewerReport: path/to/...     # rapport JUDGED (obligatoire)
  reviewerScore: <int>            # score §11.2-G (obligatoire)
  gatekeeperDecision: promote     # enum : promote (seule valeur autorisée dans Delivery)
  gatekeeperJustification: str    # obligatoire, non vide
```

Invariants :
1. Les 5 champs `qualifierReport`, `reviewerReport`, `reviewerScore`, `gatekeeperDecision`, `gatekeeperJustification` sont **tous obligatoires**
2. `gatekeeperDecision` doit valoir exactement `promote` — une Delivery avec `retry` ou `escalate` est une contradiction logique (pas de Delivery si pas de promotion)
3. `reviewerScore` doit être un entier entre 0 et 10 (grille §11.2-G)
4. `artifacts` doit contenir au moins un élément
5. `gatekeeperJustification` ne peut pas être vide (validation humaine opposable)

## Observable

Fonction `validate_delivery(delivery_spec: dict) -> None | raise InvalidDelivery`.

## Ce que le test vérifie

- Delivery complète valide : passe
- Chaque champ obligatoire manquant : rejet avec message précis
- `gatekeeperDecision=retry` : rejet (contradiction)
- `reviewerScore=15` (hors range) : rejet
- `reviewerScore=-1` : rejet
- `artifacts=[]` : rejet
- `gatekeeperJustification=''` ou espaces : rejet
